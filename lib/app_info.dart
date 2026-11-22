/// AppInfo — 本客户端版本信息，需与 pubspec.yaml 的 version 保持一致
class AppInfo {
  AppInfo._();

  /// 版本号，不含 v 前缀与构建号
  static const String version = '1.0.0';

  /// 构建号，对应 pubspec version 里 + 后面的部分
  static const String buildNumber = '1';

  /// 顶栏展示用的短标签，如 v1.0.0
  static const String versionLabel = 'v$version';

  /// 带构建号的完整展示串
  static const String fullLabel = '$versionLabel (build $buildNumber)';
}
