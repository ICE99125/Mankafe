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

/// 官方 3.1.0 的 `results.groups` 是 Map，一本漫画可能同时有
/// 「默認 / 單行本 / 其它汉化版」多个栏目，章节接口按栏目分别返回。
/// 早期详情页只取 `groups.first`，其余栏目就整块消失了。
///
/// 这里挂真正的 [ComicDetailScreen]，只把最外层 HTTP 换成 MockClient：
/// 覆盖「首屏默认栏目 215 话 → 上一页 / 下一页每页 100 话翻页 → 切到單行本
/// 栏目只请求该栏目章节 → 再切回默认栏目命中缓存」这条用户实际路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('多栏目漫画：栏目 tab 可切换、各栏目独立缓存、上一页/下一页每页 100 话', (tester) async {
    final requested = <String>[];
    final h = _Harness(requested);
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 10);

    expect(tester.takeException(), isNull);

    // 两个栏目都渲染成 tab；默认栏目 215 话 → 3 页，分页器是上一页 / 下一页。
    expect(find.text('默認'), findsOneWidget);
    expect(find.text('單行本'), findsOneWidget);
    expect(find.text('上一页'), findsOneWidget);
    expect(find.text('下一页'), findsOneWidget);
    expect(find.text('1-100 / 215'), findsOneWidget);
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('215 话 · 完結 · 无解锁 / 无付费'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '默认栏目第一话应可见');
    expect(find.text('100'), findsOneWidget, reason: '默认栏目第 100 话应可见');
    // 首页「上一页」置灰，避免点了没反应。
    expect(_pagerEnabled(tester, '上一页'), isFalse);
    expect(_pagerEnabled(tester, '下一页'), isTrue);

    // 栏目之间也要分开：每个 tab 左右各 18 内边距 + 6 间距 = 42。
    // 之前 14 内边距且无间距，三个栏目挤在一起（用户反馈「太靠近」）。
    final defaultRect = tester.getRect(find.text('默認'));
    final tankobonRect = tester.getRect(find.text('單行本'));
    expect(
      tankobonRect.left - defaultRect.right,
      greaterThanOrEqualTo(30),
      reason: '相邻栏目之间要留出足够间距',
    );

    // 栏目 tab 与章节网格之间要留出间距：之前网格紧贴下划线，
    // 第一个章节按钮几乎顶在 tab 上（用户反馈「太靠近」）。
    final gridPadding = tester.widget<SliverPadding>(
      find
          .ancestor(
            of: find.byType(SliverGrid),
            matching: find.byType(SliverPadding),
          )
          .first,
    );
    expect(
      (gridPadding.padding as EdgeInsets).top,
      12,
      reason: '有多个栏目时章节网格顶部要留 12 间距',
    );

    // 点「下一页」逐页翻：第二页换成 101-200，第一话不再出现在目录里。
    await tester.tap(find.text('下一页'));
    await _settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
    expect(find.text('101-200 / 215'), findsOneWidget);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('101'), findsOneWidget);
    expect(find.text('1'), findsNothing, reason: '翻页后第 1 话不该还在');
    expect(_pagerEnabled(tester, '上一页'), isTrue, reason: '第二页可以回退');

    // 翻到最后一页（201-215）：只剩 15 话，「下一页」置灰。
    await tester.tap(find.text('下一页'));
    await _settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
    expect(find.text('201-215 / 215'), findsOneWidget);
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(find.text('201'), findsOneWidget);
    expect(find.text('215'), findsOneWidget);
    expect(_pagerEnabled(tester, '下一页'), isFalse, reason: '末页没有下一页');

    // 「上一页」回到第二页。
    await tester.tap(find.text('上一页'));
    await _settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
    expect(find.text('101-200 / 215'), findsOneWidget);
    expect(find.text('101'), findsOneWidget);

    // 切到「單行本」：只请求该栏目接口，目录变成 1 话且分页器消失。
    await tester.tap(find.text('單行本'));
    await _settle(tester, frames: 8);
    expect(tester.takeException(), isNull);
    expect(
      requested.where((p) => p.contains('/group/tankobon/chapters')).length,
      1,
      reason: '單行本栏目应只拉一次它自己的章节接口',
    );
    expect(find.text('1 话 · 完結 · 无解锁 / 无付费'), findsOneWidget);
    expect(find.text('上一页'), findsNothing, reason: '1 话不该出现分页器');
    expect(find.text('下一页'), findsNothing, reason: '1 话不该出现分页器');

    // 切回默认栏目命中缓存，不重复打接口。
    final defaultCalls =
        requested.where((p) => p.contains('/group/default/chapters')).length;
    await tester.tap(find.text('默認'));
    await _settle(tester, frames: 4);
    expect(tester.takeException(), isNull);
    expect(
      requested.where((p) => p.contains('/group/default/chapters')).length,
      defaultCalls,
      reason: '切回已缓存栏目不应重新请求',
    );
    expect(find.text('215 话 · 完結 · 无解锁 / 无付费'), findsOneWidget);
  });
}

/// 分页按钮是否可点（`onPressed == null` 即为置灰）。
bool _pagerEnabled(WidgetTester tester, String label) {
  final button = tester.widget<TextButton>(
    find
        .ancestor(
          of: find.text(label),
          matching: find.byType(TextButton),
        )
        .first,
  );
  return button.onPressed != null;
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpDetail(WidgetTester tester, _Harness h) async {
  // 高视口让栏目 tab / 分页区间 / 章节网格都进入构建范围。
  tester.view.physicalSize = const Size(420, 3600);
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
      // 详情页的章节格子会读下载状态；测试里不 init，避免碰 path_provider。
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
      home: const ComicDetailScreen(pathWord: 'multi'),
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

  _Harness(List<String> requested) {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      requested.add(path);
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
          'uuid': 'uuid-multi',
          'path_word': 'multi',
          'name': '多栏目测试漫画',
          'cover': '',
          'author': ['测试作者'],
          'brief': '一本有多个章节栏目的漫画。',
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
          'tankobon': {
            'path_word': 'tankobon',
            'count': 1,
            'name': '單行本',
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
    if (path == '/api/v3/comic2/multi') return _detail();
    if (path.contains('/group/') && path.endsWith('/chapters')) {
      final isDefault = path.contains('/group/default/');
      final total = isDefault ? 215 : 1;
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
      final end = (offset + limit).clamp(0, total);
      return {
        'list': [
          for (var i = offset; i < end; i++)
            _chapter('${isDefault ? 'd' : 't'}-$i', i + 1),
        ],
        'total': total,
        'limit': limit,
        'offset': offset,
      };
    }
    // 评论等其它接口：合法空信封。
    return {
      'list': <dynamic>[],
      'total': 0,
      'limit': 20,
      'offset': 0,
    };
  }
}
