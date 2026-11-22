/// AppVersionChannel — 版本下发频道，字段可能缺失
class AppVersionChannel {
  final String name;
  final String version;
  final String url;
  final bool update;
  final bool forced;

  const AppVersionChannel({
    this.name = '',
    this.version = '',
    this.url = '',
    this.update = false,
    this.forced = false,
  });

  factory AppVersionChannel.fromJson(Object? json) {
    if (json is! Map) return const AppVersionChannel();
    final map = Map<String, dynamic>.from(json);
    return AppVersionChannel(
      name: _text(map['name']),
      version: _text(map['version']),
      url: _text(map['url']),
      update: map['update'] == true,
      forced: map['forced'] == true,
    );
  }

  static String _text(Object? value) =>
      value == null ? '' : value.toString().trim();

  bool get hasDownload => url.isNotEmpty;
}

/// AppVersionSnapshot — 三个平台的版本信息
class AppVersionSnapshot {
  final AppVersionChannel android;
  final AppVersionChannel ios;
  final AppVersionChannel androidTest;

  const AppVersionSnapshot({
    this.android = const AppVersionChannel(),
    this.ios = const AppVersionChannel(),
    this.androidTest = const AppVersionChannel(),
  });

  factory AppVersionSnapshot.fromResults(Object? results) {
    if (results is! Map) return const AppVersionSnapshot();
    final map = Map<String, dynamic>.from(results);
    return AppVersionSnapshot(
      android: AppVersionChannel.fromJson(map['android']),
      ios: AppVersionChannel.fromJson(map['ios']),
      androidTest: AppVersionChannel.fromJson(map['androidTest']),
    );
  }
}

/// 按数字段比较版本号，3.1.10 大于3.1.9
int compareAppVersion(String a, String b) {
  final pa = _numericSegments(a);
  final pb = _numericSegments(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

List<int> _numericSegments(String version) => version
    .split(RegExp(r'[^0-9]+'))
    .where((s) => s.isNotEmpty)
    .map(int.parse)
    .toList(growable: false);
