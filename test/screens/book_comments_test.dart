import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/auth_user.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/comments_screen.dart';
import 'package:mankafe/screens/content_detail_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/services/shelf_service.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/comment_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 轻小说评论回归。接口契约来自线上实测（2026-11-15）：
///   `GET /api/v3/bookcomments?book_id&limit&offset&platform=3`
///   响应 `results = {list[], total, limit, offset}`，条目字段与漫画评论一致
///   （`comment` / `count` / `parent_id` / `parent_user_name`）。
///
/// 轻小说与漫画共用同一套评论页，但对象参数换成 `book_id`（作品 uuid），
/// 回复树 / 发表 / 删除换成 `member/bookcomment`。这里钉住四件事：
/// - 详情页顶栏有带总数角标的评论入口，点进去是「轻小说评论 · N」；
/// - 顶层列表带 `book_id`、不带 `reply_id`；
/// - 回复树按 `reply_id` 另拉，发表带 `book_id + comment + reply_id`；
/// - 删除走 DELETE + form body（`book_id` / `comment_id`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('轻小说详情页：顶栏评论角标取 bookcomments 的 total，点进去是轻小说评论', (tester) async {
    _sizeView(tester);
    final h = _Harness(total: 7, pages: [
      _bookPage(count: 7, total: 7),
    ]);
    await h.state.load();

    await tester.pumpWidget(_app(
      h,
      const ContentDetailScreen(kind: MediaKind.novel, pathWord: 'book-1'),
    ));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(h.bookQueries, isNotEmpty, reason: '详情页要主动拉一次评论总数');
    final countQuery = h.bookQueries.first;
    expect(countQuery['book_id'], 'book-uuid',
        reason: '对象是书 uuid，不是 path_word');
    expect(countQuery['platform'], '3');
    expect(countQuery['limit'], '1', reason: '角标只需要信封里的 total');
    expect(countQuery.containsKey('reply_id'), isFalse,
        reason: '带 reply_id 会被当成查子回复，顶层列表恒为空');

    final button =
        tester.widget<CommentCountButton>(find.byType(CommentCountButton));
    expect(button.count, 7);
    expect(find.text('轻小说评论'), findsNothing, reason: 'title 只在 tooltip 里，不占正文');

    await tester.tap(find.byType(CommentCountButton));
    await _settle(tester);

    expect(find.text('轻小说评论 · 7'), findsOneWidget);
    final listQuery = h.bookQueries.last;
    expect(listQuery['book_id'], 'book-uuid');
    expect(listQuery['offset'], '0');
    expect(listQuery['limit'], '20');
    expect(find.byType(CommentTile), findsNWidgets(7));
    expect(find.byType(TextField), findsOneWidget, reason: '整本评论可以发表');
    expect(tester.takeException(), isNull);
  });

  testWidgets('回复：先按 reply_id 拉整棵树，发表带 book_id + comment + reply_id',
      (tester) async {
    _sizeView(tester);
    final h = _Harness(
      total: 1,
      loggedIn: true,
      pages: [
        _bookPage(count: 1, total: 1),
      ],
      threads: {
        '24100': _threadPage([
          {
            'id': 24101,
            'create_at': '2026-11-12 10:03:00',
            'user_id': 'u9',
            'user_name': '读者乙',
            'user_avatar': '',
            'comment': '已有一条回复',
            'count': 0,
            'parent_id': 24100,
            'parent_user_id': 'u1',
            'parent_user_name': '读者甲',
          },
        ]),
      },
    );
    // 不调 state.load()：load 会按空 prefs 覆盖登录态，把 harness 里设的
    // token / authUser 清掉（发表和「删除」都依赖它）。
    await tester.pumpWidget(_app(
      h,
      const ComicCommentsScreen(pathWord: 'book-1', bookId: 'book-uuid'),
    ));
    await _settle(tester);

    await tester.tap(find.text('回复').first);
    await _settle(tester);

    final thread = h.threadQueries.single;
    expect(thread['book_id'], 'book-uuid', reason: '回复树同样是书 uuid');
    expect(thread['reply_id'], '24100');
    expect(find.text('已有一条回复'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '我来回复你');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);

    final form = h.forms.single;
    expect(form['method'], 'POST');
    expect(form['book_id'], 'book-uuid', reason: '发表接口是 member/bookcomment');
    expect(form['comment'], '我来回复你');
    expect(form['reply_id'], '24100', reason: '不带 reply_id 会写成顶层评论');
    expect(h.threadQueries.length, 2, reason: '发完自动重拉这棵树');
    expect(find.text('回复成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除自己的轻小说评论：DELETE + form body（book_id / comment_id）',
      (tester) async {
    _sizeView(tester);
    final h = _Harness(
      total: 2,
      loggedIn: true,
      pages: [
        {
          'list': [
            {
              'id': 24100,
              'create_at': '2026-11-12 10:00:00',
              'user_id': 'me',
              'user_name': '读者甲',
              'user_avatar': '',
              'comment': '我自己的评论',
              'count': 0,
              'parent_id': null,
              'parent_user_id': null,
              'parent_user_name': null,
            },
            {
              'id': 24102,
              'create_at': '2026-11-12 09:00:00',
              'user_id': 'u2',
              'user_name': '读者乙',
              'user_avatar': '',
              'comment': '别人的评论',
              'count': 0,
              'parent_id': null,
              'parent_user_id': null,
              'parent_user_name': null,
            },
          ],
          'total': 2,
          'limit': 20,
          'offset': 0,
        },
      ],
    );
    // 同上：保留 harness 里设置的登录态，否则「删除」入口不会出现。
    await tester.pumpWidget(_app(
      h,
      const ComicCommentsScreen(pathWord: 'book-1', bookId: 'book-uuid'),
    ));
    await _settle(tester);

    expect(find.text('删除'), findsOneWidget, reason: '只有自己的评论显示「删除」');

    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(find.text('删除这条评论？删除后无法恢复。'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await _settle(tester);

    final form = h.forms.single;
    expect(form['method'], 'DELETE');
    expect(form['book_id'], 'book-uuid');
    expect(form['comment_id'], '24100');
    expect(find.text('我自己的评论'), findsNothing);
    expect(find.text('别人的评论'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 一页轻小说评论（字段与漫画评论完全一致）。
Map<String, dynamic> _bookPage({
  required int count,
  required int total,
  int start = 0,
}) =>
    {
      'list': [
        for (var i = 0; i < count; i++)
          {
            'id': 24100 + start + i,
            'create_at': '2026-11-12 10:00:00',
            'user_id': start + i == 0 ? 'me' : 'u${start + i}',
            'user_name': start + i == 0 ? '读者甲' : '读者${start + i}',
            'user_avatar': '',
            'comment': start + i == 0 ? '第一条评论' : '第 ${start + i} 条评论',
            'count': 0,
            'parent_id': null,
            'parent_user_id': null,
            'parent_user_name': null,
          },
      ],
      'total': total,
      'limit': 20,
      'offset': start,
    };

Map<String, dynamic> _threadPage(List<Map<String, dynamic>> rows) => {
      'list': rows,
      'total': rows.length,
      'limit': 100,
      'offset': 0,
    };

Map<String, dynamic> _bookJson() => {
      'uuid': 'book-uuid',
      'path_word': 'book-1',
      'name': '轻小说 A',
      'cover': 'https://s3.example.com/book.jpg',
      'author': ['作者 A'],
      'brief': '简介',
      'datetime_updated': '2026-11-10',
    };

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  final RouteManager routes = RouteManager()..autoFallback = false;
  final AppState state = AppState();
  late final Repository repo;

  final List<Map<String, String>> bookQueries = [];
  final List<Map<String, String>> threadQueries = [];
  final List<Map<String, dynamic>> forms = [];
  final List<Map<String, dynamic>> pages;
  final Map<String, Map<String, dynamic>> threads;
  final int total;

  _Harness({
    required this.total,
    required this.pages,
    this.threads = const {},
    bool loggedIn = false,
  }) {
    if (loggedIn) {
      state.authToken = 'token';
      state.authUser = const AuthUser(userId: 'me', nickname: '读者甲');
    }
    repo = Repository(
      ApiClient(routes, httpClient: _client(), cache: _NoCache()),
      routes,
      state,
    );
  }

  MockClient _client() {
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/book/book-1') {
        return _json({'book': _bookJson(), 'is_collect': false});
      }
      if (path == '/api/v3/book/book-1/volumes') {
        return _json({'list': <dynamic>[], 'total': 0});
      }
      if (path == '/api/v3/bookcomments') {
        final query = request.url.queryParameters;
        final replyId = query['reply_id'];
        if (replyId != null && replyId.isNotEmpty) {
          threadQueries.add(query);
          return _json(threads[replyId] ?? _threadPage(const []));
        }
        bookQueries.add(query);
        final offset = int.parse(query['offset'] ?? '0');
        final page = pages.firstWhere(
          (p) => p['offset'] == offset,
          orElse: () => pages.isEmpty
              ? {'list': <dynamic>[], 'total': 0, 'limit': 20, 'offset': offset}
              : pages.last,
        );
        return _json(page);
      }
      if (path == '/api/v3/member/bookcomment') {
        // 服务端只认 form body：删评论也是 DELETE + body。
        forms.add({
          'method': request.method,
          ...Uri.splitQueryString(request.body),
        });
        return _json(null);
      }
      return _json({'list': <dynamic>[], 'total': 0, 'limit': 20, 'offset': 0});
    });
  }

  static http.Response _json(Object? results) => http.Response(
        jsonEncode({'code': 200, 'message': 'ok', 'results': results}),
        200,
        headers: {'content-type': 'application/json'},
      );
}

Widget _app(_Harness h, Widget home) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: h.state),
        ChangeNotifierProvider<RouteManager>.value(value: h.routes),
        Provider<Repository>.value(value: h.repo),
        ChangeNotifierProvider<ShelfService>(
          create: (_) => ShelfService(repo: h.repo, state: h.state),
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
        home: home,
      ),
    );

void _sizeView(WidgetTester tester, {double width = 420}) {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
