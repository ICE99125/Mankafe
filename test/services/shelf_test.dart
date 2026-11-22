import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/auth_user.dart';
import 'package:mankafe/models/comic.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/screens/content_detail_screen.dart';
import 'package:mankafe/screens/library_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/download_manager.dart';
import 'package:mankafe/services/download_store.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/services/shelf_service.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收藏的存储策略：**未登录写本地，已登录写云端**。
///
/// 之前只有一个本地 `Set<String>`，与登录态无关，书架还整页门禁；
/// 现在两条真相分开，这里把边界钉住：
/// - 未登录：只写本地、不发任何请求，书架渲染本机收藏；
/// - 已登录：走 `/member/collect/{comic|book|post|cartoon}` 的 form 请求，
///   收藏与取消只差 `is_collect`（1/0），对象 id 字段名按类型不同；
///   失败必须抛出（页面回滚图标），不能假装成功；
/// - 登录后把本机收藏补到云端，成功后清掉本机那份。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const comic = Comic(
    uuid: 'uuid-1',
    pathWord: 'yuekanshaonv',
    name: '月刊少女野崎君',
    cover: 'https://s3.example.com/cover.jpg',
    authors: ['椿泉'],
    lastChapter: '第 115 话',
    updatedAt: '2026-11-10 10:00:00',
  );

  const novel = Comic(
    uuid: 'book-uuid',
    pathWord: 'novel-pw',
    name: '轻小说 A',
    cover: 'https://s3.example.com/book.jpg',
  );
  const photo = Comic(
    uuid: 'post-uuid',
    pathWord: 'post-uuid',
    name: '写真 A',
  );
  const animation = Comic(
    uuid: 'cartoon-uuid',
    pathWord: 'cartoon-pw',
    name: '动画 A',
  );

  group('本地收藏', () {
    test('写入后能读回完整字段，重启后仍在', () async {
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);

      expect(state.isFavorite('yuekanshaonv'), isTrue);
      final entry = state.favoriteOf('yuekanshaonv');
      expect(entry, isNotNull);
      expect(entry!.name, '月刊少女野崎君');
      expect(entry.cover, 'https://s3.example.com/cover.jpg');
      expect(entry.lastChapter, '第 115 话');
      expect(entry.addedAt, greaterThan(0));

      // 模拟重启：新的 AppState 从同一份 SharedPreferences 读回。
      final reopened = AppState();
      await reopened.load();
      expect(reopened.isFavorite('yuekanshaonv'), isTrue);
      expect(reopened.favoriteOf('yuekanshaonv')!.name, '月刊少女野崎君');
    });

    test('取消收藏后本地与持久化都清掉', () async {
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);
      await state.setLocalFavorite(comic, false);

      expect(state.isFavorite('yuekanshaonv'), isFalse);
      final reopened = AppState();
      await reopened.load();
      expect(reopened.isFavorite('yuekanshaonv'), isFalse);
    });

    test('旧版只存 path_word 的数据会迁移成条目，不丢收藏', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pref_favorites': <String>['old-a', 'old-b'],
      });
      final state = AppState();
      await state.load();

      expect(state.localFavorites.length, 2);
      expect(state.isFavorite('old-a'), isTrue);
      expect(state.favoriteOf('old-a')!.pathWord, 'old-a');
      // 名称缺失时退回 path_word，不能显示成空白。
      expect(state.favoriteOf('old-a')!.toComic().name, 'old-a');
    });

    test('mergeFavorite 只补全已收藏条目，不会凭空新增', () async {
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(
          const Comic(uuid: 'u-0', pathWord: 'only-path', name: ''), true);

      await state.mergeFavorite(const Comic(
        pathWord: 'only-path',
        uuid: 'u-1',
        name: '补全后的名字',
        cover: 'https://s3.example.com/c.jpg',
      ));
      await state.mergeFavorite(comic); // 未收藏 → 不该新增

      expect(state.localFavorites.length, 1);
      expect(state.favoriteOf('only-path')!.name, '补全后的名字');
      expect(state.isFavorite('yuekanshaonv'), isFalse);
    });

    test('四类内容各自收藏：类型随条目落盘，同标识不互相覆盖', () async {
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);
      await state.setLocalFavorite(novel, true, kind: MediaKind.novel);
      await state.setLocalFavorite(photo, true, kind: MediaKind.photo);
      await state.setLocalFavorite(animation, true, kind: MediaKind.animation);
      // 同一个标识在两类内容下各自成立（写真用 uuid，容易和 path_word 撞）。
      await state.setLocalFavorite(
          const Comic(uuid: 'shared-1', pathWord: 'shared-pw', name: '同名条目'),
          true);
      await state.setLocalFavorite(
          const Comic(uuid: 'shared-1', pathWord: 'shared-pw', name: '同名条目'),
          true,
          kind: MediaKind.novel);

      expect(state.localFavorites.length, 6);
      expect(state.isFavorite('novel-pw', kind: MediaKind.novel), isTrue);
      expect(state.isFavorite('novel-pw'), isFalse, reason: '类型不匹配不算收藏');
      expect(
          state.localFavoritesOf(MediaKind.photo).single.pathWord, 'post-uuid');

      // 模拟重启：类型必须一起读回来，否则书架四个页签会串。
      final reopened = AppState();
      await reopened.load();
      expect(reopened.favoriteOf('cartoon-pw', kind: MediaKind.animation)?.kind,
          MediaKind.animation);
      expect(reopened.localFavoritesOf(MediaKind.novel).length, 2);
      expect(reopened.localFavoritesOf(MediaKind.comic).length, 2);
      expect(reopened.isFavorite('novel-pw', kind: MediaKind.novel), isTrue);
    });
  });

  group('ShelfService', () {
    test('未登录：只写本地，一个请求都不发', () async {
      final h = _Harness();
      final state = AppState();
      await state.load();
      final shelf = ShelfService(repo: h.repo(state), state: state);

      final now = await shelf.toggle(comic);

      expect(now, isTrue);
      expect(state.isFavorite('yuekanshaonv'), isTrue);
      expect(h.requests, isEmpty, reason: '未登录不该请求 member 写接口');
    });

    test('已登录：收藏 / 取消都是同端点 + is_collect（1/0）', () async {
      final h = _Harness();
      final state = await _loggedIn();
      final shelf = ShelfService(repo: h.repo(state), state: state);

      expect(await shelf.toggle(comic), isTrue);
      expect(h.requests.single.path, '/api/v3/member/collect/comic');
      expect(h.requests.single.method, 'POST');
      expect(h.requests.single.body['comic_id'], 'uuid-1');
      expect(h.requests.single.body['is_collect'], '1');
      // 线上要求 form-urlencoded + 设备字段（与抓包一致），JSON 会被当成没带参数。
      expect(h.requests.single.form, isTrue, reason: '必须是 form 请求');
      expect(h.requests.single.body['authorization'], startsWith('Token '));
      expect(state.isFavorite('yuekanshaonv'), isFalse, reason: '已登录时本地不参与判定');

      expect(await shelf.toggle(comic, currentIsFavorite: true), isFalse);
      expect(h.requests.last.path, '/api/v3/member/collect/comic',
          reason: '取消收藏不是 /collects/delete，而是同一个端点传 is_collect=0');
      expect(h.requests.last.body['comic_id'], 'uuid-1');
      expect(h.requests.last.body['is_collect'], '0');
    });

    test('四种内容各用各的端点与 id 字段名', () async {
      final h = _Harness();
      final state = await _loggedIn();
      final shelf = ShelfService(repo: h.repo(state), state: state);

      expect(await shelf.toggle(comic), isTrue);
      expect(await shelf.toggle(novel, kind: MediaKind.novel), isTrue);
      expect(await shelf.toggle(photo, kind: MediaKind.photo), isTrue);
      expect(await shelf.toggle(animation, kind: MediaKind.animation), isTrue);

      final calls = h.requests;
      expect(calls[0].path, '/api/v3/member/collect/comic');
      expect(calls[0].body['comic_id'], 'uuid-1');
      expect(calls[1].path, '/api/v3/member/collect/book');
      expect(calls[1].body['book_id'], 'book-uuid');
      expect(calls[1].body.containsKey('comic_id'), isFalse);
      expect(calls[2].path, '/api/v3/member/collect/post');
      expect(calls[2].body['post_id'], 'post-uuid');
      expect(calls[3].path, '/api/v3/member/collect/cartoon');
      expect(calls[3].body['cartoon_id'], 'cartoon-uuid');
      for (final call in calls) {
        expect(call.body['is_collect'], '1');
      }
    });

    test('已登录且服务端返回 success:false → 抛出，不能假装成功', () async {
      final h = _Harness(failCollect: true);
      final state = await _loggedIn();
      final shelf = ShelfService(repo: h.repo(state), state: state);

      await expectLater(shelf.toggle(comic), throwsA(isA<ApiException>()));
    });

    test('登录后把本机收藏补到云端，成功后清空本机', () async {
      final h = _Harness();
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);
      await state.setLocalFavorite(
          const Comic(pathWord: 'second', uuid: 'uuid-2', name: '第二本'), true);

      await state.saveSession('tok', const AuthUser(userId: '1'));
      final shelf = ShelfService(repo: h.repo(state), state: state);

      final moved = await shelf.syncLocalToCloud();

      expect(moved, 2);
      expect(state.localFavorites, isEmpty, reason: '同步成功后清掉本机那份');
      expect(
        h.requests.map((r) => r.path),
        everyElement('/api/v3/member/collect/comic'),
      );
      expect(
        h.requests.map((r) => r.body['comic_id']),
        containsAll(<String>['uuid-1', 'uuid-2']),
      );
    });

    test('同步中途失败：已上传的清掉，剩下的留着下次再试', () async {
      final h = _Harness(failAfter: 1);
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);
      await state.setLocalFavorite(
          const Comic(pathWord: 'second', uuid: 'uuid-2', name: '第二本'), true);
      await state.saveSession('tok', const AuthUser(userId: '1'));
      final shelf = ShelfService(repo: h.repo(state), state: state);

      final moved = await shelf.syncLocalToCloud();

      expect(moved, 1);
      expect(state.localFavorites.length, 1);
    });
    test('已登录：小说 / 写真 / 动画收藏各走自己的端点', () async {
      final h = _Harness();
      final state = await _loggedIn();
      final shelf = ShelfService(repo: h.repo(state), state: state);

      expect(await shelf.toggle(novel, kind: MediaKind.novel), isTrue);
      expect(h.requests.last.path, '/api/v3/member/collect/book');
      expect(h.requests.last.body['book_id'], 'book-uuid');
      expect(h.requests.last.body['is_collect'], '1');

      expect(await shelf.toggle(photo, kind: MediaKind.photo), isTrue);
      expect(h.requests.last.path, '/api/v3/member/collect/post');
      expect(h.requests.last.body['post_id'], 'post-uuid');

      expect(await shelf.toggle(animation, kind: MediaKind.animation), isTrue);
      expect(h.requests.last.path, '/api/v3/member/collect/cartoon');
      expect(h.requests.last.body['cartoon_id'], 'cartoon-uuid');

      // 取消同样是原端点，只把 is_collect 换成 0。
      expect(
          await shelf.toggle(novel,
              kind: MediaKind.novel, currentIsFavorite: true),
          isFalse);
      expect(h.requests.last.path, '/api/v3/member/collect/book');
      expect(h.requests.last.body['is_collect'], '0');
    });

    test('登录后同步：每条按自己的类型打对应端点', () async {
      final h = _Harness();
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(comic, true);
      await state.setLocalFavorite(novel, true, kind: MediaKind.novel);
      await state.setLocalFavorite(photo, true, kind: MediaKind.photo);
      await state.saveSession('tok', const AuthUser(userId: '1'));
      final shelf = ShelfService(repo: h.repo(state), state: state);

      final moved = await shelf.syncLocalToCloud();

      expect(moved, 3);
      expect(state.localFavorites, isEmpty);
      expect(
        h.requests.map((r) => r.path).toSet(),
        {
          '/api/v3/member/collect/comic',
          '/api/v3/member/collect/book',
          '/api/v3/member/collect/post',
        },
      );
    });

    test('同步中途失败：按类型+标识清理，不误删另一类的同名条目', () async {
      final h = _Harness(failAfter: 1);
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(
          const Comic(uuid: 'same-uuid', pathWord: 'same', name: '同名'), true);
      await state.setLocalFavorite(
          const Comic(uuid: 'same-uuid', pathWord: 'same', name: '同名'), true,
          kind: MediaKind.novel);
      await state.saveSession('tok', const AuthUser(userId: '1'));
      final shelf = ShelfService(repo: h.repo(state), state: state);

      final moved = await shelf.syncLocalToCloud();

      expect(moved, 1);
      expect(state.localFavorites.length, 1, reason: '只清掉已上传的那一类');
    });

    test('轻小说 / 动画 / 写真详情：服务端给的收藏状态直接采用', () async {
      final h =
          _Harness(bookCollect: true, cartoonCollect: true, postCollect: false);
      final state = await _loggedIn();
      final repo = h.repo(state);

      final book = await repo.contentDetail(MediaKind.novel, 'novel-pw',
          withChapters: false);
      expect(book.isCollect, isTrue);
      expect(book.item.name, '轻小说 A');

      final cartoon = await repo.contentDetail(
          MediaKind.animation, 'cartoon-pw',
          withChapters: false);
      expect(cartoon.isCollect, isTrue, reason: '动画用 collect 对象表示已收藏');

      final post = await repo.contentDetail(MediaKind.photo, 'post-uuid',
          withChapters: false);
      expect(post.isCollect, isFalse);

      // 服务端给了明确值就不该再跑账号收藏列表。
      expect(
        h.requests.where((r) => r.path.startsWith('/api/v3/member/collect/')),
        isEmpty,
      );
    });

    test('详情没给收藏状态时，登录态用账号收藏列表补齐', () async {
      final h = _Harness(
        collectByPath: {
          '/api/v3/member/collect/books': [
            {
              'book': {
                'uuid': 'book-uuid',
                'path_word': 'novel-pw',
                'name': '轻小说 A',
              }
            }
          ]
        },
      );
      final state = await _loggedIn();
      final repo = h.repo(state);

      final book = await repo.contentDetail(MediaKind.novel, 'novel-pw',
          withChapters: false);

      expect(book.isCollect, isTrue, reason: '服务端没给 → 查账号收藏列表');
      expect(
        h.requests.any((r) =>
            r.path == '/api/v3/member/collect/books' && r.method == 'GET'),
        isTrue,
      );
    });

    test('未登录：详情没给收藏状态时以本机收藏为准，且不发请求', () async {
      final h = _Harness();
      final state = AppState();
      await state.load();
      await state.setLocalFavorite(novel, true, kind: MediaKind.novel);
      final repo = h.repo(state);

      final book = await repo.contentDetail(MediaKind.novel, 'novel-pw',
          withChapters: false);

      expect(book.isCollect, isTrue);
      expect(
        h.requests.where((r) => r.path.startsWith('/api/v3/member/')),
        isEmpty,
      );
    });

    test('已登录：详情页 is_collect 只看服务端，不被本地残留点亮', () async {
      final h = _Harness(detailIsCollect: false);
      final state = AppState();
      await state.load();
      // 登录前留下的本机收藏：登录后不该再影响详情页的收藏图标。
      await state.setLocalFavorite(comic, true);
      await state.saveSession('tok', const AuthUser(userId: '1'));

      final detail = await h.repo(state).detail('yuekanshaonv');

      expect(detail.isCollect, isFalse, reason: '已登录时以服务端 is_collect 为准');
    });
  });

  testWidgets('未登录书架按四个页签分流本机收藏', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    await state.setLocalFavorite(comic, true);
    await state.setLocalFavorite(novel, true, kind: MediaKind.novel);

    await tester.pumpWidget(_app(h, state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('仅本机收藏 2 本'), findsOneWidget);
    expect(find.text('月刊少女野崎君'), findsOneWidget);
    expect(find.text('轻小说 A'), findsNothing, reason: '默认停在漫画页签');

    await tester.tap(find.text('轻小说'));
    await tester.pump();
    expect(find.text('轻小说 A'), findsOneWidget);
  });

  testWidgets('未登录：详情页收藏按钮写本机，收的是当前类型', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness(bookCollect: false);
    final state = AppState();
    await state.load();

    await tester.pumpWidget(_contentApp(h, state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('收藏'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已收藏'), findsOneWidget);
    expect(find.text('已加入本机收藏'), findsOneWidget);
    expect(state.isFavorite('novel-pw', kind: MediaKind.novel), isTrue);
    expect(state.isFavorite('novel-pw'), isFalse, reason: '不该记成漫画收藏');
    expect(
      h.requests.where((r) => r.path.startsWith('/api/v3/member/')),
      isEmpty,
      reason: '未登录收藏不能打云端接口',
    );
  });

  testWidgets('未登录只收藏了轻小说时，书架直接落到轻小说页签', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    await state.setLocalFavorite(novel, true, kind: MediaKind.novel);

    await tester.pumpWidget(_app(h, state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 漫画页签为空，不该让用户先看到「这里还没有收藏」。
    expect(find.text('轻小说 A'), findsOneWidget);
  });

  testWidgets('未登录书架直接显示本机收藏，而不是「登录后查看书架」', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();
    await state.setLocalFavorite(comic, true);

    await tester.pumpWidget(_app(h, state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('月刊少女野崎君'), findsOneWidget, reason: '本机收藏要能直接看到封面卡片');
    expect(find.text('登录后查看书架'), findsNothing, reason: '未登录不再整页门禁');
    expect(find.textContaining('仅本机收藏 1 本'), findsOneWidget);
  });

  testWidgets('未登录且没有收藏时给出「在本机收藏」的空态', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = _Harness();
    final state = AppState();
    await state.load();

    await tester.pumpWidget(_app(h, state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('这里还没有收藏'), findsOneWidget);
    expect(find.textContaining('只存在本机'), findsOneWidget);
  });
}

Future<AppState> _loggedIn() async {
  final state = AppState();
  await state.load();
  await state.saveSession('tok', const AuthUser(userId: '1', nickname: '读者'));
  return state;
}

Widget _app(_Harness h, AppState state) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<RouteManager>.value(value: h.routes),
      Provider<Repository>.value(value: h.repo(state)),
      ChangeNotifierProvider<DownloadManager>(
        create: (_) => DownloadManager(
          repo: h.repo(state),
          store: DownloadStore(root: Directory.systemTemp),
        ),
      ),
      ChangeNotifierProvider<ShelfService>(
        create: (_) => ShelfService(repo: h.repo(state), state: state),
      ),
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
      home: const Scaffold(body: LibraryScreen()),
    ),
  );
}

