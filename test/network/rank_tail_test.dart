import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/home_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 回归：排行榜末尾不能只剩空白。
///
/// 1. 首屏不足一屏时必须自动续页（不能等用户滚）。
/// 2. 滚到末尾时，footer 必须是「加载中 / 加载更多 / 已经到底了」之一，
///    绝不能再出现一个不可见的 SizedBox + 一大片空白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首屏不足一屏时自动补下一页', (tester) async {
    final queries = <Map<String, String>>[];
    await _pumpHome(tester, queries: queries, itemsPerPage: 3);
    await _openRank(tester);

    final ranks = queries.where((q) => q['offset'] != null).toList();
    expect(ranks.length, greaterThanOrEqualTo(2),
        reason: '首屏只有 3 条时应立刻补页，实际只请求了 ${ranks.length} 页');
    expect(ranks[1]['offset'], '3', reason: '补页应接着已有条数往后取');
  });

  testWidgets('轨迹末尾必须给出可见的 footer', (tester) async {
    final queries = <Map<String, String>>[];
    await _pumpHome(tester, queries: queries, itemsPerPage: 18);
    await _openRank(tester);

    // 反复贴到底部，直到翻不动为止（相当于用户一直往下滑）。
    for (var i = 0; i < 40; i++) {
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isEmpty) break;
      final pos = tester.state<ScrollableState>(scrollable.last).position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    final tailVisible = find.text('加载更多').evaluate().isNotEmpty ||
        find.text('已经到底了').evaluate().isNotEmpty ||
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.text('加载更多失败，点击重试').evaluate().isNotEmpty;
    expect(tailVisible, isTrue, reason: '列表末尾既没有加载提示也没有「已经到底了」，就是用户看到的空白');
    expect(find.byType(CircularProgressIndicator).evaluate().length,
        lessThanOrEqualTo(1),
        reason: '不能重复触发补页');
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required List<Map<String, String>> queries,
  required int itemsPerPage,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState();
  final routes = RouteManager()..autoFallback = false;
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/api/v3/ranks') {
      final q = request.url.queryParameters;
      queries.add(q);
      final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
      return _json(_rankPage(offset, itemsPerPage));
    }
    return _json(_comicsPage());
  });
  final repo = Repository(
    ApiClient(routes, httpClient: client, cache: _NoCache()),
    routes,
    state,
  );

  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<RouteManager>.value(value: routes),
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
      home: const Scaffold(body: HomeScreen()),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _openRank(WidgetTester tester) async {
  await tester.tap(find.text('排行榜'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
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
      'brief': '简介',
      'popular': 12345,
      'datetime_updated': '2026-11-12 10:00:00',
      'status': 'ongoing',
    };

Map<String, dynamic> _comicsPage() => {
      'list': [_comic('漫画甲', 'a'), _comic('漫画乙', 'b')],
      'total': 2,
      'limit': 21,
      'offset': 0,
    };

/// total 故意给 200（服务端常见值），实际每页 [perPage] 条。
Map<String, dynamic> _rankPage(int offset, int perPage) => {
      'list': [
        for (var i = 0; i < perPage && offset + i < 200; i++)
          {
            'sort': offset + i + 1,
            'sort_last': 0,
            'rise_sort': 0,
            'rise_num': 100 - i,
            'date_type': 2,
            'popular': 9000 - i,
            'comic': _comic('榜單${offset + i}', 'r${offset + i}'),
          },
      ],
      'total': 200,
      'limit': 18,
      'offset': offset,
    };

class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
