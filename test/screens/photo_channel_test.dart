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
import 'package:mankafe/widgets/browse_widgets.dart';
import 'package:mankafe/widgets/paged_media.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 写真频道对齐原版：
/// - 顶栏一排分段（首页 / 全新上架 / 发现 / 排行榜），没有「数据来源」和方块按钮；
/// - 「全新上架」= `/api/v3/update/post/newest` 的三列网格，一页 18 条；
/// - 「发现」= 标签行（全部 / 单人 …）+ 更新时间 / 热度 + 网格，
///   数据走 `/api/v3/posts?mannequin=&tag=&ordering=`；
/// - 「排行榜」= 并排三个 tag（周榜 / 月榜 / 总榜单），没有「更多」按钮。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _PhotoHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  /// 每次请求过的 query，用来断言真的按原版口径带参数。
  final List<Map<String, String>> newestQueries = [];
  final List<Map<String, String>> postQueries = [];

  _PhotoHarness() {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/h5/postIndex') return _json(_postIndex());
      if (path == '/api/v3/tag/post/count') {
        return _json({
          'list': [
            {'name': '單人', 'path_word': 'danren', 'count': 42},
            {'name': '撩撥', 'path_word': 'liaobo', 'count': 17},
          ]
        });
      }
      if (path == '/api/v3/update/post/newest') {
        newestQueries.add(request.url.queryParameters);
        return _json(_newestPage(
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0,
        ));
      }
      if (path == '/api/v3/posts' || path == '/api/v3/search/posts') {
        postQueries.add(request.url.queryParameters);
        return _json(_postsPage(
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0,
        ));
      }
      return _json(_page('內容', 'x'));
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }

  static Map<String, dynamic> _comic(String name, String id) => {
        // 写真条目是扁平结构：路由标识是 uuid（没有 path_word），
        // 作者来自 mannequins[].name —— 和 /api/v3/posts 的真实返回一致。
        'uuid': id,
        'name': name,
        'cover': 'https://st.mangafunb.fun/t/$id/cover/1.jpg',
        'popular': 100,
        'mannequins': [
          {'name': '模特A', 'path_word': 'modela'}
        ],
        'datetime_updated': '2026-11-12 10:00:00',
      };

  static Map<String, dynamic> _postIndex() => {
        'banners': [
          {
            'type': 130,
            'cover': 'https://s3.mangafunb.fun/recommend/2026/11/b1.jpg',
            'brief': 'Byoru-飛霄',
            'out_uuid': '2020',
            'comic': {'name': '【越南coser】Byoru-飛霄', 'path_word': '2020'},
          },
          {
            'type': 130,
            'cover': 'https://s3.mangafunb.fun/recommend/2026/11/b2.jpg',
            'brief': 'Azami-尼祿泳裝',
            'out_uuid': '2019',
            'comic': {'name': '【越南coser】Azami-尼祿泳裝', 'path_word': '2019'},
          },
        ],
        'topics': {'list': [], 'total': 0},
        'rankWeekPosts': {
          'list': [
            {'popular': 34, 'post': _comic('周榜第一', 'rank-week-1')},
          ],
          'total': '43',
          'limit': '6',
          'offset': '0',
        },
        'rankMonthPosts': {
          'list': [
            {'popular': 583, 'post': _comic('月榜第一', 'rank-month-1')},
          ],
          'total': '199',
          'limit': '6',
          'offset': '0',
        },
        'newPosts': [
          {
            'datetime_created': '2026-11-10 18:09:28',
            'post': _comic('最新寫真B', 'photo-b'),
          },
        ],
      };

  /// `/api/v3/update/post/newest` 的信封：条目是 `{name, datetime_created, post}`。
  static Map<String, dynamic> _newestPage(int offset) => {
        'list': [
          for (var i = 0; i < 18 && offset + i < 12; i++)
            {
              'name': '上架 ${offset + i}',
              'datetime_created': '2026-11-13 10:00:00',
              'post': _comic('新上架${offset + i}', 'new-${offset + i}'),
            },
        ],
        'total': 12,
        'limit': 18,
        'offset': offset,
      };

  /// `/api/v3/posts` 的信封：条目是扁平 post 对象，total 40 条好验证续页。
  static Map<String, dynamic> _postsPage(int offset) => {
        'list': [
          for (var i = 0; i < 18 && offset + i < 40; i++)
            _comic('寫真${offset + i}', 'post-${offset + i}'),
        ],
        'total': 40,
        'limit': 18,
        'offset': offset,
      };

  static Map<String, dynamic> _page(String name, String id) => {
        'list': [_comic(name, id)],
        'total': 1,
        'limit': 21,
        'offset': 0,
      };

  static http.Response _json(Map<String, dynamic> results) => http.Response(
        jsonEncode({'code': 200, 'message': '请求成功', 'results': results}),
        200,
        headers: {'content-type': 'application/json'},
      );
}

