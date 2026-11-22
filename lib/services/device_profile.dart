import 'dart:math';

/// DeviceProfile — 设备指纹与客户端参数，集中在此处便于替换
class DeviceProfile {
  DeviceProfile._();

  /// HMAC-SHA256 密钥
  static const String tapString = '3af08590311032efe0660550a0563a53';

  /// 设备指纹；请求头 device 取 androidId，机型只在 deviceInfo
  static String _pseudoId = 'vDBkFuRE7DBw1U3v';

  static String get pseudoId => _pseudoId;
  static void setPseudoId(String value) {
    final v = value.trim();
    if (v.length >= 8) _pseudoId = v;
  }

  /// 生成16 位随机指纹，大小写字母 + 数字
  static String newPseudoId() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(16, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// 表单里的公共身份字段，写入接口都以 form body 提交
  static Map<String, String> formFields({String authorization = 'Token '}) => {
        'platform': '3',
        'authorization': authorization,
        'version': effectiveVersion,
        'source': source,
        'region': region,
        'webp': webp,
        'userAgent': effectiveUserAgent,
        'isGoogle': isGoogle,
        'pseudoID': pseudoId,
        'dt': dtBody,
        'tapString': tapString,
        'umString': umString,
        'buildTime': buildTime,
        'versionCode': effectiveVersionCode,
        'androidId': androidId,
        'referer': effectiveReferer,
        'deviceInfo': deviceInfo,
      };

  static const String umString = 'b4c89ca4104ea9a97750314d791520ac';
  static const String androidId = 'V417IR';
  static const String deviceInfo = 'V2203A-PD2203';
  static const String model = 'V2203A';

  /// 客户端版本号
  static const String version = '3.1.0';
  static const String versionCode = '84';

  /// 请求头版本号覆盖，只影响自报版本，重启失效
  static bool customVersionEnabled = false;
  static String customVersion = version;
  static String customVersionCode = versionCode;

  /// 当前实际发出的版本号，请求头与表单共用
  static String get effectiveVersion =>
      customVersionEnabled && customVersion.trim().isNotEmpty
          ? customVersion.trim()
          : version;

  static String get effectiveVersionCode =>
      customVersionEnabled && customVersionCode.trim().isNotEmpty
          ? customVersionCode.trim()
          : versionCode;

  /// UA / referer 里的版本号跟随自定义版本
  static String get effectiveUserAgent => 'COPY/$effectiveVersion';

  static String get effectiveReferer =>
      'com.copymanga.app-$effectiveVersion';
  static const String buildTime = '2025.05.22';
  static const String source = 'copyApp';
  static const String userAgent = 'COPY/3.1.0';
  static const String referer = 'com.copymanga.app-3.1.0';
  static const String region = '1';
  static const String webp = '1';
  static const String isGoogle = 'false';

  /// 图片静态主机兜底值，运行时优先用 network2 下发的值
  static const String fallbackImageHost = 's3.mangafunb.fun';

  static String _p2(int v) => v.toString().padLeft(2, '0');

  /// 请求头 dt：点分隔日期，如2026.11.09
  static String get dtHeader {
    final n = DateTime.now();
    return '${n.year}.${_p2(n.month)}.${_p2(n.day)}';
  }

  /// 表单 dt：UTC 时间，如2026-11-09 23:08:24.000Z
  static String get dtBody {
    final n = DateTime.now().toUtc();
    return '${n.year}-${_p2(n.month)}-${_p2(n.day)} '
        '${_p2(n.hour)}:${_p2(n.minute)}:${_p2(n.second)}.000Z';
  }
}
