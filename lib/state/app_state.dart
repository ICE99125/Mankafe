import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../models/auth_user.dart';
import '../models/comic.dart';
import '../models/favorite_entry.dart';
import '../models/media_page.dart';
import '../services/device_profile.dart';
import '../services/proxy_config.dart';

/// ReadDirection — 翻页方向
enum ReadDirection { horizontal, vertical }

/// HistoryEntry — 一条浏览记录
class HistoryEntry {
  final String pathWord;
  final String chapterUuid;
  final String chapterName;
  final int page;
  final DateTime at;

  /// 阅读时记录下的真实作品名与封面，历史列表直接展示，不再用演示数据补齐
  final String name;
  final String? cover;

  /// 这条历史属于哪个章节栏目（分组）
  final String? groupPathWord;

  /// 这条记录属于哪一类内容（漫画 / 轻小说 / 写真集 / 动画）
  final MediaKind kind;

  /// 作品在服务端的累计热度（`popular`）
  final int popular;

  const HistoryEntry({
    required this.pathWord,
    required this.chapterUuid,
    required this.chapterName,
    this.page = 0,
    required this.at,
    this.name = '',
    this.cover,
    this.groupPathWord,
    this.kind = MediaKind.comic,
    this.popular = 0,
  });

  /// 只换热度、其余原样保留
  HistoryEntry withPopular(int value) => HistoryEntry(
        pathWord: pathWord,
        chapterUuid: chapterUuid,
        chapterName: chapterName,
        page: page,
        at: at,
        name: name,
        cover: cover,
        groupPathWord: groupPathWord,
        kind: kind,
        popular: value,
      );

  Map<String, dynamic> toJson() => {
        'pathWord': pathWord,
        'chapterUuid': chapterUuid,
        'chapterName': chapterName,
        'page': page,
        'at': at.millisecondsSinceEpoch,
        'name': name,
        'cover': cover,
        'groupPathWord': groupPathWord,
        'kind': kind.name,
        'popular': popular,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        pathWord: (json['pathWord'] ?? '').toString(),
        chapterUuid: (json['chapterUuid'] ?? '').toString(),
        chapterName: (json['chapterName'] ?? '').toString(),
        page: json['page'] is int ? json['page'] as int : 0,
        at: DateTime.fromMillisecondsSinceEpoch(
            json['at'] is int ? json['at'] as int : 0),
        name: (json['name'] ?? '').toString(),
        cover: json['cover'] is String ? json['cover'] as String : null,
        groupPathWord: json['groupPathWord'] is String
            ? json['groupPathWord'] as String
            : null,
        kind: _kindOf(json['kind']),
        popular: json['popular'] is int ? json['popular'] as int : 0,
      );

  static MediaKind _kindOf(dynamic raw) {
    final v = (raw ?? '').toString();
    for (final k in MediaKind.values) {
      if (k.name == v) return k;
    }
    return MediaKind.comic;
  }
}

/// AppState — 外观、阅读偏好、书架 / 历史 / 进度的本地状态
class AppState extends ChangeNotifier {
  static const _kTheme = 'pref_theme_mode';
  static const _kSeed = 'pref_seed_index';
  static const _kDirection = 'pref_read_direction';
  static const _kLanguage = 'pref_app_language';
  static const _kPageIndicator = 'pref_page_indicator';

  /// 旧版收藏：只有 `path_word` 字符串列表
  static const _kFavoritesLegacy = 'pref_favorites';

  /// 新版收藏：完整条目 JSON 列表（未登录书架的数据源）
  static const _kFavorites = 'pref_favorites_v2';
  static const _kHistory = 'pref_history';
  static const _kPseudoId = 'pref_pseudo_id';
  static const _kAuthToken = 'pref_auth_token';
  static const _kAuthUser = 'pref_auth_user';

  ThemeMode themeMode = ThemeMode.system;
  int seedIndex = 0;
  ReadDirection readDirection = ReadDirection.horizontal;
  AppLanguage language = AppLanguage.system;
  bool showPageIndicator = true;

  /// 网络代理配置，null 表示直连
  ProxySettings? proxy;

  /// 本地收藏（未登录时的书架数据源），最近收藏的排在最前
  final List<FavoriteEntry> localFavorites = [];

  final List<HistoryEntry> history = [];

  /// 登录态：token 与账号信息由 /api/v3/login 返回，存本地，重启保持
  String? authToken;
  AuthUser? authUser;
  bool authExpired = false;

