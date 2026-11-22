import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'http_factory.dart';
import 'net_image_headers.dart';

/// ImageStore — 图片磁盘缓存：内存字节 LRU + 磁盘文件
class ImageStore {
  ImageStore({
    this.memoryLimit = 48,
    this.memoryBytesLimit = 40 * 1024 * 1024,
    this.diskLimitBytes = 200 * 1024 * 1024,
    Directory? directory,
    http.Client? client,
  })  : _dirOverride = directory,
        _client = client;

  static final ImageStore instance = ImageStore();

  /// `.tmp` 文件只有明显陈旧才清：刚写完还没改名的临时文件属于正在写的那张图
  static const Duration _staleTmpAge = Duration(minutes: 10);

  final int memoryLimit;
  final int memoryBytesLimit;
  final int diskLimitBytes;

  final Directory? _dirOverride;
  http.Client? _client;

  final Map<String, Uint8List> _mem = {};
  int _memBytes = 0;

  /// 同一 URL 正在进行的读缓存 / 下载 / 落盘Future
  final Map<String, Future<Uint8List>> _inflight = {};

  /// 同 [HttpCache]：并发加载时共享同一个初始化 Future
  Future<Directory?>? _dirFuture;
  int _savedSinceEvict = 0;

  /// 命中内存 / 磁盘的计数，供设置页展示
  int memoryHits = 0;
  int diskHits = 0;

  http.Client get _http => _client ??= buildHttpClient(
        connectionTimeout: const Duration(seconds: 8),
      );

  /// 读缓存：内存 → 磁盘
  Future<Uint8List?> load(String url) async {
    final mem = _mem.remove(url);
    if (mem != null) {
      _mem[url] = mem; // LRU 移到末尾
      memoryHits++;
      return mem;
    }
    final dir = await _ensureDir();
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/${_fileName(url)}');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        await file.delete();
        return null;
      }
      _putMemory(url, bytes);
      diskHits++;
      return bytes;
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 读盘失败: $error');
      return null;
    }
  }

  /// 读缓存 → 未命中则下载并落盘
  Future<Uint8List> get(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final pending = _inflight[url];
    if (pending != null) return await pending;

    // 先登记再 await：两个调用方可能同时跨过上面的检查、一起卡在读盘的 IO 上
    final task = _getCold(url, onProgress: onProgress);
    _inflight[url] = task;
    try {
      return await task;
    } finally {
      _inflight.remove(url);
    }
  }

  Future<Uint8List> _getCold(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final cached = await load(url);
    if (cached != null) return cached;
    final bytes = await fetch(url, onProgress: onProgress);
    await save(url, bytes);
    return bytes;
  }

  /// 预热：把后面几页的字节提前拉进内存 / 磁盘缓存
  Future<void> warm(String url) async {
    try {
      await get(url);
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 预热失败: $error');
    }
  }

  /// 落盘 + 进内存
  Future<void> save(String url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    _putMemory(url, bytes);
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      final file = File('${dir.path}/${_fileName(url)}');
      // 先写临时文件再改名：避免进程被杀时留下半张图，下次读到坏数据
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // 淘汰协程 / `clear` 可能刚好把临时文件删掉了：重写一次再改名，别静默丢图
        await tmp.writeAsBytes(bytes, flush: false);
        await tmp.rename(file.path);
      }
      _savedSinceEvict++;
      if (_savedSinceEvict >= 60) {
        _savedSinceEvict = 0;
        unawaited(_evictDisk(dir));
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 写盘失败: $error');
    }
  }

  /// 直接下载（带图床要求的请求头）
  Future<Uint8List> fetch(
    String url, {
    Duration timeout = const Duration(seconds: 20),
    void Function(int received, int total)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers.addAll(imageHeaders);
    final streamed = await _http.send(request).timeout(timeout);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // 把响应体读掉，否则连接不会释放
      await streamed.stream.drain<void>();
      throw HttpException('HTTP ${streamed.statusCode}', uri: Uri.parse(url));
    }
    final total = streamed.contentLength ?? 0;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      onProgress?.call(builder.length, total);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      throw HttpException('响应为空', uri: Uri.parse(url));
    }
    return bytes;
  }

  /// 淘汰单张图（换头像等同一 URL 内容变了的场景）
  Future<void> evict(String url) async {
    final dropped = _mem.remove(url);
    if (dropped != null) _memBytes -= dropped.length;
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      final file = File('${dir.path}/${_fileName(url)}');
      if (await file.exists()) await file.delete();
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 淘汰失败: $error');
    }
  }

  Future<int> diskSizeBytes() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final item in dir.list()) {
        if (item is File) total += await item.length();
      }
    } catch (_) {
      return total;
    }
    return total;
  }

  Future<void> clear() async {
    _mem.clear();
    _memBytes = 0;
    memoryHits = 0;
    diskHits = 0;
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      await for (final item in dir.list()) {
        if (item is File) await item.delete();
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 清理失败: $error');
    }
  }

  // 内部

  void _putMemory(String url, Uint8List bytes) {
    final old = _mem.remove(url);
    if (old != null) _memBytes -= old.length;
    _mem[url] = bytes;
    _memBytes += bytes.length;
    while (_mem.isNotEmpty &&
        (_mem.length > memoryLimit || _memBytes > memoryBytesLimit)) {
      final key = _mem.keys.first;
      final dropped = _mem.remove(key);
      if (dropped != null) _memBytes -= dropped.length;
    }
  }

  static String _fileName(String url) =>
      sha1.convert(utf8.encode(url)).toString();

  Future<Directory?> _ensureDir() => _dirFuture ??= _initDir();

  Future<Directory?> _initDir() async {
    try {
      final base = _dirOverride ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/image_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      unawaited(_evictDisk(dir));
      return dir;
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 目录不可用: $error');
      return null;
    }
  }

  Future<void> _evictDisk(Directory dir) async {
    try {
      final entries = <MapEntry<File, int>>[];
      var total = 0;
      await for (final item in dir.list()) {
        if (item is! File) continue;
        if (item.path.endsWith('.tmp')) {
          // 只清陈旧的临时文件
          try {
            final stat = await item.stat();
            if (DateTime.now().difference(stat.modified) >= _staleTmpAge) {
              await item.delete();
            }
          } catch (_) {
            // 文件已经不在（被并发清理掉了），跳过就好
          }
          continue;
        }
        final size = await item.length();
        entries.add(MapEntry(item, size));
        total += size;
      }
      if (total <= diskLimitBytes) return;
      final stats = <MapEntry<File, DateTime>>[];
      for (final e in entries) {
        stats.add(MapEntry(e.key, (await e.key.stat()).modified));
      }
      stats.sort((a, b) => a.value.compareTo(b.value));
      for (final entry in stats) {
        if (total <= diskLimitBytes) break;
        try {
          final size = await entry.key.length();
          await entry.key.delete();
          total -= size;
        } catch (_) {
          // 单个文件删不掉不该中断整轮淘汰
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[image-cache] 淘汰失败: $error');
    }
  }
}
