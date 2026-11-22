import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/auth_user.dart';
import 'package:mankafe/screens/history_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/skeleton.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浏览记录页的两张版式图（360dp 宽，无真机时核对懒加载手感）：
///   1. 首屏骨架（`screenshots/history_skeleton.png`）
///   2. 滚到底：第三页条目 + 「已经到底了」（`screenshots/history_paged.png`）
///
/// 出图：
///   flutter test test/screens/history_preview_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('浏览记录：骨架屏 + 分页网格 版式预览', (tester) async {
    await _loadFont('Roboto', _windowsFont('simhei.ttf'));
    await _loadFont('MaterialIcons', _materialIconsFont());

    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState();
    await state.load();
    await state.saveSession('token', const AuthUser(userId: '1'));

    const total = 46;
    // 请求先卡住，好让第一张图就是骨架屏本身。
    final gate = Completer<void>();
    final client = MockClient((request) async {
      await gate.future;
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      final items = <Map<String, dynamic>>[
        for (var i = offset; i < offset + 21 && i < total; i++)
          {
            'id': i,
            'last_chapter_id': 1,
            'last_chapter_name': '第 ${i + 1} 话',
            'comic': {
              'name': '作品${(i + 1).toString().padLeft(2, '0')}',
              'path_word': 'pw$i',
              'cover': '',
              'popular': 1000 * (i + 1),
              'datetime_updated': '2026-11-15 10:00:00',
            },
          },
      ];
      return http.Response(
        jsonEncode({
          'code': 200,
          'message': 'ok',
          'results': {
            'list': items,
            'total': total,
            'limit': 21,
            'offset': offset,
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final routes = RouteManager()..autoFallback = false;
    final repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );

    final key = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          Provider<Repository>.value(value: repo),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light(AppTheme.seedOf(0)),
          home: RepaintBoundary(key: key, child: const HistoryScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MediaGridSkeleton), findsOneWidget);
    await tester.runAsync(() async {
      await _writePng(key, 'screenshots/history_skeleton.png', pixelRatio: 3);
    });

    // 放行请求：先把三页拉完，再滚到底截第二张。
    gate.complete();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (i == 0) continue; // 第一轮只等首屏回来
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1400));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('已经到底了'), findsOneWidget);

    await tester.runAsync(() async {
      await _writePng(key, 'screenshots/history_paged.png', pixelRatio: 3);
    });
  });
}

Future<void> _writePng(GlobalKey key, String path,
    {required double pixelRatio}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) throw StateError('导出 PNG 失败：$path');
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

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

String _materialIconsFont() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT 未设置，找不到 MaterialIcons');
  return '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
