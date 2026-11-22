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

/// 精选「为你推荐」的「换一批」必须是**真请求**：
/// `GET /api/v3/recs?pos=3200102&limit=3&offset=n`（线上 total=1491）。
/// 之前它只做 `setState(_batch++)` 本地轮转，一张新卡都不会出现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('点「换一批」按 offset=3 重新请求 recs，并把新一批替换到卡片上', (tester) async {
    final recsQueries = <Map<String, String>>[];
    final h = _Harness((request) {
      final path = request.url.path;
      if (path == '/api/v3/h5/homeIndex2') {
        return _json({
          'banners': [],
          'topics': [],
          'recComics': [
            _comic('首頁推薦A', 'home-a'),
            _comic('首頁推薦B', 'home-b'),
            _comic('首頁推薦C', 'home-c'),
          ],
          'hotComics': [_comic('熱門X', 'hot-x')],
          'newComics': [],
          'rankDayComics': [],
          'rankWeekComics': [],
          'rankMonthComics': [],
          'finishComics': [],
        });
      }
      if (path == '/api/v3/update/newest') {
        return _json({'list': [], 'total': 0, 'limit': 6, 'offset': 0},
            page: true);
      }
      if (path == '/api/v3/recs') {
        final q = request.url.queryParameters;
        recsQueries.add(q);
        final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
        return _json({
          'list': [
            for (var i = 0; i < 3; i++)
              {
                'type': 1,
                'comic':
                    _comic('換一批${offset + i}', 'batch-$offset-${offset + i}'),
              }
          ],
          'total': 1491,
          'limit': 3,
          'offset': offset,
        });
      }
      return _json({});
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
        home: const Scaffold(body: HomeScreen()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('首頁推薦A'), findsOneWidget, reason: '首屏先显示首页下发的推荐');
    expect(recsQueries, isEmpty, reason: '首屏不需要额外请求 recs');

    final shuffle = find.text('换一批');
    expect(shuffle, findsOneWidget);
    await tester.tap(shuffle, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(recsQueries, hasLength(1), reason: '点一次必须发出一次真实请求');
    expect(recsQueries.first['pos'], '3200102');
    expect(recsQueries.first['limit'], '3');
    expect(recsQueries.first['offset'], '3', reason: '首屏占了 0..2，第一下换一批从 3 开始');

    expect(find.text('換一批3'), findsOneWidget, reason: '新一批要替换掉旧卡片');
    expect(find.text('首頁推薦A'), findsNothing, reason: '换一批后不应再是旧内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('换一批到底（返回不足 3 条）会自动回到第一页', (tester) async {
    var calls = 0;
    final offsets = <String>[];
    final h = _Harness((request) {
      final path = request.url.path;
      if (path == '/api/v3/h5/homeIndex2') {
        return _json({
          'banners': [],
          'topics': [],
          'recComics': [_comic('首頁推薦A', 'home-a'), _comic('首頁推薦B', 'home-b')],
          'hotComics': [_comic('熱門X', 'hot-x')],
          'newComics': [],
          'rankDayComics': [],
          'rankWeekComics': [],
          'rankMonthComics': [],
          'finishComics': [],
        });
      }
      if (path == '/api/v3/update/newest') {
        return _json({'list': [], 'total': 0, 'limit': 6, 'offset': 0},
            page: true);
      }
      if (path == '/api/v3/recs') {
        final offset = request.url.queryParameters['offset'] ?? '0';
        offsets.add(offset);
        calls++;
        // offset=3 只剩 1 条 → 触发「回到第一页」；offset=0 给满 3 条。
        final count = offset == '0' ? 3 : 1;
        return _json({
          'list': [
            for (var i = 0; i < count; i++)
              {
                'type': 1,
                'comic': _comic('第$offset頁第$i張', 'p-$offset-$i'),
              }
          ],
          'total': 4,
          'limit': 3,
          'offset': int.tryParse(offset) ?? 0,
        });
      }
      return _json({});
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
        home: const Scaffold(body: HomeScreen()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('换一批'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(offsets, ['3', '0'], reason: '不足一屏就回到 offset=0');
    expect(calls, 2);
    expect(find.text('第0頁第0張'), findsOneWidget, reason: '回到第一页的那一批要显示出来');
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _comic(String name, String pathWord) => {
      'name': name,
      'path_word': pathWord,
      'cover': '',
      'author': [
        {'name': '作者', 'path_word': 'author'}
      ],
      'author_alias': '作者',
      'popular': 3000,
    };

http.Response _json(Map<String, dynamic> results, {bool page = false}) =>
    http.Response(
      jsonEncode({
        'code': 200,
        'message': '请求成功',
        'results': results,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

typedef _Handler = http.Response Function(http.Request request);

class _Harness {
  _Harness(_Handler handler)
      : state = AppState(),
        routes = RouteManager()..autoFallback = false {
    repo = Repository(
      ApiClient(routes,
          httpClient: MockClient((r) async => handler(r)), cache: _NoCache()),
      routes,
      state,
    );
  }

  final AppState state;
  final RouteManager routes;
  late final Repository repo;
}

class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