  bool get isLoggedIn => authToken != null && authToken!.isNotEmpty;

  bool loaded = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    // 设备指纹：正版是首次启动随机生成一次、之后一直复用（抓包两次值不同但都合法）
    final savedPseudo = p.getString(_kPseudoId);
    if (savedPseudo != null && savedPseudo.trim().length >= 8) {
      DeviceProfile.setPseudoId(savedPseudo);
    } else {
      final generated = DeviceProfile.newPseudoId();
      DeviceProfile.setPseudoId(generated);
      await p.setString(_kPseudoId, generated);
    }
    themeMode = switch (p.getString(_kTheme)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    seedIndex = p.getInt(_kSeed) ?? 0;
    readDirection = p.getString(_kDirection) == 'vertical'
        ? ReadDirection.vertical
        : ReadDirection.horizontal;
    language = switch (p.getString(_kLanguage)) {
      'zh' => AppLanguage.zh,
      'en' => AppLanguage.en,
      _ => AppLanguage.system,
    };
    showPageIndicator = p.getBool(_kPageIndicator) ?? true;
    proxy = ProxyConfig.decode(p.getString(ProxyConfig.prefKey));
    ProxyConfig.apply(proxy);
    _loadFavorites(p);
    try {
      final raw = jsonDecode(p.getString(_kHistory) ?? '[]');
      if (raw is List) {
        history
          ..clear()
          ..addAll(raw
              .whereType<Map>()
              .map((e) => HistoryEntry.fromJson(Map<String, dynamic>.from(e))));
      }
    } catch (_) {
      history.clear();
    }
    authToken = p.getString(_kAuthToken);
    if (authToken != null && authToken!.isEmpty) authToken = null;
    try {
      final raw = p.getString(_kAuthUser);
      authUser = raw == null
          ? null
          : AuthUser.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      authUser = null;
    }
    loaded = true;
    notifyListeners();
  }

