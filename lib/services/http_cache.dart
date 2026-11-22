import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// CacheEntry — 一条缓存记录
class CacheEntry {
  final dynamic body;
  final DateTime savedAt;
  final Duration ttl;

  const CacheEntry(this.body, this.savedAt, this.ttl);

  /// 未过期，且晚于主动刷新水位线 staleBefore
  bool isFreshAt(DateTime now, DateTime staleBefore) =>
      savedAt.isAfter(staleBefore) && now.isBefore(savedAt.add(ttl));

  Map<String, dynamic> toJson() => {
        'savedAt': savedAt.millisecondsSinceEpoch,
        'ttl': ttl.inMilliseconds,
        'body': body,
      };

  static CacheEntry? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final savedAt = raw['savedAt'];
    final ttl = raw['ttl'];
    if (savedAt is! int || ttl is! int) return null;
    return CacheEntry(
      raw['body'],
      DateTime.fromMillisecondsSinceEpoch(savedAt),
      Duration(milliseconds: ttl),
    );
  }
}

/// HttpCache — 接口响应缓存，内存 LRU + 磁盘持久化 + 分级 TTL
class HttpCache extends ChangeNotifier {
  HttpCache({
    this.memoryLimit = 160,
    this.diskLimitBytes = 48 * 1024 * 1024,
    Directory? directory,
    DateTime Function()? clock,
  })  : _dirOverride = directory,
        _now = clock ?? DateTime.now;

  /// 全局单例
  static final HttpCache instance = HttpCache();

  /// 内存最多保留条数，超出按 LRU 淘汰
  final int memoryLimit;

  /// 磁盘目录上限（字节），超出按写入时间删最旧的
  final int diskLimitBytes;

  /// 过期超过该时长后不再回退
  static const Duration maxStaleAge = Duration(days: 14);

  final Directory? _dirOverride;

  /// 可注入时钟，单测里用来模拟时间流逝
  final DateTime Function() _now;

  /// 插入顺序即 LRU 顺序，命中时先 remove 再 put 移到末尾
  final Map<String, CacheEntry> _mem = {};

  /// 目录初始化只做一次，并发调用者等同一个 Future
  Future<Directory?>? _dirFuture;

  /// 主动刷新水位线，早于它写入的条目算过期
  DateTime _staleBefore = DateTime.fromMillisecondsSinceEpoch(0);

  int _hits = 0;
  int _staleHits = 0;
  int _writes = 0;
  int _writeSinceEvict = 0;

  /// 最近一次用过期数据顶上时的提示时间
  DateTime? lastStaleServedAt;

  int get hits => _hits;
  int get staleHits => _staleHits;
  int get writes => _writes;
  int get entryCount => _mem.length;

  // key / TTL 策略

  /// 缓存键只用 path + 查询参数，不含 host，换线路不失效
  String keyFor(String path, Map<String, String>? query) {
    if (query == null || query.isEmpty) return path;
    final keys = query.keys.toList()..sort();
    final q = keys.map((k) => '$k=${query[k]}').join('&');
    return '$path?$q';
  }

  /// 按接口决定 TTL，返回 null 表示不缓存
  Duration? ttlFor(String path) {
    // 登录态 / 写接口不缓存
    if (path.startsWith('/api/v3/member') ||
        path.startsWith('/api/v3/login') ||
        path.startsWith('/api/v3/upload')) {
      return null;
    }
    // 动画播放地址通常带时效签名，只缓存30 分钟
    if (path.startsWith('/api/v3/cartoon/') && path.contains('/chapter/')) {
      return const Duration(minutes: 30);
    }
    // 章节图片 / 写真正文 / 小说卷正文
    if (path.contains('/chapter2/') ||
        path.contains('/chapter/') ||
        path.contains('/volume/')) {
      return const Duration(days: 7);
    }
    if (path.endsWith('/chapters') || path.endsWith('/volumes')) {
      return const Duration(hours: 6);
    }
    if (path.contains('/system/') ||
        path.contains('/theme/') ||
        path.contains('/tag/') ||
        path.contains('/comment/config')) {
      return const Duration(hours: 6);
    }
    if (path.contains('/comments')) return const Duration(minutes: 3);
    if (path.startsWith('/api/v3/comic2/') ||
        path.startsWith('/api/v3/book/') ||
        path.startsWith('/api/v3/cartoon/') ||
        path.startsWith('/api/v3/post/') ||
        path.startsWith('/api/v3/topic/')) {
      return const Duration(minutes: 30);
    }
    // 列表 / 榜单 / 首页聚合 / 搜索
    return const Duration(minutes: 10);
  }

