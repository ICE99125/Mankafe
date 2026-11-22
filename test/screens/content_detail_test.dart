import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/animation_play_screen.dart';
import 'package:mankafe/screens/content_detail_screen.dart';
import 'package:mankafe/screens/content_reader_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/services/shelf_service.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 轻小说 / 动画详情页的「开始阅读 / 续读」入口。
///
/// 漫画详情页一直有「续读 第 12 话 + 收藏」这一行，内容详情页原先只有收藏，
/// 想接着看必须自己翻目录。这里钉住三件事：
/// - 没有浏览记录 → 「开始阅读」，点开第一卷；
/// - 有记录 → 「续读 第二卷」，点开就是那一卷，并把进度写进浏览记录；
/// - 浏览记录按类型取，同标识的另一类内容不能把进度串过来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('没有浏览记录：主按钮是「开始阅读」，点开第一卷', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();

    await tester.pumpWidget(_app(h, state, MediaKind.novel, 'book-1'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.textContaining('续读'), findsNothing);

    await tester.tap(find.text('开始阅读'));
    await _settle(tester);

    expect(find.byType(ContentReaderScreen), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('第01卷')),
      findsOneWidget,
    );
    // 读过就记进度：详情页下次回来才有的续读。
    final entry = state.lastReadOf('book-1', kind: MediaKind.novel);
    expect(entry, isNotNull);
    expect(entry!.chapterUuid, 'vol-1');
    expect(entry.name, '轻小说 A', reason: '作品名由详情页带进阅读器');
  });

  testWidgets('有浏览记录：显示「续读 第二卷」，点开直接落到那一卷', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    await state.recordRead(
      pathWord: 'book-1',
      chapterUuid: 'vol-2',
      chapterName: '第02卷',
      page: 0,
      name: '轻小说 A',
      cover: 'https://s3.example.com/book.jpg',
      kind: MediaKind.novel,
    );

    await tester.pumpWidget(_app(h, state, MediaKind.novel, 'book-1'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('续读 第02卷'), findsOneWidget);
    expect(find.text('开始阅读'), findsNothing);

    await tester.tap(find.text('续读 第02卷'));
    await _settle(tester);

    expect(find.byType(ContentReaderScreen), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('第02卷')),
      findsOneWidget,
    );
  });

  testWidgets('同标识的漫画记录不会串到轻小说：仍从第一卷开始', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    // 漫画与轻小说碰巧共用同一个 path_word，漫画读到第 30 话。
    await state.recordRead(
      pathWord: 'book-1',
      chapterUuid: 'comic-ch-30',
      chapterName: '第 30 话',
      page: 5,
      name: '同名漫画',
      kind: MediaKind.comic,
    );

    await tester.pumpWidget(_app(h, state, MediaKind.novel, 'book-1'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('开始阅读'), findsOneWidget, reason: '漫画进度不属于轻小说');
    expect(find.textContaining('第 30 话'), findsNothing);
  });

  testWidgets('动画：有记录显示「续看 第02集」，点击进播放页', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    await state.recordRead(
      pathWord: 'cartoon-1',
      chapterUuid: 'ep-2',
      chapterName: '第02集',
      page: 0,
      name: '动画 A',
      kind: MediaKind.animation,
    );

    await tester.pumpWidget(_app(h, state, MediaKind.animation, 'cartoon-1'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('续看 第02集'), findsOneWidget);

    await tester.tap(find.text('续看 第02集'));
    await _settle(tester);

    expect(find.byType(AnimationPlayScreen), findsOneWidget);
  });
}

/// 等一帧 FutureBuilder 的数据 + 一次页面跳转动画。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _app(_Harness h, AppState state, MediaKind kind, String pathWord) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<RouteManager>.value(value: h.routes),
      Provider<Repository>.value(value: h.repo(state)),
      ChangeNotifierProvider<ShelfService>(
        create: (_) => ShelfService(repo: h.repo(state), state: state),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(AppTheme.seedOf(0)),
      home: ContentDetailScreen(kind: kind, pathWord: pathWord),
    ),
  );
}

/// 缓存必须关掉：`HttpCache` 会去建目录，测试环境里会永久挂住。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  final RouteManager routes = RouteManager()..autoFallback = false;

  Repository repo(AppState state) {
    final client = MockClient((request) async {
      final path = request.url.path;

      if (path == '/api/v3/book/book-1') {
        return _json({
          'book': {
            'uuid': 'book-uuid',
            'path_word': 'book-1',
            'name': '轻小说 A',
            'cover': 'https://s3.example.com/book.jpg',
            'author': ['作者 A'],
            'brief': '简介',
            'datetime_updated': '2026-11-10',
          },
        });
      }
      if (path == '/api/v3/book/book-1/volumes') {
        return _json({
          'list': [
            {'uuid': 'vol-1', 'name': '第01卷', 'sort': 1},
            {'uuid': 'vol-2', 'name': '第02卷', 'sort': 2},
          ],
          'total': 2,
        });
      }
      if (path.startsWith('/api/v3/book/book-1/volume/')) {
        final id = path.split('/').last;
        return _json({
          'volume': {
            'uuid': id,
            'name': id == 'vol-2' ? '第02卷' : '第01卷',
            'contents': [
              {'name': '正文', 'content': '这一卷的正文。'}
            ],
          },
        });
      }
      if (path == '/api/v3/cartoon/cartoon-1') {
        return _json({
          'cartoon': {
            'uuid': 'cartoon-uuid',
            'path_word': 'cartoon-1',
            'name': '动画 A',
            'cover': '',
            'brief': '',
            'datetime_updated': '2026-11-10',
            'mannequins': <dynamic>[],
          },
        });
      }
      if (path == '/api/v3/cartoon/cartoon-1/chapters') {
        return _json({
          'list': [
            {
              'uuid': 'ep-1',
              'name': '第01集',
              'sort': 1,
              'count': 24,
              'lines': [
                {'name': '线路一', 'path_word': 'line1', 'config': true}
              ],
            },
            {
              'uuid': 'ep-2',
              'name': '第02集',
              'sort': 2,
              'count': 24,
              'lines': [
                {'name': '线路一', 'path_word': 'line1', 'config': true}
              ],
            },
          ],
          'total': 2,
        });
      }
      if (path == '/api/v3/cartoon/cartoon-1/chapter/ep-2') {
        // 没有播放地址：播放页展示服务端原话，不建 VideoPlayer。
        return _json({
          'chapter': {'uuid': 'ep-2', 'name': '第02集', 'video': ''},
        });
      }
      return _json({
        'list': <dynamic>[],
        'total': 0,
        'limit': 21,
        'offset': 0,
      });
    });
    return Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
        jsonEncode({'code': 200, 'message': 'ok', 'results': body}),
        200,
        headers: {'content-type': 'application/json'},
      );
}
