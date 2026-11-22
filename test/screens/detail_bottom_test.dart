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

/// 详情页章节目录的最后一块是分页条，它必须贴在屏幕底边。
///
/// 回归的是用户反馈「详情页为什么不触底」：原来分页条下面还挂着
/// `SizedBox(height: 32)`，加上分页条自身 12dp 下内边距，滚到底时最后一行
/// 距屏幕底边还有约 44dp 白，看着像没到底；而评论页的分页条是直接贴着输入栏的。
/// 现在尾部只让出系统手势条的安全区（测试里 MediaQuery padding 为 0），
/// 分页条底下只剩它自己的 6dp 内边距。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('章节目录分页条滚到底后贴着屏幕底边', (tester) async {
    await _pumpDetail(tester, _Harness());
    await _settle(tester, frames: 10);
    expect(tester.takeException(), isNull);

    // 一直往上拖，停在最大滚动位置（AlwaysScrollableScrollPhysics 会自动夹住）。
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);

    // 215 话 / 每页 100 话：滚到底后分页条才进入构建范围。
    expect(find.text('1-100 / 215'), findsOneWidget);
    expect(find.text('第 1 / 3 页'), findsOneWidget);

    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    // 分页条那一行（「上一页 / 1-100 / 215 / 下一页」）的底边。
    // 取所有匹配的 Row 里最下面那个：内层是按钮自己的 Row，
    // 外层才是分页条整行。
    var pagerBottom = double.negativeInfinity;
    for (final element
        in find
            .ancestor(
              of: find.text('下一页'),
              matching: find.byType(Row),
            )
            .evaluate()) {
      final box = element.renderObject! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      if (bottom > pagerBottom) pagerBottom = bottom;
    }
    expect(
      pagerBottom,
      moreOrLessEquals(screenH - 6, epsilon: 1.0),
      reason: '滚到底后分页条底边应贴着屏幕底边，只留它自己的 6dp 下内边距',
    );
    // 屏幕上不该再有第二条留白：分页条底边之下只剩那 6dp。
    expect(screenH - pagerBottom, lessThanOrEqualTo(7.0));
  });
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpDetail(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(420, 900);
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
      home: const ComicDetailScreen(pathWord: 'bottom'),
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

  _Harness() {
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

  static Map<String, dynamic> _detail() => {
        'comic': {
          'uuid': 'uuid-bottom',
          'path_word': 'bottom',
          'name': '贴底测试漫画',
          'cover': '',
          'author': ['测试作者'],
          'brief': '一本用来验证分页条是否贴底的漫画。',
          'popular': 12345,
          'datetime_updated': '2026-11-12 10:00:00',
          'status': 'ongoing',
          'theme': [
            {'name': '冒险', 'path_word': 'adventure'}
          ],
          'last_chapter': '完結',
        },
        'groups': {
          'default': {
            'path_word': 'default',
            'count': 215,
            'name': '默認',
          },
        },
      };

  static Map<String, dynamic> _chapter(String uuid, int index) => {
        'uuid': uuid,
        'name': '第 $index 话',
        'index': index - 1,
        'size': 10,
        'datetime_created': '2026-01-01',
      };

  static Map<String, dynamic> _resultsFor(http.Request request) {
    final path = request.url.path;
    if (path == '/api/v3/comic2/bottom') return _detail();
    if (path.endsWith('/chapters')) {
      const total = 215;
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
      final end = (offset + limit).clamp(0, total);
      return {
        'list': [
          for (var i = offset; i < end; i++) _chapter('d-$i', i + 1),
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
