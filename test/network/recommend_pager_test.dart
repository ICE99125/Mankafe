import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/recommendations_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「为你推荐 · 更多」必须是**真分页 + 滑到底续页**，不能是一次性摊平。
///
/// 线上实测 `/api/v3/comics?ordering=popular&limit=18&offset=` 的 `total=56461`，
/// 所以这页可以一直往下翻；之前的实现只拼了首页 3 条 + 人气一页 + 已完结一页，
/// 用户滚两下就到「已经到底了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('comicPage 走真实分页参数：ordering=popular、limit=18、offset 递增', () async {
    final queries = <Map<String, String>>[];
    final repo = _repo((request) {
      queries.add(request.url.queryParameters);
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
      return _comicsResponse(offset: offset, total: 200, count: 18);
    });

    final first = await repo.comicPage(offset: 0);
    expect(queries.last['ordering'], 'popular');
    expect(queries.last['limit'], '18');
    expect(queries.last['offset'], '0');
    expect(first.items.length, 18);
    expect(first.items.first.name, '推薦0');
    expect(first.total, 200);
    expect(first.hasMore, isTrue, reason: '0 + 18 < 200，后面还有得翻');

    final second = await repo.comicPage(offset: 18);
    expect(queries.last['offset'], '18');
    expect(second.items.first.name, '推薦18');
    expect(second.items.length, 18);
  });

  testWidgets('推荐页首屏只拉一页，滑到底自动续第二页（不是「已经到底了」）', (tester) async {
    final offsets = <int>[];
    final h = _Harness((request) {
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
      offsets.add(offset);
      return _comicsResponse(offset: offset, total: 200, count: 18);
    });

    tester.view.physicalSize = const Size(420, 1400);
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
        home: const RecommendationsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(offsets, contains(0));
    expect(find.text('推薦0'), findsWidgets, reason: '首屏应有第一页内容');
    expect(tester.takeException(), isNull);

    // 往下拖到底：PagedMediaList 在 extentAfter < 480 时续页。
    for (var i = 0; i < 6; i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(offsets, contains(18),
        reason: '滚到底必须按 offset=18 续拉第二页，而不是停在一页后显示「已经到底了」');
    expect(find.text('已经到底了'), findsNothing, reason: 'total=200，远没有到底');

    // 第二页在列表末尾；继续滚到末尾，检查第二页的最后一条确实进入了网格。
    for (var i = 0; i < 8 && find.text('推薦35').evaluate().isEmpty; i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('推薦35'), findsWidgets,
        reason: '第二页（offset=18）的条目必须进入列表，而不是一页就到底');
    expect(tester.takeException(), isNull);
  });
}

/// 18 条一页的 `/api/v3/comics` 响应（扁平 comic 条目）。
http.Response _comicsResponse({
  required int offset,
  required int total,
  required int count,
}) {
  final list = List.generate(count, (i) {
    final n = offset + i;
    return {
      'name': '推薦$n',
      'path_word': 'rec-$n',
      'cover': '',
      'author': ['作者$n'],
      'popular': 5000 - n,
      'datetime_updated': '2026-11-13 10:00:00',
    };
  });
  return http.Response(
    jsonEncode({
      'code': 200,
      'message': '请求成功',
      'results': {
        'list': list,
        'total': total,
        'limit': count,
        'offset': offset,
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

typedef _Handler = http.Response Function(http.Request request);

class _Harness {
  _Harness(_Handler handler)
      : state = AppState(),
        routes = RouteManager()..autoFallback = false {
    final httpClient = MockClient((request) async => handler(request));
    repo = Repository(
      ApiClient(routes, httpClient: httpClient, cache: _NoCache()),
      routes,
      state,
    );
  }

  final AppState state;
  final RouteManager routes;
  late final Repository repo;
}

Repository _repo(_Handler handler) {
  final routes = RouteManager()..autoFallback = false;
  final state = AppState();
  return Repository(
    ApiClient(routes,
        httpClient: MockClient((r) async => handler(r)), cache: _NoCache()),
    routes,
    state,
  );
}

/// 测试专用缓存：一律不缓存，彻底避开磁盘 IO（FakeAsync 下会永久挂住）。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
