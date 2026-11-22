import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/discover_screen.dart';
import 'package:mankafe/screens/home_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/browse_widgets.dart';
import 'package:mankafe/widgets/skeleton.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本轮用户反馈的三件事的回归：
///   1. 发现页加载不要顶部进度条，要骨架屏；
///   2. 排行榜经常点不开（此前完全依赖 homeIndex2 的 rank 字段）；
///   3. 发现页 / 排行榜要能下拉刷新。
/// 另加一条：榜单名次徽章在真机上「看不清」的对比度修复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('发现页首次加载是整页骨架，不出现 LinearProgressIndicator', (tester) async {
    final h = _DiscoverHarness();
    await _pumpDiscover(tester, h);

    // 请求还挂着：题材行、地区行、排序栏、三列网格全部是骨架。
    expect(find.byType(DiscoverSkeleton), findsOneWidget);
    expect(find.byType(TextTabsSkeleton), findsOneWidget);
    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: '发现页加载态不允许再用顶部进度条');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 数据到达：骨架让位给真实标签和卡片，仍然没有进度条。
    h.gate.complete(_json(_comicsPage()));
    await _settle(tester, frames: 10);

    expect(find.byType(DiscoverSkeleton), findsNothing);
    expect(find.byType(RichGridCard), findsNWidgets(3));
    expect(find.byType(TextTabRow), findsNWidgets(2),
        reason: '题材行 + 地区行都应是真实标签');
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发现页支持下拉刷新：会重新请求结果与题材', (tester) async {
    final h = _DiscoverHarness();
    h.gate.complete(_json(_comicsPage()));
    await _pumpDiscover(tester, h);
    await _settle(tester, frames: 10);

    expect(find.byType(RichGridCard), findsNWidgets(3));
    final callsBefore = h.comicCalls;
    final tagCallsBefore = h.tagCalls;

    // 直接驱动 RefreshIndicator 的 onRefresh，避免 fling 的时序抖动。
    final indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await indicator.onRefresh();
    await _settle(tester, frames: 10);

    expect(h.comicCalls, greaterThan(callsBefore), reason: '下拉应重拉结果');
    expect(h.tagCalls, greaterThan(tagCallsBefore), reason: '下拉应重拉题材');
    expect(tester.takeException(), isNull);
  });

  testWidgets('榜单名次徽章：前三名实心高对比，不再用看不清的奖章图标', (tester) async {
    final theme = AppTheme.light(AppTheme.seedOf(0));
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: const Scaffold(
        body: Column(
          children: [
            RankBadge(rank: 1),
            RankBadge(rank: 2),
            RankBadge(rank: 3),
            RankBadge(rank: 4),
          ],
        ),
      ),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.workspace_premium_rounded), findsNothing,
        reason: '奖章中段镂空，白字压在上面几乎看不见');

    final scheme = theme.colorScheme;
    Color? background(int index) {
      final container = tester.widget<Container>(find
          .descendant(
            of: find.byType(RankBadge).at(index),
            matching: find.byType(Container),
          )
          .first);
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(background(0), scheme.tertiary);
    expect(background(1), scheme.primary);
    expect(background(2), scheme.secondary);
    expect(background(3), scheme.surfaceContainerHighest);

    // 数字要够大够粗，且用反色，不再 11 号白字。
    final first = tester.widget<Text>(find.text('1'));
    expect(first.style?.fontSize, 15);
    expect(first.style?.fontWeight, FontWeight.w900);
    expect(first.style?.color, scheme.onTertiary);
  });

  testWidgets('排行榜不依赖首页接口：homeIndex2 失败也能点开并加载真实榜单', (tester) async {
    final requested = <String>[];
    final h = _HomeHarness(requested, failHome: true);
    await _pumpHome(tester, h);
    await _settle(tester, frames: 8);

    // 首页接口挂了，但顶栏仍在，tab 可点。
    expect(find.text('排行榜'), findsOneWidget);
    await tester.tap(find.text('排行榜'));
    await _settle(tester, frames: 12);

    expect(
      requested.where((p) => p == '/api/v3/ranks').length,
      greaterThanOrEqualTo(1),
      reason: '排行榜应自己请求 /api/v3/ranks',
    );
    expect(find.byType(RankRow), findsWidgets, reason: '榜单条目必须真的渲染出来');
    expect(find.byType(RankListSkeleton), findsNothing);
    expect(find.byType(RefreshIndicator), findsWidgets, reason: '排行榜要支持下拉刷新');
    expect(tester.takeException(), isNull);
  });

  testWidgets('排行榜受众：男频 / 女频是 type=1 靠 audience_type 分，轻小说是 type=5',
      (tester) async {
    final h = _HomeHarness(<String>[], failHome: false);
    await _pumpHome(tester, h);
    await _settle(tester, frames: 8);

    await tester.tap(find.text('排行榜'));
    await _settle(tester, frames: 10);

    // 默认停在「男频 · 上升最快」（day 榜），不再是周榜。
    expect(h.rankQueries, isNotEmpty);
    expect(h.rankQueries.first['type'], '1');
    expect(h.rankQueries.first['audience_type'], 'male');
    expect(h.rankQueries.first['date_type'], 'day');
    expect(h.rankQueries.first['limit'], '18', reason: '原版榜单 18 条一页');

    // 女频：还是漫画榜，但受众换成 female。
    h.rankQueries.clear();
    await tester.tap(find.text('女频'));
    await _settle(tester, frames: 10);
    expect(h.rankQueries, isNotEmpty);
    expect(h.rankQueries.first['type'], '1');
    expect(h.rankQueries.first['audience_type'], 'female');

    // 轻小说：真发 type=5，解析 `book` 内层，并支持 18 条分页续拉。
    h.rankQueries.clear();
    await tester.tap(find.text('轻小说'));
    await _settle(tester, frames: 10);
    expect(h.rankQueries, isNotEmpty);
    expect(h.rankQueries.first['type'], '5', reason: '之前轻小说退化成热度列表，没走榜单接口');
    expect(find.byType(RankRow), findsWidgets);
    expect(find.text('輕小說0'), findsWidgets);

    // total=165、18 条一页，所以首屏之后不能显示「到底了」——
    // 分页请求本身（offset 0 → 18）由 test/network/rank_novel_test.dart 断言。
    expect(find.text('已经到底了'), findsNothing, reason: '轻小说榜 165 条，18 条一页还有下一页');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

http.Response _json(Object results) => http.Response(
      jsonEncode({'code': 200, 'message': 'ok', 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _comic(String name, String pathWord) => {
      'uuid': 'uuid-$pathWord',
      'path_word': pathWord,
      'name': name,
      'cover': '',
      'author': ['测试作者'],
      'brief': '用于测试的简介。',
      'popular': 12345,
      'datetime_updated': '2026-11-12 10:00:00',
      'status': 'ongoing',
      'theme': [
        {'name': '校园', 'path_word': 'school'}
      ],
    };

Map<String, dynamic> _comicsPage() => {
      'list': [
        _comic('漫画甲', 'a'),
        _comic('漫画乙', 'b'),
        _comic('漫画丙', 'c'),
      ],
      'total': 3,
      'limit': 21,
      'offset': 0,
    };

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _DiscoverHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  final Completer<http.Response> gate = Completer<http.Response>();
  int comicCalls = 0;
  int tagCalls = 0;

  _DiscoverHarness() {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/comics') {
        comicCalls++;
        if (!gate.isCompleted) return gate.future;
        return _json(_comicsPage());
      }
      if (path == '/api/v3/theme/comic/count') {
        tagCalls++;
        return _json({
          'list': [
            {'name': '校园', 'path_word': 'school', 'count': 3},
            {'name': '冒险', 'path_word': 'adventure', 'count': 2},
          ]
        });
      }
      return _json(_comicsPage());
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

Future<void> _pumpDiscover(WidgetTester tester, _DiscoverHarness h) async {
  tester.view.physicalSize = const Size(420, 1600);
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
      home: Scaffold(
        body: DiscoverView(query: ValueNotifier<String>('')),
      ),
    ),
  ));
  await tester.pump();
}

class _HomeHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  /// 每次 `/api/v3/ranks` 的 query，用来断言受众 / 周期真的换成了新参数。
  final List<Map<String, String>> rankQueries = [];

  _HomeHarness(List<String> requested, {required bool failHome}) {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      requested.add(path);
      if (failHome && path == '/api/v3/h5/homeIndex2') {
        return http.Response(
          jsonEncode({'code': 503, 'message': '服务暂时不可用'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/v3/ranks') {
        final q = request.url.queryParameters;
        rankQueries.add(q);
        // 轻小说榜（type=5）内层字段是 book，漫画榜是 comic。
        if (q['type'] == '5') {
          return _json(_bookRankPage(
            int.tryParse(q['offset'] ?? '0') ?? 0,
          ));
        }
        return _json(_comicsPage());
      }
      return _json(_comicsPage());
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

/// 轻小说榜单的真实信封：`{sort, popular, date_type, book:{...}}`，
/// 18 条一页，total 165（`/ranks?type=5&date_type=day` 实测）。
Map<String, dynamic> _bookRankPage(int offset) => {
      'list': [
        for (var i = 0; i < 18 && offset + i < 165; i++)
          {
            'sort': offset + i + 1,
            'sort_last': 0,
            'rise_sort': 0,
            'rise_num': 100 - i,
            'date_type': 1,
            'popular': 5000 - i,
            'book': {
              'uuid': 'book-${offset + i}',
              'path_word': 'book-${offset + i}',
              'name': '輕小說${offset + i}',
              'cover': '',
              'author': [
                {'name': '作者${offset + i}', 'path_word': 'a${offset + i}'}
              ],
              'popular': 5000 - i,
            },
          },
      ],
      'total': 165,
      'limit': 18,
      'offset': offset,
    };

Future<void> _pumpHome(WidgetTester tester, _HomeHarness h) async {
  tester.view.physicalSize = const Size(420, 1600);
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
      // 真实应用里 HomeScreen 挂在 AppShell 的 Scaffold 内；
      // TextTabRow / InkWell 需要 Material 祖先，测试里补一个。
      home: const Scaffold(body: HomeScreen()),
    ),
  ));
  await tester.pump();
}