  /// 读本地收藏，并把旧版只有 path_word 的字符串列表迁移成完整条目
  void _loadFavorites(SharedPreferences p) {
    localFavorites.clear();
    final raw = p.getString(_kFavorites);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          localFavorites.addAll(list.whereType<Map>().map(
              (e) => FavoriteEntry.fromJson(Map<String, dynamic>.from(e))));
          _sortFavorites();
          return;
        }
      } catch (_) {
        localFavorites.clear();
      }
    }
    for (final pathWord in p.getStringList(_kFavoritesLegacy) ?? const []) {
      if (pathWord.isEmpty) continue;
      localFavorites.add(FavoriteEntry(pathWord: pathWord));
    }
    _sortFavorites();
  }

  void _sortFavorites() =>
      localFavorites.sort((a, b) => b.addedAt.compareTo(a.addedAt));

  /// 本地收藏的 path_word 集合视图（只读，供快速判定
  Set<String> get favorites => {for (final e in localFavorites) e.pathWord};

  /// 某一类内容的本机收藏（最近收藏的排在最前）
  List<FavoriteEntry> localFavoritesOf(MediaKind kind) =>
      localFavorites.where((e) => e.kind == kind).toList();

  /// 个人页统计用：已登录时以云端数量为准（由书架拉取时写回），未登录时就是本地条数
  int cloudFavoriteCount = 0;
  int get favoriteCount => isLoggedIn && cloudFavoriteCount > 0
      ? cloudFavoriteCount
      : localFavorites.length;

  FavoriteEntry? favoriteOf(String pathWord,
      {MediaKind kind = MediaKind.comic}) {
    for (final e in localFavorites) {
      if (e.kind == kind && e.pathWord == pathWord) return e;
    }
    return null;
  }

  /// 串行化写入：多次 setXxx 并发调用时，按调用顺序落盘，避免旧快照覆盖新值
  Future<void> _writeQueue = Future<void>.value();

  Future<void> _save() {
    final theme = themeMode.name;
    final seed = seedIndex;
    final direction = readDirection.name;
    final languageName = language.name;
    final indicator = showPageIndicator;
    final favoriteJson =
        jsonEncode(localFavorites.map((e) => e.toJson()).toList());
    final historyJson = jsonEncode(history.map((e) => e.toJson()).toList());
    final token = authToken;
    final userJson = authUser == null ? null : jsonEncode(authUser!.toJson());
    _writeQueue = _writeQueue.then((_) async {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kTheme, theme);
      await p.setInt(_kSeed, seed);
      await p.setString(_kDirection, direction);
      await p.setString(_kLanguage, languageName);
      await p.setBool(_kPageIndicator, indicator);
      final proxyValue = proxy;
      if (proxyValue == null) {
        await p.remove(ProxyConfig.prefKey);
      } else {
        await p.setString(ProxyConfig.prefKey, ProxyConfig.encode(proxyValue));
      }
      await p.setString(_kFavorites, favoriteJson);
      // 迁移完成后清掉旧键：留着会让已取消的收藏在旧键里阴魂不散
      await p.remove(_kFavoritesLegacy);
      await p.setString(_kHistory, historyJson);
      if (token == null) {
        await p.remove(_kAuthToken);
      } else {
        await p.setString(_kAuthToken, token);
      }
      if (userJson == null) {
        await p.remove(_kAuthUser);
      } else {
        await p.setString(_kAuthUser, userJson);
      }
    });
    return _writeQueue;
  }

  /// 保存登录结果（token + 账号信息），并清掉登录已过期提示
  Future<void> saveSession(String token, AuthUser user) async {
    authToken = token;
    authUser = user;
    authExpired = false;
    notifyListeners();
    await _save();
  }

  /// 资料更新成功后刷新本机缓存的账号信息（token 不变）
  Future<void> updateAuthUser(AuthUser user) async {
    authUser = user;
    notifyListeners();
    await _save();
  }

  /// 退出登录 / 登录态失效
  Future<void> clearSession({bool expired = false}) async {
    authToken = null;
    authUser = null;
    authExpired = expired;
    notifyListeners();
    await _save();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    await _save();
  }

  Future<void> setSeed(int value) async {
    seedIndex = value;
    notifyListeners();
    await _save();
  }

  Future<void> setReadDirection(ReadDirection value) async {
    readDirection = value;
    notifyListeners();
    await _save();
  }

  Future<void> setLanguage(AppLanguage value) async {
    language = value;
    notifyListeners();
    await _save();
  }

  /// 保存并立即应用代理设置（null = 直连）
  Future<void> setProxy(ProxySettings? value) async {
    proxy = value;
    ProxyConfig.apply(value);
    notifyListeners();
    await _save();
  }

  Future<void> setShowPageIndicator(bool value) async {
    showPageIndicator = value;
    notifyListeners();
    await _save();
  }

  bool isFavorite(String pathWord, {MediaKind kind = MediaKind.comic}) =>
      favoriteOf(pathWord, kind: kind) != null;

  /// 写入 / 移除本地收藏
  Future<void> setLocalFavorite(
    Comic comic,
    bool value, {
    MediaKind kind = MediaKind.comic,
  }) async {
    final index = localFavorites
        .indexWhere((e) => e.kind == kind && e.pathWord == comic.pathWord);
    if (value) {
      if (index >= 0) {
        localFavorites[index] = localFavorites[index].merge(comic);
      } else {
        localFavorites.add(FavoriteEntry.fromComic(comic, kind: kind));
      }
      _sortFavorites();
    } else if (index >= 0) {
      localFavorites.removeAt(index);
    } else {
      return;
    }
    notifyListeners();
    await _save();
  }

  /// 打开详情页时顺手补全旧数据缺失的名称 / 封面
  Future<void> mergeFavorite(
    Comic comic, {
    MediaKind kind = MediaKind.comic,
  }) async {
    final index = localFavorites
        .indexWhere((e) => e.kind == kind && e.pathWord == comic.pathWord);
    if (index < 0) return;
    final old = localFavorites[index];
    final merged = old.merge(comic);
    if (merged.name == old.name &&
        merged.cover == old.cover &&
        merged.authors.join() == old.authors.join() &&
        merged.lastChapter == old.lastChapter &&
        merged.uuid == old.uuid) {
      return;
    }
    localFavorites[index] = merged;
    notifyListeners();
    await _save();
  }

  /// 清空本地收藏（登录后已全部同步到云端时调用）
  Future<void> clearLocalFavorites() async {
    if (localFavorites.isEmpty) return;
    localFavorites.clear();
    notifyListeners();
    await _save();
  }

  /// 只保留 [keep]（[FavoriteEntry.key] 集合）里的本地收藏
  Future<void> retainLocalFavorites(Set<String> keep) async {
    final before = localFavorites.length;
    localFavorites.removeWhere((e) => !keep.contains(e.key));
    if (localFavorites.length == before) return;
    notifyListeners();
    await _save();
  }

  /// 书架拉到云端收藏总数后写回，供个人页统计显示
  void setCloudFavoriteCount(int value) {
    if (cloudFavoriteCount == value) return;
    cloudFavoriteCount = value;
    notifyListeners();
  }

  /// 看过的作品，浏览记录页按类型取用
  HistoryEntry? lastReadOf(String pathWord, {MediaKind? kind}) {
    for (final e in history) {
      if (e.pathWord != pathWord) continue;
      if (kind != null && e.kind != kind) continue;
      return e;
    }
    return null;
  }

  Future<void> recordRead({
    required String pathWord,
    required String chapterUuid,
    required String chapterName,
    required int page,
    String name = '',
    String? cover,
    String? groupPathWord,
    MediaKind kind = MediaKind.comic,
    int popular = 0,
  }) async {
    // 换章节重记一条时，热度不该被旧值以外的空值覆盖
    var oldPopular = 0;
    String oldName = '';
    String? oldCover;
    for (final e in history) {
      if (e.pathWord == pathWord && e.kind == kind) {
        oldPopular = e.popular;
        oldName = e.name;
        oldCover = e.cover;
        break;
      }
    }
    // 去重按类型 + 标识：漫画与写真的标识格式不同，跨类型不该互相挤掉
    history.removeWhere((e) => e.pathWord == pathWord && e.kind == kind);
    history.insert(
      0,
      HistoryEntry(
        pathWord: pathWord,
        chapterUuid: chapterUuid,
        chapterName: chapterName,
        page: page,
        at: DateTime.now(),
        // 阅读器/播放器只负责读到哪，标题和封面由详情页带来
        name: name.isNotEmpty ? name : oldName,
        cover: cover ?? oldCover,
        groupPathWord: groupPathWord,
        kind: kind,
        popular: popular > 0 ? popular : oldPopular,
      ),
    );
    if (history.length > 120) history.removeRange(120, history.length);
    notifyListeners();
    await _save();
  }

  /// 看过的作品，浏览记录页按类型取用
  Future<void> markSeen({
    required MediaKind kind,
    required String pathWord,
    required String name,
    String? cover,
    String chapterName = '',
    int popular = 0,
  }) async {
    final old = history.firstWhere(
      (e) => e.pathWord == pathWord && e.kind == kind,
      orElse: () => HistoryEntry(
        pathWord: pathWord,
        chapterUuid: '',
        chapterName: '',
        at: DateTime.now(),
        kind: kind,
      ),
    );
    // 已有记录里读到过的章节、分组要保留，否则漫画续读会丢掉进度
    history.removeWhere((e) => e.pathWord == pathWord && e.kind == kind);
    history.insert(
      0,
      HistoryEntry(
        pathWord: pathWord,
        chapterUuid: old.chapterUuid,
        chapterName: chapterName.isNotEmpty ? chapterName : old.chapterName,
        page: old.page,
        at: DateTime.now(),
        name: name.isNotEmpty ? name : old.name,
        cover: cover ?? old.cover,
        groupPathWord: old.groupPathWord,
        kind: kind,
        popular: popular > 0 ? popular : old.popular,
      ),
    );
    if (history.length > 120) history.removeRange(120, history.length);
    notifyListeners();
    await _save();
    if (kDebugMode) {
      debugPrint('[history] seen kind=${kind.name} pathWord=$pathWord '
          'name=$name total=${history.length}');
    }
  }

  /// 清空本机浏览记录
  Future<void> clearHistory({MediaKind? kind}) async {
    if (kind == null) {
      history.clear();
    } else {
      history.removeWhere((e) => e.kind == kind);
    }
    notifyListeners();
    await _save();
  }

  /// 删掉单条本机记录（长按某本书 → 删除）
  Future<void> removeHistory(MediaKind kind, String pathWord) async {
    final before = history.length;
    history.removeWhere((e) => e.kind == kind && e.pathWord == pathWord);
    if (history.length == before) return;
    notifyListeners();
    await _save();
  }

  /// 用云端拉到的 `popular` 回填本机记录
  Future<void> backfillHistoryPopular(
      MediaKind kind, Map<String, int> byPathWord) async {
    var changed = false;
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
      if (entry.kind != kind || entry.popular > 0) continue;
      final value = byPathWord[entry.pathWord] ?? 0;
      if (value <= 0) continue;
      history[i] = entry.withPopular(value);
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  Future<void> resetLocalData() async {
    localFavorites.clear();
    cloudFavoriteCount = 0;
    history.clear();
    notifyListeners();
    await _save();
  }
}