/// 排序胶囊：按胶囊本体点击（Text 只是 label，点它不算命中胶囊）。
Finder _sortChip(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(ChoiceChip),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 顶栏分段 tab 里的文字：「全新上架」在首页正文里也有一个同名小标题，
/// 断言和点击都必须限定在 [BrandTabBar] 内，否则会命中两个。
Finder _tab(String label) => find.descendant(
      of: find.byType(BrandTabBar),
      matching: find.text(label),
    );

Future<void> _pumpPhoto(WidgetTester tester, _PhotoHarness h) async {
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
        body: CatalogScreen(kind: CatalogKind.photo),
      ),
    ),
  ));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('写真顶栏：没有「数据来源」和聚合方块，改成四个分段 tab', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    expect(find.text('数据来源'), findsNothing);
    expect(find.byIcon(Icons.dashboard_outlined), findsNothing);

    for (final label in ['首页', '全新上架', '发现', '排行榜']) {
      expect(_tab(label), findsOneWidget, reason: '分段「$label」应在顶栏里');
    }
    expect(find.byType(BrandTabBar), findsOneWidget);
  });

  testWidgets('写真首页：轮播在最上面 + 全新上架网格，没有接口说明和标签云', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    // 首页默认落在「首页」分段：轮播（postIndex 的 banners）必须渲染。
    expect(find.byType(CoverCarousel), findsOneWidget);

    // 之前 MediaIndexScreen 那套技术说明 / 「全部写真」入口 / 标签云都去掉了。
    expect(find.textContaining('GET /api/v3'), findsNothing);
    expect(find.textContaining('全部写真'), findsNothing);
    expect(find.textContaining('排序方式'), findsNothing);

    // 轮播下面直接是「全新上架」列表，数据走 update/post/newest。
    expect(find.text('全新上架'), findsWidgets);
    expect(h.newestQueries, isNotEmpty);
    expect(h.newestQueries.first['limit'], '18');
    expect(find.byType(MediaEntryCard), findsWidgets);
  });

  testWidgets('全新上架：走 update/post/newest，一页 18 条、没有「更多」按钮', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    await tester.tap(_tab('全新上架'));
    await _settle(tester);

    expect(h.newestQueries, isNotEmpty);
    final q = h.newestQueries.first;
    expect(q['limit'], '18', reason: '原版写真一页 18 条');
    expect(q['offset'], '0');
    expect(q.containsKey('date'), isTrue, reason: '原版接口带 date=');
    expect(find.byType(MediaEntryCard), findsWidgets);
    expect(find.text('新上架0'), findsWidgets);
    // 分段页里不应再出现「更多」入口。
    expect(find.text('更多'), findsNothing);
  });

  testWidgets('发现：标签行 + 更新時間 / 熱度排序，点标签走 posts?tag=', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    await tester.tap(find.text('发现'));
    await _settle(tester);

    // 之前那套「写真标签（N）」标题 + 接口说明已经删掉。
    expect(find.textContaining('写真标签'), findsNothing);
    expect(find.textContaining('/api/v3'), findsNothing);

    // 标签行：全部 + 服务端下发的标签（横向可滑）。
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('單人'), findsOneWidget);
    expect(find.text('撩撥'), findsOneWidget);

    // 排序行沿用 SortBar 的两个入口。
    expect(find.text('更新时间'), findsOneWidget);
    expect(find.text('热度'), findsOneWidget);

    // 默认「全部」：tag 为空、按更新时间倒序、一页 18 条。
    final first = h.postQueries.first;
    expect(first['tag'], '');
    expect(first['ordering'], '-datetime_updated');
    expect(first['limit'], '18');

    // 点「撩撥」→ 换成该标签的 path_word。
    h.postQueries.clear();
    await tester.tap(find.text('撩撥'));
    await _settle(tester);
    expect(h.postQueries, isNotEmpty);
    expect(h.postQueries.first['tag'], 'liaobo');
    expect(find.text('撩撥'), findsOneWidget);
  });

  testWidgets('发现：更新时间 / 热度都能升降序，方向靠 ordering 正负', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    await tester.tap(find.text('发现'));
    await _settle(tester);
    expect(h.postQueries.first['ordering'], '-datetime_updated',
        reason: '默认按更新时间降序');

    // 点「热度」：换维度，回到默认的降序。
    h.postQueries.clear();
    await tester.tap(_sortChip('热度'));
    await _settle(tester);
    expect(h.postQueries, isNotEmpty, reason: '换排序必须重新请求第一页');
    expect(h.postQueries.first['ordering'], '-popular');

    // 再点「热度」：原地翻成升序（不带负号）。
    h.postQueries.clear();
    await tester.tap(_sortChip('热度'));
    await _settle(tester);
    expect(h.postQueries.first['ordering'], 'popular');

    // 切回「更新时间」：又回到降序。
    h.postQueries.clear();
    await tester.tap(_sortChip('更新时间'));
    await _settle(tester);
    expect(h.postQueries.first['ordering'], '-datetime_updated');

    // 再点「更新时间」：升序。
    h.postQueries.clear();
    await tester.tap(_sortChip('更新时间'));
    await _settle(tester);
    expect(h.postQueries.first['ordering'], 'datetime_updated');
  });

  testWidgets('发现：列表滚到底自动续页（offset 18 → 36）', (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    await tester.tap(find.text('发现'));
    await _settle(tester);
    expect(h.postQueries.first['offset'], '0');

    for (var i = 0; i < 6; i++) {
      await tester.drag(
          find.byType(MediaEntryCard).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 200));
      if (h.postQueries.any((q) => q['offset'] == '18')) break;
    }
    expect(h.postQueries.any((q) => q['offset'] == '18'), isTrue,
        reason: '滚到底应该自动请求第二页（没有「更多」按钮）');
  });

  testWidgets('排行榜：并排三个 tag、无「更多」，总榜单走 posts?ordering=-popular',
      (tester) async {
    final h = _PhotoHarness();
    await _pumpPhoto(tester, h);

    await tester.tap(find.text('排行榜'));
    await _settle(tester);

    // 三个并排 tag 齐全，且没有「更多」。
    expect(find.text('周榜'), findsOneWidget);
    expect(find.text('月榜'), findsOneWidget);
    expect(find.text('总榜单'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
    expect(find.text('查看全部'), findsNothing);

    // 默认周榜：第一屏是 postIndex 下发的那 6 条真实榜单。
    expect(find.text('周榜第一'), findsWidgets);

    // 周榜 6 条撑不满一屏时必须自己继续补页，不能「6 条就到底」。
    for (var i = 0; i < 6 && h.postQueries.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(h.postQueries, isNotEmpty, reason: '周榜 6 条之后要继续懒加载');
    expect(h.postQueries.first['ordering'], '-popular');

    // 切月榜。
    await tester.tap(find.text('月榜'));
    await _settle(tester);
    expect(find.text('月榜第一'), findsWidgets);

    // 切总榜单：真的走 /api/v3/posts?ordering=-popular。
    h.postQueries.clear();
    await tester.tap(find.text('总榜单'));
    await _settle(tester);
    expect(h.postQueries, isNotEmpty);
    expect(h.postQueries.first['ordering'], '-popular',
        reason: '不带负号的 popular 实测是升序，必须用 -popular');
    expect(h.postQueries.first['limit'], '18');
    expect(find.text('寫真0'), findsWidgets);
  });
}
