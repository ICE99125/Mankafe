import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/catalog_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「换一批」必须是**真的网络请求**。
///
/// 老实现在已经加载好的推荐池里取模轮转（`pool[(batch*3+i)%pool.length]`），
/// 池里只有 recCartoons 那三条时，点下去看到的还是同一批卡片——
/// 用户看到的现象就是「按钮没反应」。
///
/// 这里挂真实的 [CatalogScreen]（动画频道），只把 HTTP 换成 MockClient：
/// 断言点一次「换一批」会发出 `GET /api/v3/recs?pos=3200301&limit=3&offset=3`，
/// 并把返回的三条渲染出来；再点一次要到 offset=6。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _RecsHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  /// 记录每一次 /api/v3/recs 的 query，方便断言 offset 递进。
  final List<String> recsOffsets = [];

  _RecsHarness() {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/h5/cartoonIndex') {
        return _json({
          'banners': [],
          'topics': {'list': [], 'total': 0},
          'tags': [],
          'ordering': [],
          'recCartoons': {
            'list': [_entry('首屏动画A', 'cartoon-first')],
            'total': '63',
            'limit': '3',
            'offset': '0',
          },
        });
      }
      if (path == '/api/v3/recs') {
        final q = request.url.queryParameters;
        recsOffsets.add(q['offset'] ?? '');
        final offset = int.tryParse(q['offset'] ?? '') ?? 0;
        return _json({
          'list': [
            _entry('第$offset条', 'rec-$offset-a'),
            _entry('第${offset + 1}条', 'rec-$offset-b'),
            _entry('第${offset + 2}条', 'rec-$offset-c'),
          ],
          'total': '63',
          'limit': '3',
          'offset': '$offset',
        });
      }
      if (path == '/api/v3/theme/cartoon/count') {
        return _json({
          'list': [
            {'name': '奇幻', 'path_word': 'qihuan', 'count': 3}
          ]
        });
      }
      return _json({
        'list': [],
        'total': 0,
        'limit': 21,
        'offset': 0,
      });
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }

  static Map<String, dynamic> _entry(String name, String pathWord) => {
        'type': 5,
        'comic': {
          'path_word': pathWord,
          'name': name,
          'cover': 'https://st.mangafunb.fun/t/$pathWord/cover/1.jpg',
          'years': '2026-04-03',
          'count': 12,
          'popular': 100,
        },
      };

  static http.Response _json(Map<String, dynamic> results) => http.Response(
        jsonEncode({'code': 200, 'message': '请求成功', 'results': results}),
        200,
        headers: {'content-type': 'application/json'},
      );
}

Future<void> _pumpCatalog(WidgetTester tester, _RecsHarness h) async {
  tester.view.physicalSize = const Size(360, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: h.state),
      ChangeNotifierProvider<RouteManager>.value(value: h.routes),
      Provider<Repository>.value(value: h.repo),
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
      home: const Scaffold(
        body: CatalogScreen(kind: CatalogKind.animation),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('换一批：真的请求 /api/v3/recs，offset 按 3 递进并渲染新卡片', (tester) async {
    final h = _RecsHarness();
    await _pumpCatalog(tester, h);

    // 首屏来自 cartoonIndex 的 recCartoons，不发 recs。
    expect(find.text('首屏动画A'), findsOneWidget);
    expect(h.recsOffsets, isEmpty);

    await tester.tap(find.text('换一批'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 真请求，且参数就是抓包里的 pos/limit/offset。
    expect(h.recsOffsets, ['3']);
    expect(find.text('第3条'), findsOneWidget);
    expect(find.text('第4条'), findsOneWidget);
    expect(find.text('第5条'), findsOneWidget);
    expect(find.text('首屏动画A'), findsNothing);

    await tester.tap(find.text('换一批'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(h.recsOffsets, ['3', '6']);
    expect(find.text('第6条'), findsOneWidget);
    expect(find.text('第3条'), findsNothing);

    expect(tester.takeException(), isNull);
  });
}
