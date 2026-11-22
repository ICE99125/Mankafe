/// LinkOrigin — 链路来源：内置候选 / 线路下发 / 自定义
enum LinkOrigin { builtin, discovered, custom }

/// LinkHealth — 线路健康状态
enum LinkHealth { unknown, checking, online, offline }

/// RouteMode — 线路选择模式，自动择优或手动锁定
enum RouteMode { auto, manual }

/// LinkOrigin 的中文标签
extension LinkOriginX on LinkOrigin {
  String get label => switch (this) {
        LinkOrigin.builtin => '内置候选',
        LinkOrigin.discovered => '线路下发',
        LinkOrigin.custom => '自定义',
      };
}

/// RouteMode 的中文标签
extension RouteModeX on RouteMode {
  String get label => this == RouteMode.auto ? '自动择优' : '手动锁定';
}

/// RouteLink — 一条 API 线路及其健康状态
class RouteLink {
  final String id;
  final String name;
  final String baseUrl;
  final String note;
  final LinkOrigin origin;
  final bool removable;

  LinkHealth health;
  int? latencyMs;
  String? detail;
  DateTime? checkedAt;

  RouteLink({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.origin,
    this.note = '',
    this.removable = false,
    this.health = LinkHealth.unknown,
    this.latencyMs,
    this.detail,
    this.checkedAt,
  });

  bool get isOnline => health == LinkHealth.online;

  String get host {
    final uri = Uri.tryParse(baseUrl);
    return uri == null ? baseUrl : uri.host;
  }

  String get healthLabel => switch (health) {
        LinkHealth.unknown => '未检测',
        LinkHealth.checking => '检测中',
        LinkHealth.online => '畅通',
        LinkHealth.offline => '不可达',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'note': note,
        'removable': removable,
      };

  factory RouteLink.customFromJson(Map<String, dynamic> json) => RouteLink(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '自定义链路').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        note: (json['note'] ?? '').toString(),
        origin: LinkOrigin.custom,
        removable: true,
      );

  RouteLink cloneWith({LinkHealth? health, int? latencyMs, String? detail}) =>
      RouteLink(
        id: id,
        name: name,
        baseUrl: baseUrl,
        note: note,
        origin: origin,
        removable: removable,
        health: health ?? this.health,
        latencyMs: latencyMs,
        detail: detail,
        checkedAt: DateTime.now(),
      );
}

/// Network2Info — /api/v3/system/network2 的下发结果
class Network2Info {
  final String api;
  final List<String> apiList;
  final String cdn;
  final String marketing;
  final List<String> contentHosts;
  final bool inMainland;
  final String mobileRegion;
  final bool network2;
  final int timestamp;
  final DateTime fetchedAt;

  const Network2Info({
    required this.api,
    required this.apiList,
    this.cdn = '',
    this.marketing = '',
    this.contentHosts = const [],
    this.inMainland = true,
    this.mobileRegion = 'CN',
    this.network2 = true,
    this.timestamp = 0,
    required this.fetchedAt,
  });

  factory Network2Info.fromJson(Map<String, dynamic> json) => Network2Info(
        api: _first(json['api']),
        apiList: _strings(json['api_list']),
        // 图片主机字段名是 static
        cdn: _first(json['static'] ?? json['cdn']),
        // 营销域名在 share 字段
        marketing: _first(json['marketing'] ?? json['share']),
        contentHosts: _strings(json['content_hosts']),
        inMainland: json['in_mainland'] == true,
        mobileRegion: (json['mobile_region'] ?? '').toString(),
        network2: json['network2'] != false,
        timestamp: json['timestamp'] is int ? json['timestamp'] as int : 0,
        fetchedAt: DateTime.now(),
      );

  /// 摊平嵌套列表取第一个非空值
  static String _first(dynamic v) {
    if (v is List) {
      for (final item in v) {
        final s = _first(item);
        if (s.isNotEmpty) return s;
      }
      return '';
    }
    return v == null ? '' : v.toString().trim();
  }

  static List<String> _strings(dynamic v) {
    if (v is! List) return const [];
    final out = <String>[];
    void walk(dynamic node) {
      if (node is List) {
        for (final item in node) {
          walk(item);
        }
      } else {
        final s = node == null ? '' : node.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
    }

    walk(v);
    return out;
  }
}

/// RequestLog — 最近一次请求记录，用于请求日志
class RequestLog {
  final DateTime time;
  final String method;
  final String path;
  final String linkName;
  final int latencyMs;
  final int? status;
  final String? error;

  const RequestLog({
    required this.time,
    required this.method,
    required this.path,
    required this.linkName,
    required this.latencyMs,
    this.status,
    this.error,
  });

  bool get ok =>
      error == null && status != null && status! >= 200 && status! < 300;

  String get timeLabel => '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
