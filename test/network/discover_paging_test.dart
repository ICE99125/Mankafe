import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/discover_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/browse_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户反馈：发现页「拖到底直接拖不动，也没有提示已经到底了」。
///
/// 两个直接原因：
///   1. 发现页只取一页、没有分页 → 服务端明明还有 200 条，却永远不会再请求；
///   2. 地区 / 进度是本地过滤，过滤后只剩两三条时内容撑不满一屏，
///      maxScrollExtent = 0，于是拖不动，末尾也没有任何 footer。
/// 这里把小屏（360×640）下的两条行为钉死：
///   ① 筛选后不足一屏要自动续页（offset 必须往下走）；
///   ② 末尾一定有可见文案（「加载更多」/「已经到底了」/ 转圈），不能是空白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('发现页：地区过滤后不够一屏会自动续页，末尾有可见 footer', (tester) async {
    final h = _DiscoverPagingHarness();
    await _pumpDiscover(tester, h);
    await _settle(tester, frames: 12);

    // 首屏是「全部」，21 条足够撑一屏，此时不该多翻页。
    expect(find.byType(RichGridCard), findsWidgets);
    // 缺 datetime_updated 的条目（线上升序那侧真实存在）不再用「—」占位，
    // 日期行整行不渲染，热度下面不留横杠（用户：没时间就别写占位）。
    expect(find.text('—'), findsNothing, reason: '没有更新时间就不写日期，不留占位符');

    // 切到「日漫」：本地过滤每页只命中 2 条 → 一屏空空荡荡。
    await tester.tap(find.text('日漫'));
    await _settle(tester, frames: 12);

    expect(
      h.offsets.any((o) => o > 0),
      isTrue,
      reason: '过滤后内容不足一屏，必须自动往下翻页，而不是停在两条一条不动',
    );

    // 滚到底：必须有可见的「加载更多 / 已经到底了」，不能只留空白。
    await _scrollToEnd(tester);
    final footer = _visibleFooter(tester);
    expect(footer, isNotNull, reason: '列表末尾必须是可见文案，不能是一片空白');
    expect(tester.takeException(), isNull);
  });

  testWidgets('发现页：排序两个维度都能升降序（ordering 正负切换）', (tester) async {
    final h = _DiscoverPagingHarness();
    await _pumpDiscover(tester, h);
    await _settle(tester, frames: 12);
    expect(h.orderings.first, '-datetime_updated', reason: '默认按更新时间降序');

    // 点「热度」：换维度并重新请求第一页，默认降序。
    h.orderings.clear();
    await tester.tap(_sortChip('热度'));
    await _settle(tester, frames: 12);
    expect(h.orderings, isNotEmpty, reason: '换排序必须重新请求');
    expect(h.orderings.first, '-popular');

    // 再点「热度」：同一维度翻成升序。
    h.orderings.clear();
    await tester.tap(_sortChip('热度'));
    await _settle(tester, frames: 12);
    expect(h.orderings.first, 'popular');

    // 切回「更新时间」：默认降序；再点一次翻成升序。
    h.orderings.clear();
    await tester.tap(_sortChip('更新时间'));
    await _settle(tester, frames: 12);
    expect(h.orderings.first, '-datetime_updated');

    h.orderings.clear();
    await tester.tap(_sortChip('更新时间'));
    await _settle(tester, frames: 12);
    expect(h.orderings.first, 'datetime_updated');
  });

  testWidgets('发现页：数据取完后末尾给出「已经到底了」', (tester) async {
    final h = _DiscoverPagingHarness(total: 3, perPage: 3);
    await _pumpDiscover(tester, h);
    await _settle(tester, frames: 12);

    expect(h.offsets.length, 1, reason: 'total=3 时不该再翻页');
    await _scrollToEnd(tester);

    final footer = _visibleFooter(tester);
    expect(footer, isNotNull, reason: '末尾必须有提示，不能是空白');
    expect(
      footer!.toLowerCase().contains('到底') || footer.contains('加载更多'),
      isTrue,
      reason: 'footer 应该是「已经到底了」或「加载更多」之一，实际是：$footer',
    );
    expect(tester.takeException(), isNull);
  });
}

