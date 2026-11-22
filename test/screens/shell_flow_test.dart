import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/catalog_more_screen.dart';
import 'package:mankafe/screens/catalog_screen.dart';
import 'package:mankafe/screens/content_detail_screen.dart';
import 'package:mankafe/screens/shell.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/browse_widgets.dart';
import 'package:mankafe/widgets/paged_media.dart';
import 'package:mankafe/widgets/request_error.dart';
import 'package:mankafe/widgets/skeleton.dart';
import 'package:mankafe/widgets/ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真实页面组合的集成测试。
///
/// 之前 73 项用例大多是「把单个 widget 塞进 MaterialApp」的组件级测试，
/// 覆盖不到用户实际走的路径：启动 → AppShell 六个 tab 常驻挂载 → 切底部
/// tab → 点卡片 push 详情 → 返回 → 再切 tab。多次线上白屏 / 连锁红屏都是
/// 这种「页面组合 + 转场」下才出现的，单 widget 测试永远测不到。
///
/// 这里挂的是**真正的 [AppShell]**，只在最外层把 HTTP 换成 MockClient，
/// 其余 Provider、主题、导航、骨架、FutureBuilder 全部与线上一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首页：真实数据到达后必须有可见内容，不能只剩 surface 白屏', (tester) async {
    final h = await _Harness.create(tester);
    await _pumpShell(tester, h);
    await _settle(tester);

    expect(tester.takeException(), isNull, reason: '首页构建不应抛任何断言');
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    // 数据到位：骨架必须消失，轮播 / 区块标题 / 作品卡都要真的在树上。
    expect(find.byType(HomeSkeleton), findsNothing);
    expect(find.byType(CoverCarousel), findsOneWidget);
    expect(find.byType(SectionHeader), findsWidgets);
    expect(find.byType(MediaEntryCard), findsWidgets);
    expect(find.text(_Harness.comicName), findsWidgets);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(RequestErrorState), findsNothing);

    // 真正「不是白屏」的判据：内容渲染对象已 attach 且有非零尺寸。
    final text = find.text(_Harness.comicName).first;
    expect(text.evaluate().single.renderObject!.attached, isTrue);
    expect(tester.getSize(text).width, greaterThan(0));
    expect(tester.getSize(text).height, greaterThan(0));

    // 外层 / 内层 IndexedStack 都停在首页（0），不能出现「选中了空气」。
    final stacks = find.byType(IndexedStack).evaluate().toList();
    expect(stacks, isNotEmpty);
    expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack).first).index, 0);
  });

  testWidgets('精选四个内部 tab 来回切换：无断言、无分页视图、首页不丢内容', (tester) async {
    final h = await _Harness.create(tester);
    await _pumpShell(tester, h);
    await _settle(tester);

    for (final label in ['全新上架', '发现', '排行榜', '首页']) {
      await _tapHomeTab(tester, label);
      await _settle(tester, frames: 4);
      expect(tester.takeException(), isNull, reason: '切到「$label」后不应抛断言');
      expect(find.byType(ErrorWidget), findsNothing,
          reason: '切到「$label」后不能出现红屏 ErrorWidget');
    }

    // 切回首页后内容仍然在（IndexedStack 不会把状态丢掉）。
    expect(find.byType(CoverCarousel), findsOneWidget);
    expect(find.byType(HomeSkeleton), findsNothing);
    expect(find.byType(TabPageSelector), findsNothing);
  });

  testWidgets('精选「专题系列」的卡片可以点进专题内容页', (tester) async {
    final h = await _Harness.create(tester);
    await _pumpShell(tester, h);
    await _settle(tester);

    final strip = find.byType(TopicStrip);
    expect(strip, findsOneWidget, reason: '首页应渲染「专题系列」横滑');
    await tester.dragUntilVisible(
      strip,
      find.byType(CustomScrollView).first,
      const Offset(0, -320),
    );
    await _settle(tester, frames: 4);

    // 卡片本体（TopicStrip 内每张卡的 InkWell），不是「更多」按钮。
    final card =
        find.descendant(of: strip, matching: find.byType(InkWell)).first;
    await tester.tap(card, warnIfMissed: false);
    await _settle(tester, frames: 8);

    expect(find.byType(CatalogMoreScreen), findsOneWidget,
        reason: '专题卡必须能点进该专题的内容列表（之前整张卡没有手势）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部切到动画 → 点卡片 → 详情数据到达后可见（不白屏、不红屏）', (tester) async {
    final h = await _Harness.create(tester);
    await _pumpShell(tester, h);
    await _settle(tester);

    await _tapBottomTab(tester, '动画');
    await _settle(tester);
    expect(tester.takeException(), isNull, reason: '切到动画 tab 不应抛断言');

    // 只命中「动画」分类页里的卡片：IndexedStack 常驻所有页面，
    // 首页也有 MediaEntryCard，直接用 .first 会点到首页漫画卡而非动画卡。
    final animCard = find.descendant(
      of: find.byWidgetPredicate(
          (w) => w is CatalogScreen && w.kind == CatalogKind.animation),
      matching: find.byType(MediaEntryCard),
    );
    expect(animCard, findsWidgets, reason: '动画列表应渲染出真实条目');

    await tester.tap(animCard.first);
    await _settle(tester, frames: 8);

    expect(tester.takeException(), isNull, reason: 'push 动画详情后不应抛任何渲染树断言');
    expect(find.byType(ContentDetailScreen), findsOneWidget);
    expect(find.byType(ContentDetailSkeleton), findsNothing,
        reason: '详情接口已返回，骨架必须让位给真实内容');
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(RequestErrorState), findsNothing);
    expect(find.text(_Harness.cartoonName), findsWidgets,
        reason: '动画详情标题必须可见，不能是整屏 surface 色');
    expect(find.text('目录 · 集'), findsOneWidget);
    expect(find.text('第01集'), findsWidgets);

    // 目录 / 章节行：有封面就显示缩略图，**没封面**才不留左侧块。
    // 这里的 mock 第01集没有 v_cover，所以 leading 必须为空——原来会退化成
    // 灰底序号块（0 / 1 / 2…），把标题挤到第二列。
    final chapterRow = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('第01集').first,
        matching: find.byType(ListTile),
      ),
    );
    expect(chapterRow.leading, isNull, reason: '没封面的目录章节行不该有左侧序号块');

    final title = find.text(_Harness.cartoonName).first;
    expect(title.evaluate().single.renderObject!.attached, isTrue);
    expect(tester.getSize(title).height, greaterThan(0));

    // 返回后首页还在，不能因为转场把整棵树弄坏。
    await _tapBack(tester);
    await _settle(tester, frames: 6);
    expect(tester.takeException(), isNull);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
  });

  testWidgets('完整回归序列：切底部 tab → 进详情 → 返回 → 再切回精选', (tester) async {
    final h = await _Harness.create(tester);
    await _pumpShell(tester, h);
    await _settle(tester);

    final sequence = <String>['写真', '轻小说', '动画', '书架', '精选'];
    for (final label in sequence) {
      await _tapBottomTab(tester, label);
      await _settle(tester, frames: 4);
      expect(tester.takeException(), isNull, reason: '切到「$label」后不应抛断言');
      expect(find.byType(ErrorWidget), findsNothing,
          reason: '切到「$label」后不能出现红屏');
    }

    // 精选 → 排行榜 → 精选 → 动画 → 详情 → 返回
    await _tapHomeTab(tester, '排行榜');
    await _settle(tester, frames: 4);
    await _tapHomeTab(tester, '首页');
    await _settle(tester, frames: 4);
    await _tapBottomTab(tester, '动画');
    await _settle(tester, frames: 4);
    await tester.tap(find.byType(MediaEntryCard).first);
    await _settle(tester, frames: 8);
    expect(tester.takeException(), isNull);
    expect(find.text(_Harness.cartoonName), findsWidgets);

    await _tapBack(tester);
    await _settle(tester, frames: 6);
    await _tapBottomTab(tester, '精选');
    await _settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(CoverCarousel), findsOneWidget, reason: '回到精选后首页内容仍应可见');
  });

  testWidgets('接口失败时首页显示可重试错误态，而不是一片空白', (tester) async {
    final h = await _Harness.create(tester, failHome: true);
    await _pumpShell(tester, h);
    await _settle(tester, frames: 12);

    expect(tester.takeException(), isNull);
    expect(find.byType(RequestErrorState), findsWidgets);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(HomeSkeleton), findsNothing, reason: '已经失败，不能永远停在骨架上');
  });
}

