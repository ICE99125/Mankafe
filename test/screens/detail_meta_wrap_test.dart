import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/comic_detail_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/download_manager.dart';
import 'package:mankafe/services/download_store.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 详情页元信息那一行（作者 / 地区 / 人气）在长作者名下不能横向溢出。
///
/// 回归的是用户反馈「右边有报错」：原来是 `Row` 直接把三个 pill 排一行，
/// 作者名是「kwvh · Lee Euntak · Lee hyun-sung」这种多作者拼接时，
/// 窄屏上一行放不下，右侧被裁掉并画出黄黑溢出条（RIGHT OVERFLOWED BY ...）。
/// 现在这一行是 `Wrap`：放不下就换行，单个超长字段再省略号兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('多作者长名 + 窄屏：元信息行不溢出，地区与人气仍在', (tester) async {
    await _pumpDetail(tester, _Harness(), width: 360);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('kwvh · Lee Euntak · Lee hyun-sung'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
    expect(find.text('46.6 万 人气'), findsOneWidget);
  });

  testWidgets('超长单作者名：单行内省略号收尾，不溢出', (tester) async {
    await _pumpDetail(tester, _Harness(singleLongAuthor: true), width: 360);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    // 文本仍在，只是被 maxLines: 1 + ellipsis 收进可用宽度。
    // 作者名同时也会出现在下面的作者 chip 里，所以按「加了省略号的 text」定位 pill。
    final pills = tester
        .widgetList<Text>(find.textContaining('A Very Long Single Author Name'))
        .where((t) => t.maxLines == 1 && t.overflow == TextOverflow.ellipsis);
    expect(pills, hasLength(1));
    expect(find.text('46.6 万 人气'), findsOneWidget);
  });
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpDetail(WidgetTester tester, _Harness h,
    {required double width}) async {
  tester.view.physicalSize = Size(width, 800);
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
      ChangeNotifierProvider<DownloadManager>(
        create: (_) => DownloadManager(
          repo: h.repo,
          store: DownloadStore(root: Directory.systemTemp),
        ),
      ),
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
      home: const ComicDetailScreen(pathWord: 'meta'),
    ),
  ));
  await tester.pump();
}

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里 dart:io 的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;
  final bool singleLongAuthor;

  _Harness({this.singleLongAuthor = false}) {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'code': 200,
          'message': 'ok',
          'results': _resultsFor(request),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }

  List<String> get _authors => singleLongAuthor
      ? ['A Very Long Single Author Name That Runs Past The Meta Row']
      : ['kwvh', 'Lee Euntak', 'Lee hyun-sung'];

  Map<String, dynamic> _detail() => {
        'comic': {
          'uuid': 'uuid-meta',
          'path_word': 'meta',
          'name': '我在死敵家當團寵',
          'cover': '',
          'author': _authors,
          'brief': '用来验证元信息行换行的一本漫画。',
          'popular': 466000,
          'region': 'xx',
          'datetime_updated': '2026-11-12 10:00:00',
          'status': 'ongoing',
          'theme': [
            {'name': '爱情', 'path_word': 'romance'}
          ],
          'last_chapter': '第 48 话',
        },
        'groups': {
          'default': {
            'path_word': 'default',
            'count': 48,
            'name': '默認',
          },
        },
      };

  Map<String, dynamic> _resultsFor(http.Request request) {
    final path = request.url.path;
    if (path == '/api/v3/comic2/meta') return _detail();
    if (path.endsWith('/chapters')) {
      const total = 48;
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
      final end = (offset + limit).clamp(0, total);
      return {
        'list': [
          for (var i = offset; i < end; i++)
            {
              'uuid': 'm-$i',
              'name': '第 ${i + 1} 话',
              'index': i,
              'size': 10,
              'datetime_created': '2026-01-01',
            },
        ],
        'total': total,
        'limit': limit,
        'offset': offset,
      };
    }
    return {
      'list': <dynamic>[],
      'total': 0,
      'limit': 20,
      'offset': 0,
    };
  }
}
