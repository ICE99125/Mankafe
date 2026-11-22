import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/app_info.dart';
import 'package:mankafe/services/device_profile.dart';

/// 钉住两套版本口径：
///
/// - 界面上的「本软件版本」= `1.0.0`、构建号 `1`，与 `pubspec.yaml` 一致；
/// - 请求头里自报的官方客户端版本 = `3.1.0` / `84`，不受界面版本影响。
///
/// 改界面版本时最容易顺手去动 `DeviceProfile`，那会把请求头也改成 1.0.0，
/// 服务端就可能认不出这个客户端，所以这里显式拦住。
void main() {
  test('本软件版本是 1.0.0，构建号 1，顶栏显示 v1.0.0', () {
    expect(AppInfo.version, '1.0.0');
    expect(AppInfo.buildNumber, '1');
    expect(AppInfo.versionLabel, 'v1.0.0');
    expect(AppInfo.fullLabel, 'v1.0.0 (build 1)');
  });

  test('请求头版本与界面版本分开，仍是 3.1.0 / 84', () {
    expect(DeviceProfile.version, '3.1.0');
    expect(DeviceProfile.versionCode, '84');
    expect(DeviceProfile.userAgent, 'COPY/3.1.0');
    expect(DeviceProfile.referer, 'com.copymanga.app-3.1.0');
  });

  test('AppInfo 与 pubspec.yaml 的 version 没有走偏', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final raw = lines
        .firstWhere((line) => line.startsWith('version:'))
        .substring('version:'.length)
        .trim();
    final parts = raw.split('+');
    expect(parts.first, AppInfo.version, reason: 'pubspec: $raw');
    expect(parts.length > 1 ? parts[1] : '0', AppInfo.buildNumber,
        reason: 'pubspec: $raw');
  });
}
