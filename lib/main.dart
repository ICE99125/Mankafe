import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'l10n/app_localizations.dart';
import 'services/proxy_config.dart';
import 'utils/frame_kick.dart';

/// 把 Flutter 错误与堆栈写入 <cache>/flutter_error.log
void _installErrorRecorder() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    try {
      final file = File('${Directory.systemTemp.path}/flutter_error.log');
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.writeAsStringSync('', flush: true);
      }
      file.writeAsStringSync(
        '\n===== ${DateTime.now()} =====\n$details\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 落盘失败不影响业务
    }
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorRecorder();
  // 读取界面文案，首帧就能显示正确文案
  await AppLocalizations.load();
  // 先恢复代理再建 Provider/ApiClient，保证首个 HttpClient 带上代理
  await ProxyConfig.restore();
  // 虚拟屏 vsync 不送达时兜底出帧
  FrameHeartbeat.start();
  runApp(const MankafeApp());
}