// ── 测试夹具 ────────────────────────────────────────────────────────────

/// 固定步进若干帧。不能用 pumpAndSettle：页面级骨架用
/// AnimationController.repeat()，永远 settle 不了。
Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _tapHomeTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar).first,
    matching: find.text(label),
  );
  expect(tab, findsWidgets, reason: '找不到首页 tab「$label」');
  await tester.tap(tab.first);
  await tester.pump();
}

Future<void> _tapBottomTab(WidgetTester tester, String label) async {
  final destination = find.widgetWithText(NavigationDestination, label);
  expect(destination, findsOneWidget, reason: '找不到底部 tab「$label」');
  await tester.tap(destination);
  await tester.pump();
}

/// 详情页返回：用 `BackButton` 直接点，不用 `tester.pageBack()`。
///
/// `pageBack()` 只会 `find.byTooltip('Back')`，但中文 locale 下 Material 的
/// 返回按钮 tooltip 是「返回」而非 "Back"，命不中会导致「找不到 Back 按钮」。
/// 真实用户也是点这个返回箭头，行为一致。
Future<void> _tapBack(WidgetTester tester) async {
  final back = find.byType(BackButton);
  expect(back, findsOneWidget, reason: '详情页应有返回按钮');
  await tester.tap(back);
  await tester.pump();
}

