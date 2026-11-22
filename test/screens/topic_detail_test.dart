import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/content.dart';
import 'package:mankafe/screens/topic_detail_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/image_url.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 专题详情页的页头说明。
///
/// 首页专题卡只露出标题，点进来如果只有一串作品，用户不知道这一期收的是
/// 什么。`/api/v3/topic/{path_word}` 里的 `series / datetime_created /
/// brief / intro` 就是这段说明，接口有、页面之前没画。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('专题详情页补上说明：系列名 / 日期 / 标题 / 简介', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_app(_Harness(failDetail: false)));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    // 页头的系列名 + 期号日期。
    expect(find.text('copy熱門漫畫專題'), findsOneWidget);
    expect(find.text('2026-07-03'), findsOneWidget);
    expect(find.text('夏番漫畫2026 必看熱門漫畫推薦第41期'), findsOneWidget);
    // 说明正文来自接口 brief / intro。
    expect(find.textContaining('本季度有約30部新番為漫畫改編'), findsOneWidget);
    // 说明下面是真实的作品列表，两部分同页。
    expect(find.text('碧藍之海'), findsOneWidget);
    expect(find.text('正相反的你與我'), findsOneWidget);
    // 专题条目都没有 `datetime_updated`：卡片只显示热度，不写「—」占位。
    expect(find.text('—'), findsNothing);
  });

  testWidgets('说明接口失败：页头退化成可重试提示，作品列表照常', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_app(_Harness(failDetail: true)));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('专题说明加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 页头挂了不影响分页列表。
    expect(find.text('碧藍之海'), findsOneWidget);
  });

  test('intro 优先于 brief：两个字段都在时用 intro', () {
    final detail = TopicDetail.fromJson(const {
      'title': 'T',
      'brief': '短简介',
      'intro': '完整说明',
      'series': {'name': 'S'},
      'datetime_created': '2026-07-03',
    });
    expect(detail.description, '完整说明');
    expect(detail.seriesName, 'S');
  });

  test('imageAspect 从 .宽x高.jpg 缩略后缀读出横幅比例', () {
    expect(
      imageAspect(
          'https://s3.mangafunb.fun/topic/cover/remenmanhua202606/17840192714271.jpg.372x100.jpg'),
      closeTo(3.72, 0.001),
    );
    expect(imageAspect('https://s3.mangafunb.fun/topic/cover/x.jpg'), 2.5);
  });
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _app(_Harness h) {
  final state = AppState();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<RouteManager>.value(value: h.routes),
      Provider<Repository>.value(value: h.repo(state)),
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
      home: const TopicDetailScreen(
        pathWord: 'remenmanhua202606',
        title: '夏番漫畫2026 必看熱門漫畫推薦第41期',
      ),
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
  final bool failDetail;

  _Harness({this.failDetail = false});

  /// 照抄线上 `/api/v3/topic/remenmanhua202606` 的真实响应字段。
  static const Map<String, dynamic> _detail = {
    'title': '夏番漫畫2026 必看熱門漫畫推薦第41期',
    'series': {
      'name': 'copy熱門漫畫專題',
      'color': 'light-green',
      'path_word': 'remenmanhua-topic',
    },
    'journal': '2026',
    'cover':
        'https://s3.mangafunb.fun/topic/cover/remenmanhua202606/17840192714271.jpg.372x100.jpg',
    'period': '第41期',
    'brief': '本次必看熱門漫畫推薦第41期為2026年7月夏季新番動畫的原作漫畫或相關衍生漫畫作品匯總合集，'
        '本季度有約30部新番為漫畫改編，在專題靠前位置。看番不過癮，來看看原作漫畫吧。',
    'intro': '本次必看熱門漫畫推薦第41期為2026年7月夏季新番動畫的原作漫畫或相關衍生漫畫作品匯總合集，'
        '本季度有約30部新番為漫畫改編，在專題靠前位置。看番不過癮，來看看原作漫畫吧。',
    'type': 1,
    'path_word': 'remenmanhua202606',
    'datetime_created': '2026-07-03',
  };

  static final Map<String, dynamic> _contents = {
    'list': [
      {
        'path_word': 'bluegiant',
        'name': '碧藍之海',
        'cover': 'https://s3.mangafunb.fun/comic/bluegiant.jpg',
        'author': ['井上堅二', '吉岡公威'],
        'popular': 18469000,
      },
      {
        'path_word': 'seihantai',
        'name': '正相反的你與我',
        'cover': 'https://s3.mangafunb.fun/comic/seihantai.jpg',
        'author': ['阿賀沢紅茶'],
        'popular': 1599000,
      },
    ],
    'total': 2,
    'limit': 21,
    'offset': 0,
  };

  Repository repo(AppState state) {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/topic/remenmanhua202606') {
        if (failDetail) {
          return http.Response(
            jsonEncode({'code': 500, 'message': 'server error'}),
            500,
            headers: {'content-type': 'application/json'},
          );
        }
        return _json(_detail);
      }
      if (path == '/api/v3/topic/remenmanhua202606/contents') {
        return _json(_contents);
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
        jsonEncode({'code': 200, 'message': '请求成功', 'results': body}),
        200,
        headers: {'content-type': 'application/json'},
      );
}