/// 排序胶囊：按胶囊本体点击（Text 只是 label，点它不算命中胶囊）。
Finder _sortChip(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(ChoiceChip),
    );

/// 末尾可见文案：取列表（`CustomScrollView`）里最后一个可见的文字。
/// 只看滚动区，不看叠在上面的固定筛选区：题材 / 排序胶囊是筛选控件，
/// 它们在元素树里排在列表之后，会被误当成 footer（「热度」）。
String? _visibleFooter(WidgetTester tester) {
  final texts = find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Text),
      )
      .evaluate()
      .toList();
  for (final element in texts.reversed) {
    final text = (element.widget as Text).data;
    if (text == null || text.trim().isEmpty) continue;
    if (text.startsWith('漫画') || text == '日漫' || text.startsWith('搜索')) {
      continue; // 卡片标题 / 筛选标签，不算 footer
    }
    return text;
  }
  return null;
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await _settle(tester, frames: 6);
  }
}

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

http.Response _json(Object results) => http.Response(
      jsonEncode({'code': 200, 'message': 'ok', 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _comic(String pathWord,
        {required String region, bool dated = true}) =>
    {
      'uuid': 'uuid-$pathWord',
      'path_word': pathWord,
      'name': '漫画$pathWord',
      'cover': '',
      'author': ['测试作者'],
      'brief': '用于分页测试的简介。',
      'popular': 12345,
      'region': region,
      // 线上升序那一侧有一批条目根本没有 datetime_updated，卡片要能显示「—」。
      if (dated) 'datetime_updated': '2026-11-14 10:00:00',
      'status': 'serializing',
      'theme': [
        {'name': '校园', 'path_word': 'school'}
      ],
    };

/// 每页 21 条里固定 2 条日漫 —— 模拟「日漫」筛选一页只命中几条的现实。
Map<String, dynamic> _comicsPage(int offset, {int perPage = 0}) {
  final count = perPage == 0 ? 21 : perPage;
  final list = <Map<String, dynamic>>[];
  for (var i = 0; i < count; i++) {
    final index = offset + i;
    // 每页前 2 条是日漫，其余韩漫；第 1 条故意不带 datetime_updated。
    final region = (i % 21) < 2 ? 'jp' : 'kr';
    list.add(_comic('c$index', region: region, dated: i != 0));
  }
  return {
    'list': list,
    'total': 200,
    'limit': count,
    'offset': offset,
  };
}

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _DiscoverPagingHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  /// 每次 `/api/v3/comics` 实际带的 offset。
  final List<int> offsets = [];

  /// 每次 `/api/v3/comics` 实际带的 `ordering`（方向靠正负号区分）。
  final List<String> orderings = [];

  final int total;
  final int perPage;

  _DiscoverPagingHarness({this.total = 200, this.perPage = 0}) {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/comics') {
        final offset =
            int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
        offsets.add(offset);
        orderings.add(request.url.queryParameters['ordering'] ?? '');
        if (perPage != 0) {
          final list = <Map<String, dynamic>>[];
          for (var i = 0; i < perPage; i++) {
            list.add(_comic('c${offset + i}', region: 'jp'));
          }
          return _json({
            'list': list,
            'total': total,
            'limit': perPage,
            'offset': offset,
          });
        }
        return _json(_comicsPage(offset));
      }
      if (path == '/api/v3/theme/comic/count') {
        return _json({
          'list': [
            {'name': '校园', 'path_word': 'school', 'count': 3},
            {'name': '冒险', 'path_word': 'adventure', 'count': 2},
          ]
        });
      }
      return _json({'list': <Object>[], 'total': 0});
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

Future<void> _pumpDiscover(
    WidgetTester tester, _DiscoverPagingHarness h) async {
  // MuMu 这类小屏：logical 360×640。
  tester.view.physicalSize = const Size(360, 640);
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
