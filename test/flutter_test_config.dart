import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mankafe/l10n/app_localizations.dart';

/// 整个 `test/` 目录的入口：跑任何用例前先把 `assets/i18n/*.json` 读进来，
/// 这样页面里的 `t.xxx` 在测试里和真机一样能拿到中文/英文，无需每个用例自己加载。
///
/// 走磁盘而不是 rootBundle，是为了测试不依赖资源打包顺序，读坏文件也能直接看到报错。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory('assets/i18n');
  if (root.existsSync()) {
    for (final lang in root.listSync().whereType<Directory>()) {
      final code = lang.path.split(Platform.pathSeparator).last;
      for (final file in lang.listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        AppLocalizations.addJson(code, file.readAsStringSync());
      }
    }
  }

  await testMain();
}
