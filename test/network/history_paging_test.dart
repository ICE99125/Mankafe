import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/auth_user.dart';
import 'package:mankafe/screens/history_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/widgets/skeleton.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浏览记录的**懒加载 + 骨架屏**：
/// - 首屏没有任何格子时先给三列网格骨架，不闪「还没有浏览记录」；
/// - 每次只拉一页（`limit=21`），滚到离底 480 才开始拉下一页；
/// - `offset` 只数云端条目（本机兜底条目不能算进去），最后一页之后给「已经到底了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首屏骨架 → 滚动续页 → 到底了', (tester) async {
    const total = 46; // 46 条、每页 21 → offset 0 / 21 / 42 三页
    final offsets = <int>[];
    final client = MockClient((request) async {
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      offsets.add(offset);
      if (request.url.path == '/api/v3/member/browse/comics') {
        final items = <Map<String, dynamic>>[
          for (var i = offset; i < offset + 21 && i < total; i++)
            {
              'id': i,
              'last_chapter_id': 1,
              'last_chapter_name': '第 ${i + 1} 话',
              'comic': {
                'name': '作品${(i + 1).toString().padLeft(2, '0')}',
                'path_word': 'pw$i',
                'cover': '',
                'popular': 1000 * (i + 1),
                'datetime_updated': '2026-11-15 10:00:00',
              },
            },
        ];
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'list': items,
            'total': total,
            'limit': 21,
            'offset': offset,
          },
        });
      }
      return _json({
        'code': 200,
        'message': 'ok',
        'results': <String, dynamic>{},
      });
    });

    final state = AppState();
    await state.load();
    await state.saveSession('token', const AuthUser(userId: '1'));
    final routes = RouteManager()..autoFallback = false;
    final repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );

    await tester.pumpWidget(_app(state, repo));

    // 首帧：请求刚起、还没有格子 —— 应该是骨架，不是空态文案。
    expect(find.byType(MediaGridSkeleton), findsOneWidget,
        reason: '首屏要骨架屏，不能先闪「还没有漫画浏览记录」');
    expect(find.text('还没有漫画浏览记录'), findsNothing);

    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(MediaGridSkeleton), findsNothing);
    expect(offsets, [0], reason: '首屏只拉第一页');
    expect(find.text('作品01'), findsOneWidget);

    // 往下滚：第一次拖到底部附近就该拉第二页。
    for (var i = 0; i < 8; i++) {
      if (offsets.length >= 3) break;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(offsets, [0, 21, 42], reason: 'offset 只能按云端条目数递增');

    // 一直滚到底：最后一页的条目和「已经到底了」要能出来。
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('作品46'), findsOneWidget, reason: '第三页的条目要能滚出来');
    expect(find.text('已经到底了'), findsOneWidget);
    expect(offsets.length, 3, reason: '到底之后不能再发下一页请求');
    expect(tester.takeException(), isNull);
  });
}

Widget _app(AppState state, Repository repo) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      Provider<Repository>.value(value: repo),
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
      home: const HistoryScreen(),
    ),
  );
}

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
