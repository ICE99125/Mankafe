import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/link.dart';
import 'api_endpoints.dart';
import 'http_factory.dart';
import 'proxy_config.dart';

/// RouteManager — 线路探测与自动切换
class RouteManager extends ChangeNotifier {
  RouteManager() {
    _links = _defaultLinks();
  }

  static const _kMode = 'route_mode';
  static const _kActive = 'route_active';
  static const _kCustom = 'route_custom_links';
  static const _kFallback = 'route_auto_fallback';

  // 探测超时12s：弱网下冷启动的首次 TLS 握手可超过8s
  static const Duration _probeTimeout = Duration(seconds: 12);

  /// 单条线路探测失败后的重试次数
  static const int _probeAttempts = 2;

  /// 连续失败多少次才降级为不可达
  static const int _offlineAfterFailures = 3;

  http.Client _client = buildHttpClient();

  final Map<String, int> _failureStreak = {};
  bool _recovering = false;
  DateTime? _lastRecoverAt;

  /// 代理变更后重建探测用 client（`findProxy` 在创建时绑定）
  void refreshTransport() {
    final old = _client;
    _client = buildHttpClient();
    Timer(const Duration(seconds: 30), old.close);
  }

  late List<RouteLink> _links;
  RouteMode mode = RouteMode.auto;
  bool autoFallback = true;
  String _activeId = 'primary';
  Network2Info? network2;

  bool startupChecking = false;
  bool startupDone = false;
  String startupPhase = '准备检测链路';
  String? lastNotice;

  /// 网络代际：每次重新判定链路 +1，页面用它做 key 重建
  int _revision = 0;
  int get revision => _revision;

  final List<RequestLog> logs = [];

  List<RouteLink> get links => List.unmodifiable(_links);

  RouteLink get activeLink => _byId(_activeId) ?? _links.first;

  RouteLink? byId(String id) => _byId(id);

  /// 全部链路都是真实 HTTPS 地址（内置 / 下发 / 自定义），没有离线数据源
  List<RouteLink> get networkLinks => List.unmodifiable(_links);

  String get activeId => _activeId;

  int get onlineCount => _links.where((l) => l.isOnline).length;

  /// 启动自检进度：已出结果（非 checking / unknown）的网络链路占比
  double get startupProgress {
    final total = networkLinks.length;
    if (total == 0) return 1;
    final done = networkLinks
        .where((l) =>
            l.health != LinkHealth.unknown && l.health != LinkHealth.checking)
        .length;
    return done / total;
  }