Future<void> _pumpShell(WidgetTester tester, _Harness h) async {
  // 手机竖屏尺寸，避免 RenderFlex overflow 被误报成异常。
  tester.view.physicalSize = const Size(420, 1500);
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
      // 真正的应用入口是 AppShell，不是单个 widget，也不经过启动自检页。
      home: const AppShell(),
    ),
  ));
  await tester.pump();
}

/// 测试专用缓存：一律不缓存，彻底避开磁盘 IO。
///
/// `flutter test` 跑在 FakeAsync zone 里，`dart:io` 的 File 读写要等真实事件循环，
/// 一旦 `ApiClient` 走到 `HttpCache._ensureDir()` 就会永久挂住（表现为
/// "did not complete"）。`ttlFor` 返回 null 时 `ApiClient.get` 既不读也不写缓存。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  _Harness._({
    required this.state,
    required this.routes,
    required this.repo,
  });

  static const comicName = '测试漫画';
  static const cartoonName = '测试动画';
  static const novelName = '测试小说';
  static const photoName = '测试写真';

  final AppState state;
  final RouteManager routes;
  final Repository repo;

  static Future<_Harness> create(
    WidgetTester tester, {
    bool failHome = false,
  }) async {
    final cache = _NoCache();
    final routes = RouteManager()..autoFallback = false;
    final state = AppState();

    final httpClient = MockClient((request) async {
      final path = request.url.path;
      if (failHome && path == '/api/v3/h5/homeIndex2') {
        return http.Response(
          jsonEncode({'code': 503, 'message': '服务暂时不可用'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'code': 200,
          'message': 'ok',
          'results': _resultsFor(path),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = ApiClient(routes, httpClient: httpClient, cache: cache);
    final repo = Repository(api, routes, state);
    return _Harness._(state: state, routes: routes, repo: repo);
  }

  // ── 各类真实接口的响应形状 ──────────────────────────────────────────

  static Map<String, dynamic> _comic(String name, String pathWord) => {
        'uuid': 'uuid-$pathWord',
        'path_word': pathWord,
        'name': name,
        'cover': '',
        'author': ['测试作者'],
        'brief': '这是一段用于集成测试的简介。',
        'popular': 12345,
        'datetime_updated': '2026-11-12 10:00:00',
        'status': 'ongoing',
        'theme': [
          {'name': '校园', 'path_word': 'school'}
        ],
      };

  static Map<String, dynamic> _page(String name, String pathWord) => {
        'list': [_comic(name, pathWord)],
        'total': 1,
        'limit': 21,
        'offset': 0,
      };

  static Map<String, dynamic> _homeIndex() => {
        'banners': [
          {
            'type': '1',
            'cover': '',
            'brief': '测试轮播',
            'out_uuid': '',
            'comic': {'path_word': 'comic-1', 'name': comicName},
          }
        ],
        // 专题系列至少一条：首页的专题卡必须能点进专题内容页。
        // 解析层会丢掉没有封面的专题，所以这里必须给一个 cover。
        'topics': [
          {
            'title': '測試專題',
            'period': '冬番2026',
            'cover': 'https://example.com/topic-cover.jpg',
            'path_word': 'topic-1',
          }
        ],
        'recComics': [_comic(comicName, 'comic-1')],
        'hotComics': [_comic(comicName, 'comic-1')],
        'newComics': [_comic(comicName, 'comic-1')],
        'rankDayComics': [_comic(comicName, 'comic-1')],
        'rankWeekComics': [_comic(comicName, 'comic-1')],
        'rankMonthComics': [_comic(comicName, 'comic-1')],
        'finishComics': [_comic(comicName, 'comic-1')],
      };

  static dynamic _resultsFor(String path) {
    if (path == '/api/v3/h5/homeIndex2') return _homeIndex();
    if (path == '/api/v3/topic/topic-1/contents') {
      return _page(comicName, 'comic-1');
    }
    if (path == '/api/v3/h5/cartoonIndex' || path == '/api/v3/h5/postIndex') {
      return {
        'banners': [],
        'topics': {'list': [], 'total': 0},
        'tags': [],
        'ordering': [],
        'recCartoons': {
          'list': [_comic(cartoonName, 'cartoon-1')],
          'total': 1
        },
      };
    }
    if (path == '/api/v3/update/newest' ||
        path == '/api/v3/update/post/newest') {
      return _page(comicName, 'comic-1');
    }
    if (path == '/api/v3/cartoons' ||
        path == '/api/v3/search/cartoons' ||
        path == '/api/v3/h5/cartoonIndex') {
      return _page(cartoonName, 'cartoon-1');
    }
    if (path == '/api/v3/books' || path == '/api/v3/search/books') {
      return _page(novelName, 'book-1');
    }
    if (path == '/api/v3/posts' || path == '/api/v3/search/posts') {
      return _page(photoName, 'post-1');
    }
    if (path == '/api/v3/theme/comic/count' ||
        path == '/api/v3/theme/book/count' ||
        path == '/api/v3/theme/cartoon/count' ||
        path == '/api/v3/tag/post/count') {
      return {
        'list': [
          {'name': '校园', 'path_word': 'school', 'count': 3}
        ]
      };
    }
    if (path == '/api/v3/cartoon/cartoon-1') {
      return {'cartoon': _comic(cartoonName, 'cartoon-1')};
    }
    if (path == '/api/v3/cartoon/cartoon-1/chapters') {
      return {
        'list': [
          {
            'uuid': 'ep-1',
            'name': '第01集',
            'sort': 1,
            'count': 24,
            'lines': [
              {'name': '线路一', 'path_word': 'line1', 'config': true}
            ],
          }
        ],
        'total': 1,
        'limit': 100,
        'offset': 0,
      };
    }
    if (path == '/api/v3/book/book-1') {
      return {'book': _comic(novelName, 'book-1')};
    }
    if (path == '/api/v3/book/book-1/volumes') {
      return {
        'list': [
          {'uuid': 'vol-1', 'name': '第一卷', 'sort': 1}
        ],
        'total': 1,
      };
    }
    if (path == '/api/v3/post/post-1') {
      return {'post': _comic(photoName, 'post-1')};
    }
    if (path == '/api/v3/post/post-1/chapters') {
      return {
        'list': [
          {'uuid': 'ch-1', 'name': '第01话', 'sort': 1, 'count': 8}
        ],
        'total': 1,
      };
    }
    if (path.startsWith('/api/v3/comic2/')) {
      return {
        'comic': _comic(comicName, 'comic-1'),
        'groups': <String, dynamic>{},
      };
    }
    // 列表 / 榜单 / 专题 / 系统配置 / 评论等：给一份合法的空信封。
    return _page(comicName, 'comic-1');
  }
}
