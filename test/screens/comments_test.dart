import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/auth_user.dart';
import 'package:mankafe/models/chapter.dart';
import 'package:mankafe/screens/comments_screen.dart';
import 'package:mankafe/screens/comic_detail_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/download_manager.dart';
import 'package:mankafe/services/download_store.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/comment_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 评论功能回归。接口契约来自 base.apk 逆向 + API_MOCK 7.20：
///   `GET /api/v3/comments?comic_id&limit&offset&platform=3`
///   响应 `results = {list[], total, limit, offset, close_comment}`
///
/// 最关键的一条是「不要带 reply_id」：旧实现固定传 `reply_id=0`，服务端会把它
/// 当成「查 0 号评论的子回复」，顶层评论列表永远是空的 —— 这正是详情页
/// 「读者留言」一直没内容的根因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('评论列表请求对齐 base.apk：带 comic_id / platform，不带 reply_id',
      (tester) async {
    final h = _CommentHarness(total: 2, pages: [
      _commentPage(count: 2, total: 2),
    ]);
    await _pumpComments(tester, h);
    await _settle(tester);

    expect(h.commentQueries, isNotEmpty);
    final q = h.commentQueries.first;
    expect(q['comic_id'], 'uuid-pw');
    expect(q['platform'], '3', reason: '不带 platform 会命中反盗版限制');
    expect(q['offset'], '0');
    expect(q['limit'], '20');
    expect(q.containsKey('reply_id'), isFalse,
        reason: 'reply_id=0 会被当成查子回复，导致顶层列表恒为空');

    expect(find.byType(CommentTile), findsNWidgets(2));
    expect(find.text('读者甲'), findsOneWidget);
    expect(find.text('第一条评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('评论模型按线上字段映射：comment → 正文，count → 回复数', (tester) async {
    final c = ComicComment.fromJson({
      'id': 24195,
      'create_at': '2026-11-13 22:37:30',
      'user_id': 'u1',
      'user_name': 'jkihttg',
      'user_avatar': 'https://s3.mangafunb.fun/user/cover/copymanga.png',
      'comment': '作者在推特已经更新了 汉化组赶紧',
      'count': 7,
      'parent_id': null,
      'parent_user_id': null,
      'parent_user_name': null,
    });

    expect(c.id, '24195');
    expect(c.content, '作者在推特已经更新了 汉化组赶紧',
        reason: '正文在 `comment` 字段，读 `content` 会全空');
    expect(c.replyCount, 7, reason: '`count` 是这条评论的回复数（不是点赞数），实测发一条回复 +1');
    expect(c.avatar, 'https://s3.mangafunb.fun/user/cover/copymanga.png');
    expect(c.parentId, '0', reason: '顶层评论 parent_id 是 null，归一成 0');
    expect(c.replyUserName, isEmpty);
  });

  testWidgets('评论分页器：上一页/下一页整页换，页码与区间同步', (tester) async {
    final h = _CommentHarness(total: 45, pages: [
      _commentPage(count: 20, total: 45),
      _commentPage(count: 20, total: 45, start: 20),
      _commentPage(count: 5, total: 45, start: 40),
    ]);
    await _pumpComments(tester, h);
    await _settle(tester);

    // 第一页只发一次请求：分页器按需翻页，不再「首屏就预取下一页」。
    expect(h.commentQueries.length, 1, reason: '只有翻页时才请求新一页');
    expect(h.commentQueries.single['offset'], '0');
    expect(find.text('1-20 / 45'), findsOneWidget);
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(_pagerEnabled(tester, '上一页'), isFalse, reason: '第一页不该能往前翻');
    expect(_pagerEnabled(tester, '下一页'), isTrue);

    // 下一页：整页换掉，offset 前进一页，上一页的条目不再留在列表里。
    await tester.tap(find.text('下一页'));
    await _settle(tester);
    expect(h.commentQueries.last['offset'], '20');
    expect(find.text('21-40 / 45'), findsOneWidget);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('第 20 条评论'), findsOneWidget);
    expect(find.text('第一条评论'), findsNothing, reason: '分页是整页换，不是追加');

    // 末页：区间按 total 收口（不是 41-60），下一页置灰。
    await tester.tap(find.text('下一页'));
    await _settle(tester);
    expect(h.commentQueries.last['offset'], '40');
    expect(find.text('41-45 / 45'), findsOneWidget);
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(_pagerEnabled(tester, '下一页'), isFalse);
    expect(find.text('第 44 条评论'), findsOneWidget);

    // 上一页回退。
    await tester.tap(find.text('上一页'));
    await _settle(tester);
    expect(h.commentQueries.last['offset'], '20');
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换页失败给整页错误态，点重试能拉到目标页', (tester) async {
    // 第一页成功；第二页的两次尝试（ApiClient 内建重试 call 1、2）都失败，
    // 整页换成错误态而不是继续显示上一页；点「重试」后拉到第二页。
    final h = _CommentHarness(
      total: 45,
      pages: [
        _commentPage(count: 20, total: 45),
        _commentPage(count: 20, total: 45, start: 20),
        _commentPage(count: 5, total: 45, start: 40),
      ],
      failCalls: [1, 2],
    );
    await _pumpComments(tester, h);
    await _settle(tester);

    expect(find.text('第一条评论'), findsOneWidget, reason: '首屏评论已加载');
    expect(find.text('重试'), findsNothing);

    await tester.tap(find.text('下一页'));
    await _settle(tester);

    expect(find.text('重试'), findsOneWidget, reason: '换页失败必须给出可点击的重试入口');
    expect(find.text('第一条评论'), findsNothing,
        reason: '失败时不该把上一页内容留在屏上，否则看着像没翻动');

    await tester.tap(find.text('重试'));
    await _settle(tester);

    expect(find.text('重试'), findsNothing);
    expect(find.text('第 2 / 3 页'), findsOneWidget, reason: '重试后停在目标页');
    expect(find.text('第 20 条评论'), findsOneWidget);
    expect(find.text('21-40 / 45'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close_comment=true 时禁用输入栏并提示已关闭', (tester) async {
    final h = _CommentHarness(total: 1, closeComment: true, pages: [
      _commentPage(count: 1, total: 1),
    ]);
    await _pumpComments(tester, h);
    await _settle(tester);

    expect(find.text('该漫画已关闭评论'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(find.byType(CommentTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情页不再内嵌读者留言：总数挂在导航栏评论角标上', (tester) async {
    final h = _CommentHarness(
        total: 37,
        pages: [
          _commentPage(count: 3, total: 37),
        ],
        detail: true);
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 10);

    // 正文里的「读者留言」区块整块撤掉，评论只在顶栏留一个入口。
    expect(find.text('读者留言'), findsNothing);
    expect(find.byType(CommentPreviewCard), findsNothing);

    // 角标只要一个 total：limit=1，不下载整页评论。
    expect(h.commentQueries.single['limit'], '1');
    expect(h.commentQueries.single['offset'], '0');

    expect(find.byType(CommentCountButton), findsOneWidget);
    expect(
      tester.widget<CommentCountButton>(find.byType(CommentCountButton)).count,
      37,
    );
    expect(find.text('37'), findsOneWidget, reason: '角标显示评论总数');

    // 点图标才进入评论详情页。
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await _settle(tester, frames: 10);
    expect(find.text('漫画评论 · 37'), findsOneWidget);
    expect(find.text('评论须知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有评论时不挂角标，点进去是空态与「写第一条」', (tester) async {
    final h = _CommentHarness(
        total: 0,
        pages: [
          _commentPage(count: 0, total: 0),
        ],
        detail: true);
    await _pumpDetail(tester, h);
    await _settle(tester, frames: 10);

    expect(find.byType(CommentCountButton), findsOneWidget);
    expect(
      tester.widget<CommentCountButton>(find.byType(CommentCountButton)).count,
      0,
    );
    expect(find.text('0'), findsNothing, reason: 'total=0 时不显示角标数字');

    await tester.tap(find.byIcon(Icons.forum_outlined));
    await _settle(tester, frames: 10);
    expect(find.text('还没有评论，来抢沙发吧'), findsOneWidget);
    expect(find.text('写第一条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('头像加载中不打断列表布局（无界约束下不能撑成无限大）', (tester) async {
    // 回归：头像占位原来写的是 `width/height: double.infinity`，而头像在 `Row`
    // 里拿到的是沿主轴无界的约束 → 抛 `BoxConstraints forces an infinite width
    // and infinite height`，这一行的布局当场中断，列表后面几行不再布局：界面表现
    // 是「只画了前几条、下面一大片空白、滚也滚不动，明明还有更多」。
    // 这里只要头像带 URL（进入加载态）且放在 Row 里，就必须零异常。
    _sizeView(tester);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Row(children: [
              CommentAvatar(
                name: '读者甲',
                avatar: 'https://example.invalid/avatar.png',
              ),
              SizedBox(width: 12),
              Expanded(child: Text('一层的评论正文')),
            ]),
          ],
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '加载中的占位必须有界，不能抛出无限约束');
    expect(tester.getSize(find.byType(ClipOval)), const Size(40, 40));
  });

  testWidgets('窄屏 360dp：角标压成 999+，分页器与输入栏不溢出', (tester) async {
    final h = _CommentHarness(
        total: 1300,
        pages: [
          _commentPage(count: 20, total: 1300),
        ],
        detail: true);
    await _pumpDetail(tester, h, width: 360);
    await _settle(tester, frames: 10);

    // 顶栏多了评论图标 + 角标，窄屏上四位数字必须压成「999+」。
    expect(find.text('999+'), findsOneWidget, reason: '超过 999 条压成 999+');
    expect(tester.takeException(), isNull, reason: '360dp 顶栏两个图标不溢出');

    await tester.tap(find.byIcon(Icons.forum_outlined));
    await _settle(tester, frames: 10);
    expect(find.text('1-20 / 1300'), findsOneWidget);
    expect(find.text('第 1 / 65 页'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '360dp 窄屏上分页器 + 输入栏不溢出');
  });

  testWidgets('点「N 条回复」按 reply_id 拉整棵回复树并就地展开', (tester) async {
    final h = _CommentHarness(
      total: 1,
      loggedIn: true,
      pages: [
        {
          'list': [_rootComment(id: 24000, count: 2)],
          'total': 1,
          'limit': 20,
          'offset': 0,
        },
      ],
      threads: {
        '24000': _replyPage([
          // 线上是时间倒序；本地按 parent_id 还原层级、按时间正序渲染。
          _replyRow(
            id: 24002,
            content: '二级回复正文',
            parentId: 24001,
            userId: 'u8',
            userName: '读者丙',
            parentUserName: '读者乙',
            createdAt: '2026-11-12 10:05:00',
          ),
          _replyRow(
            id: 24001,
            content: '直接回复正文',
            parentId: 24000,
            userId: 'u9',
            userName: '读者乙',
            parentUserName: '读者甲',
            createdAt: '2026-11-12 10:03:00',
          ),
        ]),
      },
    );
    await _pumpComments(tester, h);
    await _settle(tester);

    expect(find.text('2 条回复'), findsOneWidget);
    expect(find.text('直接回复正文'), findsNothing, reason: '没展开前不去拉回复树');
    expect(h.threadQueries, isEmpty);

    await tester.tap(find.text('2 条回复'));
    await _settle(tester);

    expect(h.threadQueries.single['reply_id'], '24000');
    expect(h.threadQueries.single['comic_id'], 'uuid-pw');
    expect(find.text('直接回复正文'), findsOneWidget);
    expect(find.text('二级回复正文'), findsOneWidget);
    // 直接回复根评论不重复「回复 @楼主」；二级回复要标出回复的是谁。
    expect(find.text('回复 @读者乙'), findsOneWidget);
    expect(find.text('回复 @读者甲'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点回复后发送带 reply_id：落成子回复并自动刷新这棵树', (tester) async {
    final h = _CommentHarness(
      total: 1,
      loggedIn: true,
      pages: [
        {
          'list': [_rootComment(id: 24000, count: 1)],
          'total': 1,
          'limit': 20,
          'offset': 0,
        },
      ],
      threads: {
        '24000': _replyPage([
          _replyRow(
            id: 24001,
            content: '已有的回复',
            parentId: 24000,
            userName: '读者乙',
            createdAt: '2026-11-12 10:03:00',
          ),
        ]),
      },
    );
    await _pumpComments(tester, h);
    await _settle(tester);

    await tester.tap(find.text('回复').first);
    await _settle(tester);

    expect(find.text('回复 @读者甲'), findsWidgets, reason: '输入栏标签与占位都切成「回复 @某某」');
    expect(h.threadQueries.length, 1, reason: '点回复就地展开目标评论的回复树');

    await tester.enterText(find.byType(TextField), '我来回复你');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);

    final form = h.forms.single;
    expect(form['method'], 'POST');
    expect(form['comic_id'], 'uuid-pw');
    expect(form['reply_id'], '24000', reason: '不带 reply_id 服务端就当顶层评论写');
    expect(form['comment'], '我来回复你');
    expect(h.threadQueries.length, 2, reason: '发完自动重拉这棵树，用户不用下拉刷新');
    expect(find.text('回复成功'), findsOneWidget);
    expect(find.text('回复 @读者甲'), findsNothing, reason: '发完退出回复态');
    expect(tester.takeException(), isNull);
  });

  testWidgets('发表顶层评论后自动重拉列表，不依赖手动下拉刷新', (tester) async {
    final h = _CommentHarness(
      total: 1,
      loggedIn: true,
      pages: [
        _commentPage(count: 1, total: 1),
      ],
    );
    await _pumpComments(tester, h);
    await _settle(tester);
    expect(h.commentQueries.length, 1);

    await tester.enterText(find.byType(TextField), '刚发的评论');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);

    final form = h.forms.single;
    expect(form['method'], 'POST');
    expect(form['comment'], '刚发的评论');
    expect(form['reply_id'], '', reason: '顶层评论 reply_id 必须是空串');
    expect(h.commentQueries.length, 2, reason: '发完自动重新拉第 1 页');
    expect(find.text('评论成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除自己的评论：DELETE + form body，本地即时移除', (tester) async {
    final h = _CommentHarness(
      total: 2,
      loggedIn: true,
      pages: [
        {
          'list': [
            {
              'id': 24000,
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
              'id': 24001,
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
    await _pumpComments(tester, h);
    await _settle(tester);

    expect(find.text('删除'), findsOneWidget, reason: '只有自己的评论显示「删除」');

    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(find.text('删除这条评论？删除后无法恢复。'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await _settle(tester);

    final form = h.forms.single;
    expect(form['method'], 'DELETE');
    expect(form['comic_id'], 'uuid-pw');
    expect(form['comment_id'], '24000');
    expect(form['platform'], '3', reason: '删除参数全部走 form body');
    expect(form['authorization'], 'Token token');

    expect(find.text('我自己的评论'), findsNothing, reason: '删完立刻从列表消失');
    expect(find.text('别人的评论'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('删除吐槽走 DELETE /api/v3/member/roast，body 带 chapter_id + roast_id',
      () async {
    final routes = RouteManager()..autoFallback = false;
    final state = AppState()..authToken = 'token';
    final calls = <http.Request>[];
    final client = MockClient((request) async {
      calls.add(request);
      return _json(null);
    });
    final repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );

    await repo.deleteRoast('chapter-1', '9001');

    final req = calls.single;
    expect(req.method, 'DELETE', reason: '吐槽是另一张表，不能拿 /member/comment 删');
    expect(req.url.path, '/api/v3/member/roast');
    final body = Uri.splitQueryString(req.body);
    expect(body['roast_id'], '9001');
    expect(body['chapter_id'], 'chapter-1');
    expect(body['platform'], '3');
    expect(body['authorization'], 'Token token');
  });
}

/// 顶层评论（`parent_id` 为 null，`count` 即回复数）。
Map<String, dynamic> _rootComment({required int id, int count = 0}) => {
      'id': id,
      'create_at': '2026-11-12 10:00:00',
      'user_id': 'u1',
      'user_name': '读者甲',
      'user_avatar': '',
      'comment': '第一条评论',
      'count': count,
      'parent_id': null,
      'parent_user_id': null,
      'parent_user_name': null,
    };

/// 回复树里的一行：必须自带 `parent_id / parent_user_name`。
Map<String, dynamic> _replyRow({
  required int id,
  required int parentId,
  required String content,
  String userId = 'u9',
  String userName = '读者乙',
  String parentUserName = '读者甲',
  String createdAt = '2026-11-12 10:03:00',
}) =>
    {
      'id': id,
      'create_at': createdAt,
      'user_id': userId,
      'user_name': userName,
      'user_avatar': '',
      'comment': content,
      'count': 0,
      'parent_id': parentId,
      'parent_user_id': 'u1',
      'parent_user_name': parentUserName,
    };

/// 分页按钮是否可点：按钮置灰时 `onPressed` 为 null。
bool _pagerEnabled(WidgetTester tester, String label) {
  final finder = find
      .ancestor(of: find.text(label), matching: find.byType(TextButton))
      .first;
  return tester.widget<TextButton>(finder).onPressed != null;
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

http.Response _json(Object? results) => http.Response(
      jsonEncode({'code': 200, 'message': 'ok', 'results': results}),
      200,
      headers: {'content-type': 'application/json'},
    );

/// 按线上实测结构造响应：正文是 `comment`、`count` 是回复数、
/// 没有 `reply_id` / `reply_count`，`parent_id` 顶层为 null。
Map<String, dynamic> _commentPage({
  required int count,
  required int total,
  int start = 0,
}) =>
    {
      'list': [
        for (var i = 0; i < count; i++)
          {
            'id': 24000 + start + i,
            'create_at': '2026-11-12 10:00:00',
            'user_id': start + i == 0 ? 'me' : 'u${start + i}',
            'user_name': start + i == 0 ? '读者甲' : '读者${start + i}',
            'user_avatar': '',
            'comment': start + i == 0 ? '第一条评论' : '第 ${start + i} 条评论',
            'count': start + i,
            'parent_id': null,
            'parent_user_id': null,
            'parent_user_name': null,
          },
      ],
      'total': total,
      'limit': 20,
      'offset': start,
    };

/// `GET /api/v3/comments?reply_id={id}` 的响应：**整棵回复树、扁平数组**，
/// 每条自带 `parent_id / parent_user_name`，按时间倒序（和线上一致）。
Map<String, dynamic> _replyPage(List<Map<String, dynamic>> rows) => {
      'list': rows,
      'total': rows.length,
      'limit': 100,
      'offset': 0,
    };

Map<String, dynamic> _comicJson() => {
      'uuid': 'uuid-pw',
      'path_word': 'pw',
      'name': '测试漫画',
      'cover': '',
      'author': ['测试作者'],
      'brief': '用于测试的简介。',
      'popular': 12345,
      'datetime_updated': '2026-11-12 10:00:00',
      'status': 'ongoing',
      'theme': [
        {'name': '校园', 'path_word': 'school'}
      ],
    };

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _CommentHarness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  final List<Map<String, String>> commentQueries = [];
  final List<Map<String, String>> threadQueries = [];
  final List<Map<String, dynamic>> pages;

  /// `reply_id` → 这棵回复树。
  final Map<String, Map<String, dynamic>> threads;

  /// 发评论 / 删评论的 form body（`method` 是 POST 或 DELETE）。
  final List<Map<String, dynamic>> forms = [];

  final int total;
  final bool closeComment;
  final bool detail;
  final bool loggedIn;

  /// 0-based 的评论请求序号，命中则抛出网络异常（不消耗 pages 下标）。
  final List<int>? failCalls;

  _CommentHarness({
    required this.total,
    required this.pages,
    this.threads = const {},
    this.closeComment = false,
    this.detail = false,
    this.loggedIn = false,
    this.failCalls,
  }) {
    state = AppState();
    if (loggedIn) {
      state.authToken = 'token';
      state.authUser = const AuthUser(userId: 'me', nickname: '读者甲');
    }
    routes = RouteManager()..autoFallback = false;
    // 按请求里的 offset 选对应页，失败（抛异常）不消耗页下标，
    // 这样「失败 → 重试」能稳定返回同一页。
    final pageByOffset = <int, Map<String, dynamic>>{
      for (final p in pages) (p['offset'] as int): p,
    };
    var commentsCall = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v3/comments') {
        final query = request.url.queryParameters;
        // 带 reply_id 就是拉某条评论下的回复树，不进顶层列表。
        final replyId = query['reply_id'];
        if (replyId != null && replyId.isNotEmpty) {
          threadQueries.add(query);
          return _json(
            threads[replyId] ?? _replyPage(const []),
          );
        }
        commentQueries.add(query);
        final idx = commentsCall++;
        if (failCalls != null && failCalls!.contains(idx)) {
          throw http.ClientException('simulated network error');
        }
        final offset = int.parse(query['offset']!);
        final page = pageByOffset[offset] ?? pages.last;
        return _json({...page, 'close_comment': closeComment});
      }
      if (path == '/api/v3/member/comment') {
        // 服务端只认 form body：删评论也是 DELETE + body。
        forms.add({
          'method': request.method,
          ...Uri.splitQueryString(request.body),
        });
        return _json(null);
      }
      if (path.startsWith('/api/v3/comic2/')) {
        return _json({
          'comic': _comicJson(),
          'groups': {
            'default': {'path_word': 'default', 'name': '默認'},
          },
          'is_collect': false,
        });
      }
      if (path.contains('/group/')) {
        return _json({'list': [], 'total': 0, 'limit': 100, 'offset': 0});
      }
      return _json({'list': [], 'total': 0, 'limit': 20, 'offset': 0});
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

Widget _app(_CommentHarness h, Widget home) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: h.state),
        ChangeNotifierProvider<RouteManager>.value(value: h.routes),
        Provider<Repository>.value(value: h.repo),
        // 详情页章节格子会读下载状态；测试里不 init，避免碰 path_provider。
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

Future<void> _pumpComments(WidgetTester tester, _CommentHarness h) async {
  _sizeView(tester);
  await tester.pumpWidget(_app(
    h,
    const ComicCommentsScreen(pathWord: 'pw', comicId: 'uuid-pw'),
  ));
  await tester.pump();
}

Future<void> _pumpDetail(WidgetTester tester, _CommentHarness h,
    {double width = 420}) async {
  _sizeView(tester, width: width);
  await tester.pumpWidget(_app(h, const ComicDetailScreen(pathWord: 'pw')));
  await tester.pump();
}