  // 读写

  /// 取新鲜数据，不新鲜或没有都返回 null
  Future<dynamic> readFresh(String key) async {
    final entry = await _load(key);
    if (entry == null) return null;
    if (!entry.isFreshAt(_now(), _staleBefore)) return null;
    _hits++;
    return entry.body;
  }

  /// 取任意未超 maxStaleAge 的数据，网络失败时顶上
  Future<dynamic> readStale(String key) async {
    final entry = await _load(key);
    if (entry == null) return null;
    if (_now().difference(entry.savedAt) > maxStaleAge) return null;
    _staleHits++;
    lastStaleServedAt = _now();
    notifyListeners();
    return entry.body;
  }

  Future<void> write(String key, dynamic body, Duration ttl) async {
    final entry = CacheEntry(body, _now(), ttl);
    _putMemory(key, entry);
    _writes++;
    try {
      final dir = await _ensureDir();
      if (dir == null) return;
      final file = File('${dir.path}/${_fileName(key)}');
      await file.writeAsString(jsonEncode(entry.toJson()), flush: false);
      _writeSinceEvict++;
      if (_writeSinceEvict >= 40) {
        _writeSinceEvict = 0;
        unawaited(_evictDisk(dir));
      }
    } catch (error) {
      // 缓存写失败不影响业务
      if (kDebugMode) debugPrint('[cache] 写盘失败 $key: $error');
    }
  }

  /// 用户主动刷新：全部标记为过期，但保留数据作离线回退
  void markAllStale() {
    _staleBefore = _now();
    if (kDebugMode) debugPrint('[cache] 已标记全部过期（下拉刷新）');
  }

  /// 真正删除，设置页「清除缓存」用
  Future<void> clear() async {
    _mem.clear();
    _hits = 0;
    _staleHits = 0;
    _writes = 0;
    lastStaleServedAt = null;
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      await for (final item in dir.list()) {
        if (item is File) await item.delete();
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[cache] 清理失败: $error');
    }
    notifyListeners();
  }

  Future<int> diskSizeBytes() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final item in dir.list()) {
        if (item is File) {
          total += await item.length();
        }
      }
    } catch (_) {
      return total;
    }
    return total;
  }

  // 内部

  Future<CacheEntry?> _load(String key) async {
    final hit = _mem.remove(key);
    if (hit != null) {
      _mem[key] = hit; // 移到末尾即最近使用
      return hit;
    }
    final dir = await _ensureDir();
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/${_fileName(key)}');
      if (!await file.exists()) return null;
      final entry = CacheEntry.fromJson(jsonDecode(await file.readAsString()));
      if (entry == null) return null;
      _putMemory(key, entry);
      return entry;
    } catch (error) {
      if (kDebugMode) debugPrint('[cache] 读盘失败 $key: $error');
      return null;
    }
  }

  void _putMemory(String key, CacheEntry entry) {
    _mem.remove(key);
    _mem[key] = entry;
    while (_mem.length > memoryLimit) {
      _mem.remove(_mem.keys.first);
    }
  }

  static String _fileName(String key) =>
      '${sha1.convert(utf8.encode(key))}.json';

  Future<Directory?> _ensureDir() => _dirFuture ??= _initDir();

  Future<Directory?> _initDir() async {
    try {
      final base = _dirOverride ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/http_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      unawaited(_evictDisk(dir));
      return dir;
    } catch (error) {
      if (kDebugMode) debugPrint('[cache] 磁盘缓存不可用: $error');
      return null;
    }
  }

  Future<void> _evictDisk(Directory dir) async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final item in dir.list()) {
        if (item is! File) continue;
        files.add(item);
        total += await item.length();
      }
      if (total <= diskLimitBytes) return;
      final stamps = <File, DateTime>{};
      for (final file in files) {
        stamps[file] = (await file.stat()).modified;
      }
      files.sort((a, b) => stamps[a]!.compareTo(stamps[b]!));
      for (final file in files) {
        if (total <= diskLimitBytes) break;
        final size = await file.length();
        await file.delete();
        total -= size;
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[cache] 淘汰失败: $error');
    }
  }
}
