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
import 'package:mankafe/widgets/brand_header.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 动画频道的「题材胶囊 + 排序」滚到顶以后要钉在顶栏下沿。
///
/// 原来这两行是普通 sliver，跟着列表一路滚走；用户要求滚到顶时固定住并换成
/// 毛玻璃。这里挂真实的 [CatalogScreen]（动画频道），只把 HTTP 换成 MockClient，
/// 断言：
/// - 滚动前胶囊躺在营销区块（轮播 / 推荐 / 专题）下面；
/// - 往上滚一大段之后胶囊仍然在屏幕上，且正好停在顶栏下沿（测试里
///   MediaQuery 顶部 padding 为 0，顶栏 = 64 + 56 = 120dp）；
/// - 钉住时那块是毛玻璃（BrandBar + 筛选头各一层 BackdropFilter）。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _StickyHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  _StickyHarness() {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/h5/cartoonIndex') {
        return _json({
          'banners': [
            {
              'type': 5,
              'cover': 'https://st.mangafunb.fun/t/banner-1/cover/1.jpg',
              'brief': '横幅一',
              'comic': {'path_word': 'banner-one', 'name': '横幅一'},
            },
          ],
          'topics': {
            'list': [
              {
                'title': '2026年10月秋季新番',
                'period': '秋季',
                'cover': 'https://st.mangafunb.fun/t/topic-1/cover/1.jpg',
                'path_word': 'autumn-2026',
              },
            ],
            'total': 1,
          },
          'tags': [],
          'ordering': [],
          'recCartoons': {
            'list': [
              _entry('首屏动画A', 'cartoon-first'),
              _entry('首屏动画B', 'cartoon-second'),
              _entry('首屏动画C', 'cartoon-third'),
            ],
            'total': '63',
            'limit': '3',
            'offset': '0',
          },
        });
      }
      if (path == '/api/v3/theme/cartoon/count') {
        return _json({
          'list': [
            {'name': '奇幻', 'path_word': 'qihuan', 'count': 3},
            {'name': '冒险', 'path_word': 'maoxian', 'count': 2},
            {'name': '校园', 'path_word': 'xiaoyuan', 'count': 1},
          ],
        });
      }
      if (path == '/api/v3/cartoons') {
        return _json({
          'list': [
            for (var i = 0; i < 30; i++) _entry('网格作品$i', 'grid-$i'),
          ],
          'total': '60',
          'limit': '21',
          'offset': '0',
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
          'years': '2026-11-15',
          'count': 12,
          'popular': 100,
        },
      };

  static http.Response _json(Map<String, dynamic> results) => http.Response(
        jsonEncode({
          'code': 200,
          'message': '请求成功',
          'results': results,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
}

Future<void> _pumpCatalog(
  WidgetTester tester,
  _StickyHarness h,
  ValueNotifier<bool> scrolled,
) async {
  tester.view.physicalSize = const Size(360, 800);
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
      home: BrandBarScrollScope(
        scrolled: scrolled,
        child: const Scaffold(
          body: CatalogScreen(kind: CatalogKind.animation),
        ),
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

  testWidgets('动画频道：题材胶囊滚到顶后钉在顶栏下沿，并切成毛玻璃', (tester) async {
    final h = _StickyHarness();
    final scrolled = ValueNotifier<bool>(false);
    addTearDown(scrolled.dispose);
    await _pumpCatalog(tester, h, scrolled);

    // 顶栏高度：状态栏 0 + 标题 64 + 搜索 56。
    const barHeight = 120.0;

    scrolled.value = true;
    await tester.pump();

    // 先往上滚一段，让胶囊行从营销区块里露出来（此时还没到顶）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 200));
    final chip = find.text('奇幻');
    expect(chip, findsOneWidget);
    final scrolling = tester.getTopLeft(chip).dy;
    expect(scrolling, greaterThan(barHeight + 100));

    // 再滚一大段：胶囊应该停住不动，而不是继续往上跑出屏幕。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 200));

    // 滚动后胶囊仍在屏幕上，而且停在顶栏下沿那一块（不是钻到顶栏背后）。
    expect(chip, findsOneWidget);
    final pinned = tester.getTopLeft(chip).dy;
    expect(pinned, greaterThanOrEqualTo(barHeight));
    expect(pinned, lessThan(barHeight + 60));
    expect(pinned, lessThan(scrolling));

    // 钉住的是毛玻璃：顶栏一层 + 筛选头一层。
    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });
}
