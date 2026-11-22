import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/comic_detail_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/download_manager.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/services/shelf_service.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/widgets/comment_widgets.dart';

/// 真机探针：首次进入漫画详情页时，导航栏评论图标的角标能不能拿到真实总数。
///
/// 评论已经从详情页正文搬到顶栏图标里，这里直接跑真实网络
/// （api.copy20xxxx.com），把 repo 里的 `[comments] comic=… total=…` 日志和
/// 角标数值打到 flutter test 控制台。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首进详情页：导航栏评论角标必须显示总数', (tester) async {
    final state = AppState();
    await state.load();
    final routes = RouteManager();
    final repo = Repository(
      ApiClient(routes, token: () => state.authToken),
      routes,
      state,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<RouteManager>.value(value: routes),
          Provider<Repository>.value(value: repo),
          ChangeNotifierProvider<DownloadManager>(
            create: (_) => DownloadManager(repo: repo)..init(),
          ),
          ChangeNotifierProvider<ShelfService>(
            create: (_) => ShelfService(repo: repo, state: state),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ComicDetailScreen(pathWord: 'modujingbingdenuli'),
        ),
      ),
    );

    // 首帧，然后给网络 10 秒。
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 角标里的数字就是评论总数；正文里不该再出现「读者留言」区块。
    final counts = find
        .byType(CommentCountButton)
        .evaluate()
        .map((e) => (e.widget as CommentCountButton).count)
        .toList();
    final headers = find
        .byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').startsWith('读者留言'))
        .evaluate()
        .length;
    debugPrint('[probe] commentCount=$counts legacyHeader=$headers');
    // ignore: avoid_print
    print('[probe] commentCount=$counts legacyHeader=$headers '
        'exception=${tester.takeException()}');
  });
}