/// 内容详情页（轻小说 / 动画 / 写真）的收藏按钮。
Widget _contentApp(_Harness h, AppState state) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<RouteManager>.value(value: h.routes),
      Provider<Repository>.value(value: h.repo(state)),
      ChangeNotifierProvider<ShelfService>(
        create: (_) => ShelfService(repo: h.repo(state), state: state),
      ),
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
      home: const ContentDetailScreen(
        kind: MediaKind.novel,
        pathWord: 'novel-pw',
      ),
    ),
  );
}

class _Call {
  final String method;
  final String path;
  final Map<String, dynamic> body;

  /// 是否为 `application/x-www-form-urlencoded` 请求（收藏写接口必须是）。
  final bool form;
  _Call(this.method, this.path, this.body, {this.form = false});
}

/// 一律不缓存，避开 `flutter test` 里 dart:io 的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  final List<_Call> requests = [];
  final RouteManager routes = RouteManager()..autoFallback = false;

  /// 第 N 次收藏写请求开始失败（用于「同步中途失败」）。
  final int? failAfter;

  /// 收藏接口直接返回 `success:false`（业务失败，HTTP 仍 200）。
  final bool failCollect;

  /// `/comic2/{path_word}` 返回的 `is_collect`。
  final bool detailIsCollect;

  /// 三类详情接口返回的收藏状态。null = 该接口不返回这个字段（线上实测
  /// 轻小说 / 写真就是这种），用来验证「登录态回落到账号收藏列表」。
  final bool? bookCollect;
  final bool? cartoonCollect;
  final bool? postCollect;

  /// 账号收藏列表（GET `/member/collect/{…}`）里的条目，按路径给。
  final Map<String, List<Map<String, dynamic>>> collectByPath;

  _Harness({
    this.failAfter,
    this.failCollect = false,
    this.detailIsCollect = false,
    this.bookCollect,
    this.cartoonCollect,
    this.postCollect,
    this.collectByPath = const {},
  });

  Repository repo(AppState state) {
    final client = MockClient((request) async {
      final path = request.url.path;
      final contentType = request.headers['content-type'] ?? '';
      Map<String, dynamic> body = const {};
      final isForm = contentType.contains('application/x-www-form-urlencoded');
      if (request.body.isNotEmpty) {
        if (isForm) {
          // form 请求的正文靠 Uri.splitQueryString 解，别按 JSON 解（会静默变成空 map）。
          body = Uri.splitQueryString(request.body);
        } else {
          try {
            final decoded = jsonDecode(request.body);
            if (decoded is Map) body = Map<String, dynamic>.from(decoded);
          } catch (_) {}
        }
      }
      requests.add(_Call(request.method, path, body, form: isForm));

      if (request.method == 'POST' &&
          path.startsWith('/api/v3/member/collect')) {
        if (failCollect) {
          return _json({
            'code': 200,
            'message': 'ok',
            'results': {
              'success': false,
              'error': '收藏失败',
            }
          });
        }
        final index = requests
            .where((r) =>
                r.method == 'POST' &&
                r.path.startsWith('/api/v3/member/collect'))
            .length;
        if (failAfter != null && index > failAfter!) {
          return _json({'code': 500, 'message': 'boom', 'results': null});
        }
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {'success': true}
        });
      }
      if (request.method == 'GET' &&
          path.startsWith('/api/v3/member/collect/')) {
        final items = collectByPath[path] ?? const <Map<String, dynamic>>[];
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'list': items,
            'total': items.length,
            'limit': 100,
            'offset': 0,
          }
        });
      }
      if (path.startsWith('/api/v3/comic2/')) {
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'comic': {
              'uuid': 'uuid-1',
              'path_word': 'yuekanshaonv',
              'name': '月刊少女野崎君',
              'cover': '',
              'author': <dynamic>[],
              'theme': <dynamic>[],
              'status': 'ongoing',
              'region': 'jp',
              'popular': 1,
              'datetime_updated': '2026-11-10 10:00:00',
              'last_chapter': '第 115 话',
              'brief': '',
            },
            'groups': {
              'default': {'path_word': 'default', 'count': 1, 'name': '默認'},
            },
            'is_collect': detailIsCollect,
          },
        });
      }
      if (path.startsWith('/api/v3/book/')) {
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'book': {
              'uuid': 'book-uuid',
              'path_word': 'novel-pw',
              'name': '轻小说 A',
              'cover': 'https://s3.example.com/book.jpg',
              'author': <dynamic>[],
              'brief': '',
              'datetime_updated': '2026-11-10',
            },
            if (bookCollect != null) 'is_collect': bookCollect,
          },
        });
      }
      if (path.startsWith('/api/v3/cartoon/')) {
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'cartoon': {
              'uuid': 'cartoon-uuid',
              'path_word': 'cartoon-pw',
              'name': '动画 A',
              'cover': '',
              'brief': '',
              'datetime_updated': '2026-11-10',
            },
            'collect': cartoonCollect == true
                ? {'datetime_created': '2026-11-10'}
                : null,
          },
        });
      }
      if (path.startsWith('/api/v3/post/')) {
        return _json({
          'code': 200,
          'message': 'ok',
          'results': {
            'post': {
              'uuid': 'post-uuid',
              'name': '写真 A',
              'cover': '',
              'brief': '',
              'datetime_updated': '2026-11-10',
              'mannequins': <dynamic>[],
            },
            if (postCollect != null) 'is_collect': postCollect,
          },
        });
      }
      // 其它接口（书架列表等）：合法空信封。
      return _json({
        'code': 200,
        'message': 'ok',
        'results': {'list': <dynamic>[], 'total': 0, 'limit': 21, 'offset': 0},
      });
    });
    return Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
}
