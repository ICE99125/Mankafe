import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/history_screen.dart';
import 'package:mankafe/theme/app_theme.dart';

/// 「编辑」底部菜单的版式基准图。
///
/// 不校验业务逻辑，只把 [EditorSheet] 放进 360x640dp 的手机视口里渲染一遍出图，
/// 方便在没有真机 / 模拟器时核对 MD3 版式：28dp 顶圆角、语义色图标底、
/// 行高、分组件间距、取消按钮的落位。
///
/// 出图：
///   flutter test test/widgets/editor_sheet_preview_test.dart --update-goldens
/// 产物：
///   test/widgets/goldens/editor_sheet_360.png
void main() {
  testWidgets('编辑底部菜单在 360dp 宽下的版式', (tester) async {
    await _loadFont('Roboto', _windowsFont('simhei.ttf'));
    await _loadFont('MaterialIcons', _materialIconsFont());

    // 1080x1920 / dpr 3 = 360x640dp，跟截图里那台机器同一档逻辑宽度。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final theme = AppTheme.light(AppTheme.seedOf(0)); // 默认「晴空蓝」种子
    final previewKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            return Scaffold(
              backgroundColor: scheme.surface,
              body: RepaintBoundary(
                key: previewKey,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _SheetFrame(
                      child: EditorSheet(
                        kinds: const [
                          MediaKind.comic,
                          MediaKind.novel,
                          MediaKind.photo,
                          MediaKind.animation,
                        ],
                        labels: const ['漫画', '轻小说', '写真集', '动画'],
                        onClear: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/editor_sheet_360.png'),
    );
    // toImage 要走真实的光栅化，在假异步里会一直挂住，必须放进 runAsync。
    await tester.runAsync(() async {
      await _writePng(previewKey, 'screenshots/editor_sheet_md3.png',
          pixelRatio: 3);
    });
  });
}

/// 把预览再导一份 3x 的 PNG 到 `screenshots/`，方便直接发给别人看版式。
Future<void> _writePng(GlobalKey key, String path,
    {required double pixelRatio}) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) throw StateError('导出 PNG 失败：$path');
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

/// 复刻 `showModalBottomSheet` 给这块内容套的那层「sheet 壳」：
/// surfaceContainerLow 底面 + 28dp 顶圆角 + 32x4 拖拽把手。
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 测试环境默认只有 Ahem（每个字都是方块），要看真中文得自己加载字体。
Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('字体缺失，无法出图：$path');
  }
  final bytes = file.readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

String _windowsFont(String name) {
  final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
  return '$windir\\Fonts\\$name';
}

/// Material 图标字体在 Flutter SDK 的缓存里，`flutter test` 会注入 FLUTTER_ROOT。
String _materialIconsFont() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT 未设置，找不到 MaterialIcons');
  return '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}
