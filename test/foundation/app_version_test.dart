import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/models/app_version.dart';
import 'package:mankafe/services/device_profile.dart';

/// `/api/v3/system/appVersion/last` 的解析与版本比较。
///
/// 这段逻辑决定设置页显示「有更新 / 已是最新」，也是「自定义请求版本号」
/// 之后仍然能自洽的基础，所以单独钉住行为。
void main() {
  group('compareAppVersion', () {
    test('逐段按数字比，3.1.1 高于 3.1.0', () {
      expect(compareAppVersion('3.1.1', '3.1.0'), 1);
      expect(compareAppVersion('3.1.0', '3.1.1'), -1);
      expect(compareAppVersion('3.1.0', '3.1.0'), 0);
    });

    test('不能退化成字符串比较：3.1.10 > 3.1.9', () {
      expect(compareAppVersion('3.1.10', '3.1.9'), 1);
      expect(compareAppVersion('3.10', '3.9'), 1);
    });

    test('段数不同按缺省 0 补齐', () {
      expect(compareAppVersion('3.2', '3.2.0'), 0);
      expect(compareAppVersion('3.2.1', '3.2'), 1);
    });

    test('空串按 0 处理，非数字段被忽略', () {
      expect(compareAppVersion('', ''), 0);
      expect(compareAppVersion('3.1.0', ''), 1);
      expect(compareAppVersion('', '3.1.0'), -1);
      expect(compareAppVersion('3.1.1-beta', '3.1.0'), 1);
    });
  });

  group('AppVersionSnapshot', () {
    /// 2026-11-15 线上原样返回。
    final payload = <String, dynamic>{
      'android': {
        'name': 'Android 正式版',
        'update': true,
        'version': '3.1.1',
        'url':
            'https://s3.mangafunb.fun/project/apk/copy/copymanga.release_20261110_3.1.1.apk',
        'forced': false,
      },
      'ios': {
        'name': 'IOS版',
        'update': false,
        'version': '',
        'url': '',
        'forced': false,
      },
      'androidTest': {
        'name': 'Android 舊版',
        'update': false,
        'forced': false,
      },
    };

    test('按渠道解析，android 带下载地址', () {
      final snapshot = AppVersionSnapshot.fromResults(payload);
      expect(snapshot.android.name, 'Android 正式版');
      expect(snapshot.android.version, '3.1.1');
      expect(snapshot.android.update, isTrue);
      expect(snapshot.android.forced, isFalse);
      expect(snapshot.android.hasDownload, isTrue);
      expect(snapshot.ios.hasDownload, isFalse);
    });

    test('androidTest 缺 version/url 时不炸，按空串处理', () {
      final snapshot = AppVersionSnapshot.fromResults(payload);
      expect(snapshot.androidTest.version, '');
      expect(snapshot.androidTest.hasDownload, isFalse);
      expect(snapshot.androidTest.name, 'Android 舊版');
    });

    test('异常输入退化为空快照', () {
      final snapshot = AppVersionSnapshot.fromResults('oops');
      expect(snapshot.android.version, '');
      expect(snapshot.android.hasDownload, isFalse);
      expect(
        AppVersionSnapshot.fromResults(const <String, dynamic>{})
            .android
            .name,
        '',
      );
    });
  });

  group('DeviceProfile 请求版本覆盖', () {
    tearDown(() {
      DeviceProfile.customVersionEnabled = false;
      DeviceProfile.customVersion = DeviceProfile.version;
      DeviceProfile.customVersionCode = DeviceProfile.versionCode;
    });

    test('默认使用本地版本', () {
      expect(DeviceProfile.effectiveVersion, '3.1.0');
      expect(DeviceProfile.effectiveVersionCode, '84');
      expect(DeviceProfile.effectiveUserAgent, 'COPY/3.1.0');
      expect(DeviceProfile.effectiveReferer, 'com.copymanga.app-3.1.0');
    });

    test('自定义后四个字段一起变，UA/referer 不会自相矛盾', () {
      DeviceProfile.customVersionEnabled = true;
      DeviceProfile.customVersion = '3.1.1';
      DeviceProfile.customVersionCode = '85';
      expect(DeviceProfile.effectiveVersion, '3.1.1');
      expect(DeviceProfile.effectiveVersionCode, '85');
      expect(DeviceProfile.effectiveUserAgent, 'COPY/3.1.1');
      expect(DeviceProfile.effectiveReferer, 'com.copymanga.app-3.1.1');
    });

    test('空输入回落到真实版本，不会把请求头刷成空串', () {
      DeviceProfile.customVersionEnabled = true;
      DeviceProfile.customVersion = '   ';
      DeviceProfile.customVersionCode = '';
      expect(DeviceProfile.effectiveVersion, '3.1.0');
      expect(DeviceProfile.effectiveVersionCode, '84');
    });
  });
}