  RouteLink? _byId(String id) {
    for (final l in _links) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// 内置候选域名，取自 base.apk 常量表与 network2 下发
  static List<RouteLink> _defaultLinks() => [
        RouteLink(
          id: 'primary',
          name: '主线路 · copy202602',
          baseUrl: 'https://api.copy202602.com',
          origin: LinkOrigin.builtin,
          note: 'APK 内置 API 域名（homeIndex2 实测 200）',
        ),
        RouteLink(
          id: 'backup_a',
          name: '备用线路 A · copy202601',
          baseUrl: 'https://api.copy202601.com',
          origin: LinkOrigin.builtin,
          note: 'network2 下发主机',
        ),
        RouteLink(
          id: 'backup_b',
          name: '备用线路 B · manga2026',
          baseUrl: 'https://api.manga2026.xyz',
          origin: LinkOrigin.builtin,
          note: 'APK 内置备用域名（network2 实测 200）',
        ),
        RouteLink(
          id: 'backup_c',
          name: '备用线路 C · mapi',
          baseUrl: 'https://mapi.mangacopy.com',
          origin: LinkOrigin.builtin,
          note: 'APK 内置默认域名（h5 接口 404，仅兜底）',
        ),
      ];

  /// 读取持久化设置
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode = p.getString(_kMode) == 'manual' ? RouteMode.manual : RouteMode.auto;
    _activeId = p.getString(_kActive) ?? 'primary';
    autoFallback = p.getBool(_kFallback) ?? true;

    final custom = <RouteLink>[];
    try {
      final raw = jsonDecode(p.getString(_kCustom) ?? '[]');
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            custom
                .add(RouteLink.customFromJson(Map<String, dynamic>.from(item)));
          }
        }
      }
    } catch (_) {
      // 忽略损坏的自定义配置
    }
    _links = [..._defaultLinks(), ...custom];
    // 旧版本持久化过已删除的链路 id，一律落到主线路，保证始终指向真实 HTTPS 地址
    if (_byId(_activeId) == null) {
      _activeId = _links.first.id;
      await p.setString(_kActive, _activeId);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, mode == RouteMode.auto ? 'auto' : 'manual');
    await p.setString(_kActive, _activeId);
    await p.setBool(_kFallback, autoFallback);
    await p.setString(
      _kCustom,
      jsonEncode(_links
          .where((l) => l.origin == LinkOrigin.custom)
          .map((l) => l.toJson())
          .toList()),
    );
  }

  void _phase(String text) {
    startupPhase = text;
    notifyListeners();
  }

  /// 启动自检主流程（`BootstrapScreen` 即首屏调用）
  Future<void> runStartupCheck() async {
    if (startupChecking) return;
    startupChecking = true;
    startupDone = false;
    lastNotice = null;
    try {
      _phase('读取已保存的链路设置');
      await load();

      _phase('并行探测 ${networkLinks.length} 条链路是否畅通');
      for (final l in networkLinks) {
        l.health = LinkHealth.checking;
        l.detail = '检测中…';
      }
      notifyListeners();
      await probeAll(markChecking: false);

      _phase('拉取线路下发（network2）');
      await refreshNetwork2();

      _phase('确定当前链路');
      _resolveActive();
      await _persist();

      startupDone = true;
    } finally {
      startupChecking = false;
      _revision++;
      notifyListeners();
    }
  }

  /// 并行探测所有网络链路，逐条刷新状态（UI 上能看到一条条点亮）
  Future<void> probeAll({bool markChecking = true}) async {
    final targets = networkLinks;
    if (markChecking) {
      for (final l in targets) {
        l.health = LinkHealth.checking;
        l.detail = '检测中…';
      }
      notifyListeners();
    }
    final futures = targets.map((link) async {
      final result = await _probe(link);
      _applyProbe(link, result);
      notifyListeners();
      _addLog(RequestLog(
        time: DateTime.now(),
        method: 'GET',
        path: ApiEndpoints.homeIndex,
        linkName: link.name,
        latencyMs: result.latencyMs ?? 0,
        status: result.ok ? 200 : null,
        error: result.ok ? null : result.detail,
      ));
    }).toList();
    await Future.wait(futures);
    notifyListeners();
  }

  /// 把探测结果落到链路状态上
  void _applyProbe(RouteLink link, _ProbeResult result) {
    if (result.ok) {
      _failureStreak.remove(link.id);
      link.health = LinkHealth.online;
    } else {
      link.health = LinkHealth.offline;
    }
    link.latencyMs = result.latencyMs;
    link.detail = result.detail;
    link.checkedAt = DateTime.now();
  }

  Future<void> probeOne(String id) async {
    final link = _byId(id);
    if (link == null) return;
    link.health = LinkHealth.checking;
    link.detail = '检测中…';
    notifyListeners();
    final result = await _probe(link);
    _applyProbe(link, result);
    notifyListeners();
  }

  /// 探活：快速失败（拒绝连接 / DNS 失败 / 立即重置）才重试
  Future<_ProbeResult> _probe(RouteLink link) async {
    _ProbeResult? last;
    for (var attempt = 1; attempt <= _probeAttempts; attempt++) {
      last = await _probeOnce(link);
      if (last.ok) {
        if (kDebugMode) {
          debugPrint(
              '[probe] ${link.name} 畅通（第 $attempt 次，${last.latencyMs} ms）');
        }
        return last;
      }
      if (kDebugMode) {
        debugPrint('[probe] ${link.name} 第 $attempt 次失败'
            '（${last.elapsedMs} ms）：${last.detail}');
      }
      final worthRetry = last.elapsedMs < 2000;
      if (!worthRetry || attempt == _probeAttempts) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return last!;
  }

  Future<_ProbeResult> _probeOnce(RouteLink link) async {
    final sw = Stopwatch()..start();
    // 用首页真实业务接口探活，避免探测畅通但首页404
    try {
      final response = await _client
          .get(
            apiUri(
                link.baseUrl, ApiEndpoints.homeIndex, const {'platform': '3'}),
            headers: apiHeaders(),
          )
          .timeout(_probeTimeout);
      sw.stop();
      if (response.statusCode == 200 && _isEnvelope(response.bodyBytes)) {
        return _ProbeResult(true, sw.elapsedMilliseconds, 'HTTP 200',
            elapsedMs: sw.elapsedMilliseconds);
      }
      return _ProbeResult(false, null, '响应异常（HTTP ${response.statusCode}）',
          elapsedMs: sw.elapsedMilliseconds);
    } catch (error) {
      sw.stop();
      return _ProbeResult(false, null, _probeFailureDetail(error),
          elapsedMs: sw.elapsedMilliseconds);
    }
  }

  /// 探活要看到合法信封：`code=200` 且 `results` 是对象
  static bool _isEnvelope(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map &&
          decoded['code'] == 200 &&
          decoded['results'] is Map;
    } catch (_) {
      return false;
    }
  }

  /// 探测同样走代理：代理不可用时明确标注，避免把代理故障误认成线路故障
  static String _probeFailureDetail(Object error) {
    final settings = ProxyConfig.settings;
    if (settings != null &&
        settings.usable &&
        ProxyConfig.isProxyFailure(error,
            host: settings.host.trim(), port: settings.port)) {
      return '代理不可用';
    }
    return '连接超时 / 不可达';
  }

  /// 从任一在线链路取 network2，把 api_list 合并进链路列表并补测
  Future<void> refreshNetwork2() async {
    final candidates = <RouteLink>[
      if (_byId(_activeId)?.isOnline ?? false) activeLink,
      ..._links.where((l) => l.isOnline),
    ];
    final seen = <String>{};
    for (final link in candidates) {
      if (!seen.add(link.id)) continue;
      try {
        final sw = Stopwatch()..start();
        final response = await _client
            .get(
              apiUri(link.baseUrl, ApiEndpoints.network2, {'platform': '3'}),
              headers: apiHeaders(),
            )
            .timeout(_probeTimeout);
        sw.stop();
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map && body['code'] == 200 && body['results'] is Map) {
          network2 = Network2Info.fromJson(
              Map<String, dynamic>.from(body['results'] as Map));
          _addLog(RequestLog(
            time: DateTime.now(),
            method: 'GET',
            path: ApiEndpoints.network2,
            linkName: link.name,
            latencyMs: sw.elapsedMilliseconds,
            status: response.statusCode,
          ));
          final added = _mergeDiscovered();
          if (added.isNotEmpty) {
            for (final l in added) {
              await probeOne(l.id);
            }
          }
          notifyListeners();
          return;
        }
      } catch (_) {
        // 换下一条
      }
    }
    network2 = null;
    notifyListeners();
  }

  List<RouteLink> _mergeDiscovered() {
    final info = network2;
    if (info == null) return const [];
    final urls = <String>[...info.apiList, if (info.api.isNotEmpty) info.api];
    final added = <RouteLink>[];
    final seen = <String>{};
    for (final raw in urls) {
      // 下发的是裸域名（且可能是列表套列表），先补全成 https://host
      final normalized = _normalizeBaseUrl(raw);
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      final exists = _links
          .any((l) => l.baseUrl.replaceAll(RegExp(r'/$'), '') == normalized);
      if (exists) continue;
      final host = Uri.tryParse(normalized)?.host ?? normalized;
      final link = RouteLink(
        id: 'disc_${normalized.hashCode.abs()}',
        name: '下发线路 · $host',
        baseUrl: normalized,
        origin: LinkOrigin.discovered,
        note: info.mobileRegion.isEmpty
            ? '由 network2 动态下发'
            : '由 network2 动态下发（${info.mobileRegion}）',
      );
      _links.add(link);
      added.add(link);
    }
    return added;
  }

  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  /// 决定当前链路
  void _resolveActive() {
    final online = _links.where((l) => l.isOnline).toList()
      ..sort(
          (a, b) => (a.latencyMs ?? 999999).compareTo(b.latencyMs ?? 999999));

    if (mode == RouteMode.auto) {
      if (online.isEmpty) {
        if (_byId(_activeId) == null) _activeId = _links.first.id;
        lastNotice = '所有网络链路均不可达，请检查网络后重试或更换线路';
        return;
      }
      final best = online.first;
      final current = _byId(_activeId);
      // 当前链路仍然畅通、且没有被明显更快的候选甩开时保持不变
      if (current != null &&
          current.isOnline &&
          (current.latencyMs ?? 0) <= (best.latencyMs ?? 0) * 1.6 + 300) {
        lastNotice = '保持当前链路：${current.name}';
        return;
      }
      _activeId = best.id;
      lastNotice = '已自动选择延迟最低的链路：${best.name}';
      return;
    }

    final current = _byId(_activeId);
    if (current == null) {
      _activeId = online.isEmpty ? _links.first.id : online.first.id;
      lastNotice = '上次选择的链路已不存在，已重新选择';
      return;
    }
    if (current.health == LinkHealth.offline) {
      if (autoFallback && online.isNotEmpty) {
        _activeId = online.first.id;
        lastNotice = '手动锁定的链路不可达，已临时回退到 ${online.first.name}';
      } else {
        lastNotice = '当前链路不可达，可在链路管理中切换线路或重新测速';
      }
    }
  }

  /// 设置页手动切换：切完立即持久化，并通知各页面刷新数据
  Future<void> switchTo(String id, {bool asManual = true}) async {
    final link = _byId(id);
    if (link == null) return;
    _activeId = id;
    if (asManual) mode = RouteMode.manual;
    lastNotice = '已切换到「${link.name}」';
    if (link.health == LinkHealth.unknown) {
      await probeOne(id);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> setMode(RouteMode value) async {
    mode = value;
    if (mode == RouteMode.auto) {
      _resolveActive();
      lastNotice = '已切换为自动择优，当前：${activeLink.name}';
    } else {
      lastNotice = '已锁定当前链路：${activeLink.name}';
    }
    await _persist();
    notifyListeners();
  }

  Future<void> setAutoFallback(bool value) async {
    autoFallback = value;
    await _persist();
    notifyListeners();
  }

  Future<void> addCustomLink(String name, String baseUrl) async {
    var url = baseUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    final link = RouteLink(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '自定义链路' : name.trim(),
      baseUrl: url,
      origin: LinkOrigin.custom,
      note: '用户手动添加',
      removable: true,
    );
    _links.add(link);
    await _persist();
    notifyListeners();
    await probeOne(link.id);
  }

  Future<void> removeCustomLink(String id) async {
    _links.removeWhere((l) => l.id == id && l.origin == LinkOrigin.custom);
    if (_activeId == id) {
      _activeId = _links.first.id;
    }
    await _persist();
    notifyListeners();
  }

  /// 业务请求失败时由 ApiClient 调用：挑一条已探测为畅通的备用链路
  bool handleFailure(String failedLinkId) {
    if (!autoFallback) return false;
    final failed = _byId(failedLinkId);
    if (failed != null) {
      final streak = (_failureStreak[failedLinkId] ?? 0) + 1;
      _failureStreak[failedLinkId] = streak;
      if (streak >= _offlineAfterFailures && failed.isOnline) {
        failed.health = LinkHealth.offline;
        failed.detail = '业务请求连续失败';
        failed.checkedAt = DateTime.now();
        if (kDebugMode) {
          debugPrint('[route] ${failed.name} 连续失败 $streak 次，标记为不可达');
        }
      }
    }

    final online = _links
        .where((l) => l.isOnline && l.id != failedLinkId)
        .toList()
      ..sort(
          (a, b) => (a.latencyMs ?? 999999).compareTo(b.latencyMs ?? 999999));
    if (online.isEmpty) {
      // 没有可用候选：后台重新探测一次并重新择优，让应用能从启动时选错线路里自己恢复
      unawaited(_recover());
      return false;
    }
    _failureStreak.remove(online.first.id);
    _activeId = online.first.id;
    lastNotice = '请求失败，已自动切换到 ${online.first.name}';
    notifyListeners();
    return true;
  }

  /// 全部候选都不可用时的自愈：重新探活 → 重新择优 → 持久化
  Future<void> _recover() async {
    if (_recovering) return;
    // 冷却：一批请求同时失败会连续触发自愈，探测本身很贵（弱网下十几秒），15s 内只做一次
    final last = _lastRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _recovering = true;
    _lastRecoverAt = DateTime.now();
    try {
      await probeAll();
      _resolveActive();
      await _persist();
      if (kDebugMode) {
        debugPrint('[route] 自愈完成，当前链路：${activeLink.name}'
            '（在线 $onlineCount/${_links.length}）');
      }
    } finally {
      _recovering = false;
      _revision++;
      notifyListeners();
    }
  }

  void addLog(RequestLog log) => _addLog(log);

  /// 业务请求成功：清零该线路的失败计数
  void noteSuccess(String linkId) {
    if (_failureStreak.remove(linkId) != null && kDebugMode) {
      debugPrint('[route] $linkId 业务请求成功，失败计数清零');
    }
  }

  void _addLog(RequestLog log) {
    logs.insert(0, log);
    if (logs.length > 60) logs.removeRange(60, logs.length);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

/// _ProbeResult — 一次探测的结果
class _ProbeResult {
  final bool ok;
  final int? latencyMs;
  final String detail;

  /// 本次探测实际耗时：用来判断快速失败还是跑满超时，前者值得重试，后者重试只会白白拖长启动时间
  final int elapsedMs;
  const _ProbeResult(this.ok, this.latencyMs, this.detail,
      {this.elapsedMs = 0});
}
