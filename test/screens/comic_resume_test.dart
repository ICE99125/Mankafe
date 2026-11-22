import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/comic.dart';
import 'package:mankafe/models/media_page.dart';
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

/// 续读的两套来源 + 空章节 id 的 404 回归。
///
/// 1. **未登录**：只认本机浏览记录。`markSeen` 写的是「作品级」记录
///    （chapterUuid 为空），它不能当成续读目标——旧实现会拿空 id 去请求
///    `/api/v3/comic/{p}/chapter2/`，服务端直接 404。
/// 2. **已登录**：收藏列表每条都带 `last_browse`，续读用它；本机记录优先。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('只有作品级记录（空章节 id）时是「开始阅读」，点开第一话', (tester) async {
    final h = _Harness(loggedIn: false);
    h.state.history.add(HistoryEntry(
      pathWord: 'resume',
      chapterUuid: '',
      chapterName: '',
      at: DateTime.now(),
    ));
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 12);

    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '开始阅读'), findsOneWidget);

    await tester.tap(find.text('开始阅读'));
    await _settle(tester, frames: 20);

    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/c-0'),
      isTrue,
      reason: '没有进度时应该落到该栏目第一话',
    );
    // 空 id 的请求（路径以 chapter2/ 结尾）一次都不该出现。
    expect(
      h.requested.any((u) => u.path.endsWith('/chapter2/')),
      isFalse,
      reason: '空章节 id 会拼出 /chapter2/，服务端 404',
    );
  });

  testWidgets('未登录：本机记录是有效章节时显示「续读 第2话」并直达', (tester) async {
    final h = _Harness(loggedIn: false);
    h.state.history.add(HistoryEntry(
      pathWord: 'resume',
      chapterUuid: 'c-1',
      chapterName: '第2话',
      groupPathWord: 'default',
      at: DateTime.now(),
    ));
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 12);

    expect(find.text('续读 第2话'), findsOneWidget);
    await tester.tap(find.text('续读 第2话'));
    await _settle(tester, frames: 20);

    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/c-1'),
      isTrue,
    );
  });

  testWidgets('已登录：本机没有记录时用收藏夹的 last_browse 续读', (tester) async {
    final h = _Harness(loggedIn: true);
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 14);

    // 收藏接口给的「上次看到第46话」，这一话不在当前目录的 3 话里也照样用它。
    expect(find.text('续读 第46话'), findsOneWidget);
    await tester.tap(find.text('续读 第46话'));
    await _settle(tester, frames: 20);

    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/lb-3'),
      isTrue,
      reason: '续读目标应来自 /member/collect/comics 的 last_browse',
    );
    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/'),
      isFalse,
    );
  });

  testWidgets('打开阅读器就算读到：返回详情后续读改成刚打开的那一话', (tester) async {
    final h = _Harness(loggedIn: false);
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 12);

    // 一开始没有进度：按钮是「开始阅读」，点开第一话。
    expect(find.text('开始阅读'), findsOneWidget);
    await tester.tap(find.text('开始阅读'));
    await _settle(tester, frames: 20);

    // 什么页都没翻就直接返回：旧实现只在翻页时 recordRead，进度仍是空的，
    // 详情页会显示上一次的续读（用户反馈点第3卷回来还是第4卷）。
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await _settle(tester, frames: 12);

    expect(find.text('续读 第1话'), findsOneWidget,
        reason: '加载成功就该把进度落到这一话，不必等用户翻页');
  });

  testWidgets('本机记录不带栏目、不在当前目录时仍然续读（cloud 读过一次后落本地）', (tester) async {
    final h = _Harness(loggedIn: false);
    h.state.history.add(HistoryEntry(
      pathWord: 'resume',
      chapterUuid: 'lb-3',
      chapterName: '第46话',
      // 从账号 last_browse 续读出来的记录不带栏目。
      groupPathWord: null,
      at: DateTime.now(),
    ));
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 12);

    expect(find.text('续读 第46话'), findsOneWidget);
    await tester.tap(find.text('续读 第46话'));
    await _settle(tester, frames: 20);
    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/lb-3'),
      isTrue,
    );
  });

  testWidgets('本机记录的栏目就是当前栏目、目录里却没有这一话时回退第一话', (tester) async {
    final h = _Harness(loggedIn: false);
    h.state.history.add(HistoryEntry(
      pathWord: 'resume',
      chapterUuid: 'deleted-1',
      chapterName: '已删的话',
      groupPathWord: 'default',
      at: DateTime.now(),
    ));
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 12);

    expect(find.text('开始阅读'), findsOneWidget);
    await tester.tap(find.text('开始阅读'));
    await _settle(tester, frames: 20);
    expect(
      h.requested
          .any((u) => u.path == '/api/v3/comic/resume/chapter2/deleted-1'),
      isFalse,
      reason: '同一栏目里翻遍目录都没有的章节多半已删除，别打 404',
    );
    expect(
      h.requested.any((u) => u.path == '/api/v3/comic/resume/chapter2/c-0'),
      isTrue,
    );
  });

  test('收藏条目解析 last_browse / browse 的上次观看位置', () {
    final fromOuter = Comic.fromEntryJson({
      'last_browse': {
        'last_browse_id': 'lb-1',
        'last_browse_name': '第1143話',
      },
      'comic': {'uuid': 'u1', 'path_word': 'p1', 'name': '名偵探柯南'},
    });
    expect(fromOuter.browseChapterId, 'lb-1');
    expect(fromOuter.browseChapterName, '第1143話');

    final fromInner = Comic.fromEntryJson({
      'comic': {
        'uuid': 'u2',
        'path_word': 'p2',
        'name': '怪獸8號',
        'browse': {
          'comic_uuid': 'u2',
          'path_word': 'p2',
          'chapter_uuid': 'lb-2',
          'chapter_name': '最终话',
        },
      },
    });
    expect(fromInner.browseChapterId, 'lb-2');
    expect(fromInner.browseChapterName, '最终话');
  });

  test('collectResume：登录后从收藏快照取上次观看位置，未登录返回 null', () async {
    final h = _Harness(loggedIn: true);
    final resume = await h.repo.collectResume(MediaKind.comic,
        uuid: 'uuid-resume', pathWord: 'resume');
    expect(resume, isNotNull);
    expect(resume!.chapterUuid, 'lb-3');
    expect(resume.chapterName, '第46话');

    final anonymous = _Harness(loggedIn: false);
    final none = await anonymous.repo.collectResume(MediaKind.comic,
        uuid: 'uuid-resume', pathWord: 'resume');
    expect(none, isNull);
    expect(anonymous.requested, isEmpty);
  });

  test('chapterContent：空章节 id 不发请求，直接抛可读错误', () async {
    final h = _Harness(loggedIn: false);
    await expectLater(
      h.repo.chapterContent('resume', '', const []),
      throwsA(isA<ApiException>()),
    );
    expect(h.requested, isEmpty);
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
      home: const ComicDetailScreen(pathWord: 'resume'),
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
  final List<Uri> requested = [];

  _Harness({required bool loggedIn}) {
    state = AppState();
    if (loggedIn) state.authToken = 'test-token';
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      requested.add(request.url);
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
          'uuid': 'uuid-resume',
          'path_word': 'resume',
          'name': '续读测试漫画',
          'cover': '',
          'author': ['测试作者'],
          'brief': '用来验证续读来源与空章节 id。',
          'popular': 100,
          'datetime_updated': '2026-11-12 10:00:00',
          'status': 'ongoing',
          'theme': [
            {'name': '冒险', 'path_word': 'adventure'}
          ],
          'last_chapter': '第3话',
        },
        'groups': {
          'default': {'path_word': 'default', 'count': 3, 'name': '默認'},
        },
      };

  static Map<String, dynamic> _chapter(String uuid, int index) => {
        'uuid': uuid,
        'name': '第$index话',
        'index': index - 1,
        'size': 10,
        'datetime_created': '2026-01-01',
      };

  static Map<String, dynamic> _resultsFor(http.Request request) {
    final path = request.url.path;
    if (path == '/api/v3/comic2/resume') return _detail();
    if (path == '/api/v3/member/collect/comics') {
      return {
        'list': [
          {
            'last_browse': {
              'last_browse_id': 'lb-3',
              'last_browse_name': '第46话',
            },
            'comic': {
              'uuid': 'uuid-resume',
              'path_word': 'resume',
              'name': '续读测试漫画',
              'last_chapter_id': 'c-2',
              'last_chapter': {'name': '第3话'},
            },
          },
        ],
        'total': 1,
        'limit': 100,
        'offset': 0,
      };
    }
    if (path == '/api/v3/comic/resume/group/default/chapters') {
      return {
        'list': [
          _chapter('c-0', 1),
          _chapter('c-1', 2),
          _chapter('c-2', 3),
        ],
        'total': 3,
        'limit': 100,
        'offset': 0,
      };
    }
    if (path.startsWith('/api/v3/comic/resume/chapter2/')) {
      final uuid = path.split('/').last;
      const names = {
        'c-0': '第1话',
        'c-1': '第2话',
        'c-2': '第3话',
        'lb-3': '第46话',
      };
      return {
        'chapter': {
          'uuid': uuid,
          'name': names[uuid] ?? '第1话',
          'contents': [
            {'url': 'https://img.test/1.jpg', 'width': 800, 'height': 1200}
          ],
          'next': '',
          'prev': '',
        },
      };
    }
    if (path == '/api/v3/comments') {
      return {'list': <dynamic>[], 'total': 0, 'limit': 1, 'offset': 0};
    }
    return {'list': <dynamic>[], 'total': 0, 'limit': 20, 'offset': 0};
  }
}
