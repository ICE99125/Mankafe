import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/models/chapter.dart';
import 'package:mankafe/models/download.dart';
import 'package:mankafe/screens/downloads_screen.dart';
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

/// 离线下载回归。
///
/// 表结构对齐 base.apk 逆向出的 `download_comic` / `download_chapter`：
/// 官方用 sqflite，这里换成 `index.json` + 每话一个图片目录，语义一致。
/// 重点覆盖三件容易退化的事：索引能落盘重读、断点续传不重复下载、
/// 删除会把图片和索引一起清掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempRoot = await Directory.systemTemp.createTemp('manga_dl_test');
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('下载一话：图片落盘 + 索引可重读', () async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await manager.init();

    manager.downloadChapter(
      comicId: 'uuid-1',
      comicPathWord: 'pw',
      comicName: '测试漫画',
      chapter: const Chapter(uuid: 'ch1', name: '第 1 话', index: 0),
    );
    await _waitDone(manager, 'ch1');

    expect(manager.isDownloaded('ch1'), isTrue);
    expect(manager.taskOf('ch1')!.status, DownloadStatus.done);
    expect(h.fetched.length, 3, reason: '3 张图应各下载一次');

    final file = manager.localFile('ch1', 0);
    expect(file, isNotNull);
    expect(await file!.exists(), isTrue);

    // 换一个 manager 重新 init，模拟重启后从索引恢复。
    final reopened = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await reopened.init();
    expect(reopened.isDownloaded('ch1'), isTrue);
    final entry = reopened.chapterOf('ch1')!;
    expect(entry.files.length, 3);
    expect(entry.imageCount, 3);
    expect(entry.comicName, '测试漫画');
    expect(entry.bytes, greaterThan(0));
  });

  test('断点续传：已存在的页不再重新下载', () async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await manager.init();
    manager.downloadChapter(
      comicId: 'uuid-1',
      comicPathWord: 'pw',
      comicName: '测试漫画',
      chapter: const Chapter(uuid: 'ch1', name: '第 1 话', index: 0),
    );
    await _waitDone(manager, 'ch1');
    expect(h.fetched.length, 3);

    // 删掉索引和其中一页，再下一次：只补缺的那一页。
    await File('${tempRoot.path}/downloads/index.json').delete();
    final dir = Directory('${tempRoot.path}/downloads/pw/ch1');
    await File('${dir.path}/001.jpg').delete();
    h.fetched.clear();

    final again = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await again.init();
    expect(again.isDownloaded('ch1'), isFalse, reason: '索引已删，视为未下载');
    again.downloadChapter(
      comicId: 'uuid-1',
      comicPathWord: 'pw',
      comicName: '测试漫画',
      chapter: const Chapter(uuid: 'ch1', name: '第 1 话', index: 0),
    );
    await _waitDone(again, 'ch1');

    expect(h.fetched.length, 1, reason: '只剩 001 需要补下');
    expect(again.chapterOf('ch1')!.files.length, 3);
  });

  test('删除一话：图片目录与索引一起清掉', () async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await manager.init();
    manager.downloadChapter(
      comicId: 'uuid-1',
      comicPathWord: 'pw',
      comicName: '测试漫画',
      chapter: const Chapter(uuid: 'ch1', name: '第 1 话', index: 0),
    );
    await _waitDone(manager, 'ch1');

    await manager.deleteChapter('ch1');
    expect(manager.isDownloaded('ch1'), isFalse);
    expect(
        await Directory('${tempRoot.path}/downloads/pw/ch1').exists(), isFalse);

    final reloaded = DownloadStore(root: tempRoot);
    expect(await reloaded.loadIndex(), isEmpty);
  });

  test('按漫画聚合：同作品多话归到一组并按章节序排列', () async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await manager.init();
    for (final (uuid, index) in [('ch2', 1), ('ch1', 0)]) {
      manager.downloadChapter(
        comicId: 'uuid-1',
        comicPathWord: 'pw',
        comicName: '测试漫画',
        chapter: Chapter(uuid: uuid, name: '第 ${index + 1} 话', index: index),
      );
      await _waitDone(manager, uuid);
    }

    final comics = manager.comics();
    expect(comics.length, 1);
    expect(comics.first.chapterCount, 2);
    expect(comics.first.chapters.first.chapterId, 'ch1',
        reason: '按 sort 升序，不按下载顺序');
    expect(comics.first.bytes, greaterThan(0));
  });

  test('体积格式化', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536 * 1024), '1.5 MB');
  });

  testWidgets('我的下载页：空态给出引导文案', (tester) async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    // testWidgets 默认在 FakeAsync 里跑，真实文件 IO 的 Future 不会结算，
    // 必须放进 runAsync 才能真正等待落盘完成。
    await tester.runAsync(manager.init);
    await _pumpDownloads(tester, h, manager);

    expect(find.text('还没有下载任何章节'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的下载页：已下载的漫画与章节都会列出来', (tester) async {
    final h = _Harness(tempRoot);
    final manager = DownloadManager(
      repo: h.repo,
      store: DownloadStore(root: tempRoot),
      fetchBytes: h.fetch,
    );
    await tester.runAsync(() async {
      await manager.init();
      manager.downloadChapter(
        comicId: 'uuid-1',
        comicPathWord: 'pw',
        comicName: '测试漫画',
        chapter: const Chapter(uuid: 'ch1', name: '第 1 话', index: 0),
      );
      await _waitDone(manager, 'ch1');
    });
    await _pumpDownloads(tester, h, manager);

    expect(find.text('测试漫画'), findsOneWidget);
    expect(find.text('第 1 话'), findsOneWidget);
    expect(find.textContaining('已下载 1 话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitDone(DownloadManager manager, String chapterId) async {
  for (var i = 0; i < 400; i++) {
    final task = manager.taskOf(chapterId);
    if (task != null &&
        (task.status == DownloadStatus.done ||
            task.status == DownloadStatus.failed ||
            task.status == DownloadStatus.canceled)) {
      if (task.status == DownloadStatus.failed) {
        fail('下载失败: ${task.error}');
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('下载超时: $chapterId');
}

class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  /// 记录被下载的图片 URL，用于验证断点续传没有重复打图床。
  final List<String> fetched = [];

  _Harness(Directory root) {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      if (request.url.path.contains('/chapter2/')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'message': 'ok',
            'results': {
              'chapter': {
                'contents': [
                  for (var i = 0; i < 3; i++)
                    {
                      'url': 'https://img.test/$i.jpg',
                      'width': 800,
                      'height': 1200,
                    },
                ],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({'code': 200, 'message': 'ok', 'results': {}}),
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

  Future<Uint8List> fetch(String url) async {
    fetched.add(url);
    // 用 URL 里的序号造不同长度的假字节，便于验证字节数累加。
    return Uint8List.fromList(List<int>.filled(100 + url.hashCode % 50, 7));
  }
}

Future<void> _pumpDownloads(
  WidgetTester tester,
  _Harness h,
  DownloadManager manager,
) async {
  tester.view.physicalSize = const Size(420, 1200);
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
      ChangeNotifierProvider<DownloadManager>.value(value: manager),
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
      home: const DownloadsScreen(),
    ),
  ));
  await tester.pump();
}
