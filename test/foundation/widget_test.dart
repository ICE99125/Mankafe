import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mankafe/models/chapter.dart';
import 'package:mankafe/models/comic.dart';
import 'package:mankafe/models/content.dart';
import 'package:mankafe/models/home_index.dart';
import 'package:mankafe/models/link.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/api_endpoints.dart';
import 'package:mankafe/services/proxy_config.dart';
import 'package:mankafe/screens/content_reader_screen.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:mankafe/utils/chapter_paging.dart';
import 'package:mankafe/widgets/browse_widgets.dart';
import 'package:mankafe/widgets/brand_header.dart';
import 'package:mankafe/widgets/detail_hero.dart';
import 'package:mankafe/widgets/net_image.dart';
import 'package:mankafe/widgets/paged_image_reader.dart';
import 'package:mankafe/widgets/request_error.dart';
import 'package:mankafe/widgets/skeleton.dart';
import 'package:mankafe/widgets/ui.dart';

/// 复刻首页「TabBar 只画指示器 + IndexedStack 切页」结构的最小样例，
/// 用于回归 AppShell 的 TickerMode 切换后不再出现 element 失活断言。
class _StableTabs extends StatefulWidget {
  const _StableTabs({required this.ready});

  final bool ready;

  @override
  State<_StableTabs> createState() => _StableTabsState();
}

class _StableTabsState extends State<_StableTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    animationDuration: Duration.zero,
  );
  int _index = 0;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _onTap(int i) => setState(() {
        _index = i;
        _tabs.index = i;
      });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          onTap: _onTap,
          tabs: const [Tab(text: 'a'), Tab(text: 'b')],
        ),
        Expanded(
          child: IndexedStack(
            index: _index,
            sizing: StackFit.expand,
            children: [
              Center(child: Text(widget.ready ? 'data' : 'skeleton')),
              const Center(child: Text('second')),
            ],
          ),
        ),
      ],
    );
  }
}

/// 不依赖平台通道的冒烟测试：验证 MD3 语义色在亮 / 暗主题下都能生成。
/// 启动链路自检、SharedPreferences 等需要真实设备/模拟器的部分，
/// 请在 Android Studio 里用 `flutter run` 验证。
void main() {
  _chapterGridTests();
  _chapterPagingTests();
  _netImageTests();
  _noSplashTests();
  testWidgets('顶层 Tab 用 IndexedStack：骨架→数据不重建容器、不抛断言', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _StableTabs(ready: false))),
    );
    final stackBefore = tester.element(find.byType(IndexedStack));

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _StableTabs(ready: true))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('data'), findsOneWidget);
    expect(tester.element(find.byType(IndexedStack)), same(stackBefore));
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('顶层 Tab 用 IndexedStack：切页与数据切换叠加不抛断言', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _StableTabs(ready: false))),
    );
    await tester.tap(find.text('b'));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _StableTabs(ready: true))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(IndexedStack), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('data'), findsOneWidget);
  });

  test('工程内不再使用分页视图：避免 PageController 失活断言', () {
    // AppShell 用 IndexedStack + TickerMode 常驻六个页面，内层再套
    // TabBarView 时，切回页面补 tick 会让 _TabBarViewState 操作已失活的
    // IgnorePointer element，抛出后整棵渲染树被破坏（白屏 + 连锁红屏）。
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.readAsStringSync().contains('TabBarView(')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });

  testWidgets('小说内容页加载：转圈，不用整屏骨架', (tester) async {
    // 「内容页」= 点进某一卷看正文的第一卷页，用户要求来个 loading。
    // 「进入页」= 轻小说详情（封面 + 简介 + 题材），那里是骨架屏，
    // 见 ContentDetailSkeleton 的用例；两者别搞反。
    // 漫画 / 写真的整页阅读器是另一条路径，不受影响（整屏骨架色）。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ContentReaderLoading()),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(SkeletonBox), findsNothing);
    expect(find.byType(Shimmer), findsNothing);
  });

  testWidgets('写真章节加载：整屏一块骨架色，不再按图片页铺占位', (tester) async {
    // 写真改成和漫画同一套整页翻页后，加载态也统一成「整屏一块」：
    // 按页铺七八个占位块，数据一到整屏一起跳，而且分页视图里也塞不进占位列表。
    await _pumpSkeleton(tester, const ReaderLoadingView());
    expect(tester.takeException(), isNull);

    final box = find.byType(SkeletonBox);
    expect(box, findsOneWidget, reason: '整屏只能有一块占位，不能按页铺');
    expect(tester.getRect(box), const Rect.fromLTWH(0, 0, 400, 2400),
        reason: '占位要铺满整个可用区域');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ListView), findsNothing, reason: '整页阅读器不是滚动列表');
  });

  testWidgets('小说正文：前面不再铺一大片分节 Chip', (tester) async {
    // 原实现把 volume.sections（序章 / 间章 / 十几个「插图」）全铺成 Chip，
    // 正文被挤到第二屏之后。现在进卷直接渲染段落。
    const volume = NovelVolume(
      name: '第一卷',
      txtAddr: '',
      encoding: 'gbk',
      sections: [
        NovelSection(name: '序章'),
        NovelSection(name: '插图'),
        NovelSection(name: '插图'),
        NovelSection(name: '插图'),
      ],
      text: '第一卷 序章\n\n台版 转自 天使动漫论坛\n\n轻书架×天使动漫录入组',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NovelParagraphs(paragraphs: volume.paragraphs)),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(Chip), findsNothing, reason: '卷内分节不该再占正文前面一整屏');
    expect(
        find.byType(SelectableText), findsNWidgets(volume.paragraphs.length));
    expect(find.textContaining('第一卷 序章'), findsOneWidget);
  });

  test('MD3 主题与种子色可正常生成', () {
    expect(AppTheme.seedPresets, isNotEmpty);

    final seed = AppTheme.seedOf(0);
    final light = AppTheme.light(seed);
    final dark = AppTheme.dark(seed);

    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(light.colorScheme.primary, isA<Color>());
    expect(dark.colorScheme.primary, isNot(equals(Colors.transparent)));
  });

  test('apiHeaders 发出的请求带 dart:io 自动生成的 Host（含端口）', () async {
    // flutter_test 默认拦截所有 HttpClient（返回 400），这里恢复真实实现。
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    Map<String, String>? seen;
    server.listen((req) async {
      final captured = <String, String>{};
      req.headers.forEach((name, values) => captured[name] = values.join(','));
      seen = captured;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{}');
      await req.response.close();
    });

    final uri =
        Uri.parse('http://127.0.0.1:${server.port}/api/v3/books?platform=3');
    // 与 ApiClient 相同的调用方式：package:http + apiHeaders。
    final response = await http.get(uri, headers: apiHeaders());
    expect(response.statusCode, 200);

    // dart:io 会按 URL 隐式写入 Host，值包含端口；应用层无需也不应硬编码。
    expect(seen!['host'], '127.0.0.1:${server.port}');
    expect(seen!['platform'], '3');
    expect(seen!['accept'], 'application/json');
    // 官方 GET 也带 content-type: application/x-www-form-urlencoded。
    expect(seen!['content-type'], 'application/x-www-form-urlencoded');
    // 完整请求头（用于人工核对，flutter test 输出里可见）。
    final dump = seen!.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    // ignore: avoid_print
    print('[captured request headers]\n$dump');
  });

  test('content-type 默认 form-urlencoded，POST JSON / multipart 各自覆盖', () {
    expect(apiHeaders()['content-type'], 'application/x-www-form-urlencoded');

    final uri = Uri.parse('http://127.0.0.1/api');

    // POST JSON：ApiClient 用 application/json 覆盖。
    final jsonHeaders = apiHeaders()..['content-type'] = 'application/json';
    expect(jsonHeaders['content-type'], 'application/json');

    // 表单：与默认值一致，包内不会抛 StateError。
    final form = http.Request('POST', uri)..headers.addAll(apiHeaders());
    form.bodyFields = {'a': 'b'};
    expect(form.headers['content-type'], 'application/x-www-form-urlencoded');

    // multipart：由 MultipartRequest 自己写入带 boundary 的类型。
    final multipart = http.MultipartRequest('POST', uri)
      ..headers.addAll(apiHeaders())
      ..files.add(http.MultipartFile.fromBytes('file', const [1, 2],
          filename: 'x.bin'));
    multipart.finalize();
    expect(multipart.headers['content-type'],
        startsWith('multipart/form-data; boundary='));
  });

  test('network2 下发字段：列表套列表要摊平成主机，不能 toString 出 [[host]]', () {
    // 真实响应（2026-11 实测）里 api / share 都是列表，api 还是列表套列表。
    final info = Network2Info.fromJson(const {
      'static': 's3.mangafunb.fun',
      'share': ['www.copy5000.com'],
      'api': [
        ['mapi.copy-manga.com'],
        ['mapi.copy-manga.com'],
      ],
      'in_mainland': true,
    });

    expect(info.api, 'mapi.copy-manga.com');
    expect(info.api, isNot(contains('[')));
    expect(info.cdn, 's3.mangafunb.fun');
    expect(info.marketing, 'www.copy5000.com');
    // 响应里没有 api_list 字段时，列表应为空而不是残留字段名。
    expect(info.apiList, isEmpty);
  });

  test('homeIndex2 解析：裸数组 / {list} 两种容器，坏条目只丢自己', () {
    final index = HomeIndex.fromJson(const {
      'banners': [
        {
          'cover': 'https://x/1.jpg',
          'brief': '轮播',
          'comic': {'name': 'A'}
        },
        'not-a-map',
      ],
      'topics': {
        'list': [
          {'title': 'T', 'cover': 'https://x/t.jpg'},
        ],
      },
      'recComics': {
        'list': [
          {'path_word': 'abc', 'name': '#1'},
          42,
        ],
      },
      'hotComics': [
        {'path_word': 'def', 'name': '#2'},
      ],
      'rankDayComics': {'list': []},
    });

    expect(index.banners, hasLength(1));
    expect(index.banners.single.title, '轮播');
    expect(index.topics, hasLength(1));
    expect(index.recommend.map((c) => c.pathWord), ['abc']);
    expect(index.hot.single.pathWord, 'def');
    expect(index.rankDay, isEmpty);
    // 响应里缺失的区块按空列表处理，不抛异常。
    expect(index.rankMonth, isEmpty);
  });

  test('homeIndex2 回归：{list} 包裹的区块必须产出 List<Comic>，不能退化成 List<dynamic>', () {
    // 旧实现里 `node is List ? node : node['list']` 的 dynamic 分支会让整条
    // 表达式变成动态调用，`_items` 返回时抛
    // `type 'List<dynamic>' is not a subtype of type 'List<Map<String, dynamic>>'`。
    // 这条用例用每个区块都走 `{list: [...]}` 的形态复现该路径。
    final index = HomeIndex.fromJson(const {
      'banners': {
        'list': [
          {'cover': 'https://x/1.jpg', 'brief': '轮播'},
        ],
      },
      'recComics': {
        'list': [
          {'path_word': 'a', 'name': 'A'},
        ],
      },
      'hotComics': {
        'list': [
          {'path_word': 'b', 'name': 'B'},
        ],
      },
      'newComics': {'list': <dynamic>[]},
      'rankWeekComics': {
        'list': [
          {'path_word': 'c', 'name': 'C'},
        ],
      },
    });

    expect(index.banners, isA<List<HomeBanner>>());
    expect(index.recommend, isA<List<Comic>>());
    expect(index.hot, isA<List<Comic>>());
    expect(index.newest, isA<List<Comic>>());
    expect(index.recommend.single.pathWord, 'a');
    expect(index.hot.single.pathWord, 'b');
    expect(index.rankWeek.single.pathWord, 'c');
  });

  test('homeIndex2 解析：finishComics 与 topicsFrom 对坏条目 / 非列表容错', () {
    final index = HomeIndex.fromJson(const {
      'finishComics': {
        'list': [
          {'path_word': 'f1', 'name': '已完结 1'},
          'bad',
          null,
          {'name': '缺 path_word'},
        ],
      },
    });
    expect(index.finish.map((c) => c.pathWord), ['f1']);

    final topics = HomeIndex.topicsFrom(const {
      'list': [
        {'title': '专题 A', 'cover': 'https://x/a.jpg', 'period': '第 1 期'},
        'bad',
        {'title': '无封面'},
      ],
    });
    expect(topics, hasLength(1));
    expect(topics.single.title, '专题 A');
    expect(topics.single.period, '第 1 期');

    expect(HomeIndex.topicsFrom(null), isEmpty);
    expect(HomeIndex.topicsFrom(const {'list': 'nope'}), isEmpty);
  });

  test('mediaPage 解析：{list} 包裹 / 坏条目 / 缺字段 / 非对象响应都不抛异常', () {
    final page = MediaPage.fromResults(
      MediaKind.comic,
      {
        'list': [
          {
            'comic': {'path_word': 'a', 'name': 'A'},
          },
          {'path_word': 'b'},
          'bad-entry',
          null,
          42,
          {'comic': null, 'name': '外层名字'},
        ],
        'total': 3,
        'limit': 21,
      },
      offset: 21,
    );
    // 非对象条目被丢弃，缺 path_word 的条目也不进列表。
    expect(page.items.map((c) => c.pathWord), ['a', 'b']);
    expect(page.total, 3);
    expect(page.limit, 21);
    expect(page.hasMore, isFalse);

    // 响应不是对象 / list 不是数组：返回空页而不是抛异常。
    final empty = MediaPage.fromResults(MediaKind.novel, null, offset: 0);
    expect(empty.items, isEmpty);
    expect(empty.total, 0);
    expect(empty.hasMore, isFalse);

    final badList = MediaPage.fromResults(
      MediaKind.novel,
      {'list': 'nope'},
      offset: 0,
    );
    expect(badList.items, isEmpty);
    expect(badList.limit, 21);
  });

  test('RecommendGroup 解析：comics 缺失 / 坏条目只丢自己', () {
    final empty = RecommendGroup.fromJson(const {'title': '专题'});
    expect(empty.title, '专题');
    expect(empty.comics, isEmpty);

    final group = RecommendGroup.fromJson(const {
      'title': '分组',
      'type': 'not-int',
      'comics': [
        {'path_word': 'a', 'name': 'A'},
        'bad',
        null,
      ],
    });
    expect(group.type, 1);
    expect(group.comics.map((c) => c.pathWord), ['a']);
  });

  test('chapterContent 解析：缺 chapter / images 含坏条目都不抛异常', () {
    final empty = ChapterContent.fromJson(const {});
    expect(empty.chapterUuid, '');
    expect(empty.name, '章节');
    expect(empty.images, isEmpty);
    expect(empty.next, isNull);

    final content = ChapterContent.fromJson(const {
      'chapter': {'uuid': 'u1', 'name': '第 1 话'},
      'images': [
        {'url': 'https://x/1.jpg', 'width': 800, 'height': 1200},
        'bad',
        null,
        <String, dynamic>{},
      ],
    });
    expect(content.chapterUuid, 'u1');
    expect(content.name, '第 1 话');
    expect(content.images, hasLength(2));
    expect(content.images.first.index, 0);
    // 缺字段的图片用默认尺寸兜底，不抛异常。
    expect(content.images.last.width, 800);
  });

  test('代理失败判定：地址指向代理 / 握手失败才算代理问题', () {
    const host = '10.0.2.2';
    const port = 9000;

    // 连不上代理端口：SocketException 的地址就是代理。
    final refused = SocketException(
      'Connection refused',
      address: InternetAddress(host),
      port: port,
      osError: const OSError('Connection refused', 111),
    );
    expect(ProxyConfig.isProxyFailure(refused, host: host, port: port), isTrue);

    // 地址是别的主机（例如命中忽略名单直连目标）时，不能归因代理。
    final other = SocketException(
      'Connection refused',
      address: InternetAddress('127.0.0.1'),
      port: 443,
    );
    expect(ProxyConfig.isProxyFailure(other, host: host, port: port), isFalse);

    // 代理拦截 HTTPS 导致的证书 / TLS 失败。
    expect(
      ProxyConfig.isProxyFailure(const HandshakeException('certificate'),
          host: host, port: port),
      isTrue,
    );
  });

  testWidgets('错误态按来源区分：代理失败给入口，线路失败只给重试', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RequestErrorState(
          error: const ProxyUnavailableException('10.0.2.2:9000', 'refused'),
          onRetry: () {},
        ),
      ),
    ));
    expect(find.text('Proxy unavailable'), findsOneWidget);
    expect(find.text('Proxy settings'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RequestErrorState(
          error: const LinkUnreachableException('timeout'),
          onRetry: () {},
        ),
      ),
    ));
    expect(find.text('Route unavailable'), findsOneWidget);
    expect(find.text('Proxy settings'), findsNothing);

    // 业务错误原样透出服务端 message。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RequestErrorState(
          error: const ApiException('账号或密码错误', code: 1024),
          onRetry: () {},
        ),
      ),
    ));
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(find.text('Proxy settings'), findsNothing);
  });

  test('代理配置：JSON / 旧格式解析、忽略列表、缺主机端口不可用', () {
    final json = ProxyConfig.encode(const ProxySettings(
      host: '10.0.2.2',
      port: 9000,
      username: 'u',
      password: 'p',
      bypass: 'localhost,*.internal',
    ));
    final decoded = ProxyConfig.decode(json)!;
    expect(decoded.host, '10.0.2.2');
    expect(decoded.port, 9000);
    expect(decoded.username, 'u');
    expect(decoded.password, 'p');
    expect(decoded.usable, isTrue);

    // 旧版本存的纯文本 host:port 仍然可读。
    final legacy = ProxyConfig.decode('10.0.2.2:9000')!;
    expect(legacy.host, '10.0.2.2');
    expect(legacy.port, 9000);
    expect(ProxyConfig.decode(''), isNull);

    // HTTP / SOCKS5 都是真实现，都算「可用」；缺主机或端口才算不可用。
    expect(
        const ProxySettings(type: ProxyType.socks5, host: 'h', port: 1).usable,
        isTrue);
    expect(
        const ProxySettings(type: ProxyType.http, host: 'h').usable, isFalse);
    expect(
        const ProxySettings(type: ProxyType.socks5, host: '', port: 1080)
            .usable,
        isFalse);

    expect(ProxyConfig.bypasses('localhost', 'localhost,127.0.0.1'), isTrue);
    expect(ProxyConfig.bypasses('api.internal', '*.internal'), isTrue);
    expect(ProxyConfig.bypasses('svc.corp', '.corp'), isTrue);
    expect(ProxyConfig.bypasses('api.example.com', 'localhost'), isFalse);
  });

  test('代理探测能区分连不上 / 认证失败 / 非 HTTP 代理', () async {
    // 先占一个端口再释放，确保连接被拒绝。
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final unreachable = await ProxyConfig.probe(
        ProxySettings(host: '127.0.0.1', port: closedPort));
    expect(unreachable.status, ProxyProbeStatus.unreachable);

    Future<ProxyProbeResult> probeAgainst(String reply) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      server.listen((socket) {
        socket.listen((_) => socket.write(reply), onError: (_) {});
      });
      return ProxyConfig.probe(
          ProxySettings(host: '127.0.0.1', port: server.port));
    }

    final ok =
        await probeAgainst('HTTP/1.1 200 Connection established\r\n\r\n');
    expect(ok.status, ProxyProbeStatus.ok);

    final auth = await probeAgainst(
        'HTTP/1.1 407 Proxy Authentication Required\r\n\r\n');
    expect(auth.status, ProxyProbeStatus.authFailed);

    final garbage = await probeAgainst('SSH-2.0-OpenSSH_9.0\r\n');
    expect(garbage.status, ProxyProbeStatus.protocolError);
  });

  testWidgets('三列网格卡片等高、封面 3:4 等大、标题起点对齐', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    const titles = [
      '短标题',
      '这是一个会占满两行的作品标题用来验证错位',
      '中等长度标题',
    ];

    await tester.pumpWidget(_gridApp(titles));
    await tester.pumpAndSettle();

    final cards = find.byType(RichGridCard);
    expect(cards, findsNWidgets(3));

    final cardRects = <Rect>[];
    final coverRects = <Rect>[];
    final titleTops = <double>[];
    for (var i = 0; i < 3; i++) {
      final card = cards.at(i);
      final cardBox = tester.renderObject<RenderBox>(card);
      cardRects.add(cardBox.localToGlobal(Offset.zero) & cardBox.size);

      final cover =
          find.descendant(of: card, matching: find.byType(AspectRatio));
      final coverBox = tester.renderObject<RenderBox>(cover.first);
      coverRects.add(coverBox.localToGlobal(Offset.zero) & coverBox.size);
      expect(coverBox.size.width / coverBox.size.height, closeTo(0.75, 0.001),
          reason: '封面必须是 3:4');

      titleTops.add(tester.getTopLeft(find.text(titles[i])).dy);
    }

    for (var i = 1; i < 3; i++) {
      expect(cardRects[i].width, closeTo(cardRects[0].width, 0.01));
      expect(cardRects[i].height, closeTo(cardRects[0].height, 0.01),
          reason: '卡片高度必须一致');
      expect(cardRects[i].top, closeTo(cardRects[0].top, 0.01));
      expect(coverRects[i].width, closeTo(coverRects[0].width, 0.01));
      expect(coverRects[i].height, closeTo(coverRects[0].height, 0.01),
          reason: '封面尺寸必须一致');
      expect(coverRects[i].top, closeTo(coverRects[0].top, 0.01));
      expect(titleTops[i], closeTo(titleTops[0], 0.01), reason: '标题导致下方元素错位');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('网格骨架与真实卡片尺寸一致（加载完不跳动）', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_gridApp(const ['短标题', '两行标题的示例作品', '标题']));
    await tester.pumpAndSettle();
    final cardHeight = tester
        .renderObject<RenderBox>(find.byType(RichGridCard).first)
        .size
        .height;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CustomScrollView(slivers: [MediaGridSkeleton()])),
    ));
    // 骨架带无限循环的呼吸动画，不能 pumpAndSettle，只推进一帧完成布局。
    await tester.pump();
    final skeletonColumn = find.ancestor(
      of: find.byType(AspectRatio).first,
      matching: find.byType(Column),
    );
    final skeletonHeight =
        tester.renderObject<RenderBox>(skeletonColumn.first).size.height;

    expect(skeletonHeight, closeTo(cardHeight, 0.5), reason: '骨架卡与真实卡必须等高');
  });

  testWidgets('MoreActions：两个并排大按钮，换一批加载中禁用并显示进度圈', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var moreTaps = 0;
    var shuffleTaps = 0;
    Widget build({bool shuffling = false}) => MaterialApp(
          theme: AppTheme.light(AppTheme.seedOf(0)),
          home: Scaffold(
            body: MoreActions(
              moreLabel: '更多',
              onMore: () => moreTaps++,
              shuffleLabel: '换一批',
              onShuffle: () => shuffleTaps++,
              shuffling: shuffling,
            ),
          ),
        );

    await tester.pumpWidget(build());
    final moreRect = tester.getRect(find.widgetWithText(OutlinedButton, '更多'));
    final shuffleRect =
        tester.getRect(find.widgetWithText(OutlinedButton, '换一批'));

    // 并排、等宽、等高（参考图里的两个大按钮）。
    expect(moreRect.top, closeTo(shuffleRect.top, 0.01));
    expect(moreRect.width, closeTo(shuffleRect.width, 0.01));
    expect(moreRect.height, closeTo(46, 0.01));
    expect(moreRect.height, closeTo(shuffleRect.height, 0.01));
    expect(shuffleRect.left, greaterThan(moreRect.right));

    await tester.tap(find.text('更多'));
    await tester.tap(find.text('换一批'));
    expect(moreTaps, 1);
    expect(shuffleTaps, 1);

    // 请求中：按钮禁用 + 有进度圈。
    await tester.pumpWidget(build(shuffling: true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('换一批'), warnIfMissed: false);
    expect(shuffleTaps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('BrandBar：传了 leading 就必须真渲染返回键，标题让出按钮位', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(AppTheme.seedOf(0)),
      home: Scaffold(
        body: BrandBar(
          leading: BrandBackButton(onPressed: () {}),
          title: const BrandTitle(name: '2026年10月秋季新番動畫'),
        ),
      ),
    ));

    // 曾经的 bug：BrandBar 收了 leading 却从不渲染，专题内容页 / 聚合页
    // 因此完全没有任何返回入口，只能靠系统手势退出。
    expect(find.byType(BrandBackButton), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);

    final back = tester.getRect(find.byType(BrandBackButton));
    final title = tester.getRect(find.text('2026年10月秋季新番動畫'));
    // MD3 的返回键是 48dp 热区（24dp 图标居中），左内距 4dp，
    // 图标左边缘落在 16dp 栅格上；标题必须整体在按钮右侧，不能被图标压住。
    expect(back.left, lessThanOrEqualTo(6));
    expect(back.width, 48);
    expect(title.left, greaterThanOrEqualTo(back.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TopicStrip：空数据时整块不渲染（不留空白占位）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TopicStrip(slides: [])),
    ));
    expect(tester.getSize(find.byType(TopicStrip)).height, 0);
    expect(find.byType(ClipRRect), findsNothing);
  });

  testWidgets('TopicStrip：卡片宽约屏宽 60%、2.5:1、底部单行黑条标题', (tester) async {
    const screenWidth = 400.0;
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: screenWidth,
          child: TopicStrip(slides: [
            TopicSlide(title: '夏番漫畫2026 必看熱門漫畫推薦第41期'),
            TopicSlide(title: '春番漫畫2026'),
          ]),
        ),
      ),
    ));

    final first = tester.getRect(find.byType(InkWell).first);
    final second = tester.getRect(find.byType(InkWell).last);
    // 一屏一张整卡 + 下一张露出预览（与原版一致）。
    expect(first.width, closeTo(screenWidth * 0.6, 0.5));
    expect(first.height, closeTo(first.width / 2.5, 0.5));
    expect(second.left - first.right, closeTo(12, 0.5));
    expect(second.left, lessThan(screenWidth));
    expect(second.left, greaterThan(first.right));

    final label = tester.widget<Text>(find.text('夏番漫畫2026 必看熱門漫畫推薦第41期'));
    expect(label.maxLines, 1);
    expect(label.style?.color, Colors.white);
  });

  test('ChapterContent：真实结构把图片放在 chapter.contents', () {
    // 旧实现只读顶层 results.images，导致阅读器 1 页占位；这里复现旧 bug。
    final content = ChapterContent.fromJson({
      'chapter': {
        'uuid': 'ch-1',
        'name': '第01話',
        'prev': '',
        'next': 'ch-2',
        'contents': [
          {'url': 'https://img/1.jpg', 'width': 800, 'height': 1200},
          {'url': 'https://img/2.jpg', 'width': 800, 'height': 1200},
        ],
      },
    });
    expect(content.name, '第01話');
    expect(content.images.length, 2);
    expect(content.images.first.url, 'https://img/1.jpg');
    expect(content.next, 'ch-2');
  });

  test('MediaPage：写真 /api/v3/posts 条目映射（uuid 当路由标识）', () {
    final page = MediaPage.fromResults(
        MediaKind.photo,
        {
          'list': [
            {
              'uuid': '9f3a',
              'name': 'FangLin-流螢',
              'cover': 'https://img/cover.jpg',
              'popular': 1200,
              'mannequins': [
                {'name': 'FangLin', 'path_word': 'fanglin'},
              ],
              'datetime_updated': '2026-11-01',
            },
            {'uuid': '', 'name': '坏条目'},
          ],
          'total': 2,
          'limit': 10,
        },
        offset: 0);
    expect(page.items.length, 1);
    expect(page.items.first.pathWord, '9f3a');
    expect(page.items.first.name, 'FangLin-流螢');
    expect(page.items.first.authors, ['FangLin']);
    expect(page.items.first.statusLabel, '写真');
  });

  test('MediaPage：书架 collect/posts 的 {post:{...}} 包裹同样能解析', () {
    // 旧实现只认扁平字段，书架写真条目会被当成空 path_word 全部过滤掉。
    final page = MediaPage.fromResults(
        MediaKind.photo,
        {
          'list': [
            {
              'last_browse': null,
              'post': {
                'uuid': 'a1b2',
                'name': '写真相册',
                'cover': 'https://img/c2.jpg',
                'popular': 33,
                'mannequins': [
                  {'name': '模特A'},
                ],
              },
            },
            {
              'post': {'name': '缺 uuid'}
            },
          ],
          'total': 2,
          'limit': 10,
        },
        offset: 0);
    expect(page.items.length, 1);
    expect(page.items.first.pathWord, 'a1b2');
    expect(page.items.first.authors, ['模特A']);
    expect(page.items.first.statusLabel, '写真');
  });

  test('Comic：comic2 的 status 对象取 display，不落成 Map.toString', () {
    final ongoing = Comic.fromJson({
      'uuid': 'u1',
      'name': 'A',
      'status': {'value': 0, 'display': '連載中'},
    });
    expect(ongoing.status, 'ongoing');
    expect(ongoing.statusLabel, '连载中');

    final finished = Comic.fromJson({
      'uuid': 'u2',
      'name': 'B',
      'status': {'value': 1, 'display': '已完結'},
    });
    expect(finished.status, 'completed');
    expect(finished.statusLabel, '已完结');

    // 列表接口给的是空串（/comics?top=finish），按连载中兜底而不是空字符串。
    final plain = Comic.fromJson({'uuid': 'u3', 'name': 'C', 'status': ''});
    expect(plain.status, 'ongoing');
  });
}

Widget _gridApp(List<String> titles) {
  return MaterialApp(
    theme: AppTheme.light(AppTheme.seedOf(0)),
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverGrid(
              gridDelegate: kTripleGridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) => RichGridCard(
                  title: titles[i],
                  author: '作者$i',
                  popular: '1.2万',
                  date: '2026-11-09',
                  onTap: () {},
                ),
                childCount: titles.length,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 取出当前树里所有骨架色块的渲染尺寸，用来断言「骨架尺寸 == 真实组件尺寸」。
List<Size> _skeletonSizes(WidgetTester tester) {
  final finder = find.byType(SkeletonBox);
  return [
    for (var i = 0; i < finder.evaluate().length; i++)
      tester.getSize(finder.at(i)),
  ];
}

/// 在足够高的视口里渲染骨架，保证 ListView 会把章节网格等靠下的区块也建出来
/// （默认 800×600 视口下它们还没进入构建范围，断言会误判为「不存在」）。
Future<void> _pumpSkeleton(WidgetTester tester, Widget skeleton) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: skeleton)));
  await tester.pump(const Duration(milliseconds: 100));
}

/// NetImage 渲染路径的护栏。
///
/// 这里刻意**不用** widget test 去验证解码结果：`ui.instantiateImageCodec`
/// 依赖引擎真实事件循环，`testWidgets` 的 FakeAsync 推不动它，用例会直接挂住
/// （实测 `tester.runAsync` 也救不回来）。真机渲染由装机验收覆盖，源码层面
/// 用这条护栏把「不许退回 image stream 二次出帧」钉死。
void _netImageTests() {
  test('NetImage 必须预解码成 RawImage，不能退回 Image.memory + frameBuilder', () {
    // 去掉文档注释，注释里为了说明根因会提到这些名字。
    final source = File('lib/widgets/net_image.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('///'))
        .join('\n');

    expect(source.contains('ui.instantiateImageCodec('), isTrue,
        reason: '必须先在 Future 链路里把字节解成 ui.Image');
    expect(source.contains('RawImage('), isTrue,
        reason: '解码结果要一次 build 就交给 RawImage paint');
    expect(source.contains('Image.memory('), isFalse,
        reason: 'Image.memory 需要第二次出帧，MuMu 虚拟屏上会永久停在灰骨架');
    expect(source.contains('frameBuilder:'), isFalse,
        reason: '不能再依赖 image stream 的 frame 回调切换 child');
    expect(source.contains('visible: loading'), isTrue,
        reason: '图到了必须收掉进度条，否则左下角永远留一截白线');
  });

  test('NetImage 只画仍被持有的图：不许把已 dispose 的 ui.Image 交给 RawImage', () {
    // 回归：切「下一话」整屏红字
    // `Bad state: Cannot clone a disposed image.`
    // 根因是换 URL 时旧图在帧末被 dispose()，而 FutureBuilder 换成新 future 之后
    // 仍把上一份数据原样带着（waiting 状态下 hasData 为真），RawImage 重建时
    // 会对这张已释放的图 clone()。所以 builder 必须先用 _owned 认一遍。
    final source = File('lib/widgets/net_image.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('///'))
        .join('\n');

    expect(source.contains('_owned.contains(decoded.image)'), isTrue,
        reason: 'RawImage 前的所有权判断不能被删掉，否则换图必踩 disposed image');
  });

  test('切话时不许用上一话的数据建新阅读器（会连带踩 disposed image）', () {
    final source = File('lib/screens/reader_screen.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('///'))
        .join('\n');

    expect(source.contains('data.chapterUuid != _chapterUuid'), isTrue,
        reason: 'FutureBuilder 在切话期间仍交出旧一话的数据，必须按 chapterUuid 拦掉');
    expect(source.contains('ReaderLoadingView()'), isTrue,
        reason: '数据没到位时显示整屏骨架，而不是拿旧页面硬建阅读器');
  });
}

/// 开机那帧「白底 + App 图标」必须去掉，但**链路检测页要留**。
///
/// 两者是两回事：
/// - 图标闪屏 = Android 12+ 的系统启动画面（`windowSplashScreenAnimatedIcon`），
///   之前这里是空的，系统就把 `android:icon`（蓝底 M 图标）画在屏幕正中；
/// - 链路检测页 = `BootstrapScreen`，逐条点亮线路 + 进度条 + 「跳过检测」，
///   是 app 的首屏，用户明确要求保留。
///
/// 这条是**源码护栏**：真机上的观感只能在设备上看，但「启动画面不许再画图标」
/// 和「首页不许被误删」可以在这里钉死（上一轮就是把两者混为一谈，顺手把首屏删了）。
void _noSplashTests() {
  test('开机闪屏不再画 App 图标：透明图标 + 纯底色，链路检测页保留', () {
    final appSource = File('lib/app.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(appSource.contains('home: const BootstrapScreen()'), isTrue,
        reason: '首屏仍然是链路检测页，探测过程要看得见');

    final bootstrap = File('lib/screens/bootstrap_screen.dart');
    expect(bootstrap.existsSync(), isTrue, reason: '链路检测页不能删');
    final bootstrapSource = bootstrap.readAsStringSync();
    expect(bootstrapSource.contains('进入前先检测链路是否畅通'), isTrue);
    expect(bootstrapSource.contains('跳过检测，直接使用当前链路'), isTrue);

    // Android 12+ 系统启动画面（API 31+）
    final v31 = File('android/app/src/main/res/values-v31/styles.xml');
    expect(v31.existsSync(), isTrue,
        reason: '没有它，Android 12+ 会自己把 App 图标画成启动页');
    final v31Source = v31.readAsStringSync();
    expect(
        v31Source.contains(
            'android:windowSplashScreenAnimatedIcon">@drawable/splash_icon_none'),
        isTrue,
        reason: '图标位要换成全透明 drawable，否则屏幕上出现的就是那个图标界面');
    expect(
        v31Source.contains(
            'android:windowSplashScreenBackground">@color/launch_bg'),
        isTrue,
        reason: '底色要和首页表层色一致，不能白屏闪一下');

    final nightV31 =
        File('android/app/src/main/res/values-night-v31/styles.xml');
    expect(nightV31.existsSync(), isTrue, reason: '深色模式的启动画面同样要去图标');
    expect(
        nightV31.readAsStringSync().contains('@drawable/splash_icon_none'),
        isTrue);

    // 老版本启动背景（pre-31）也不许塞 bitmap / logo
    for (final p in [
      'android/app/src/main/res/drawable/launch_background.xml',
      'android/app/src/main/res/drawable-v21/launch_background.xml',
    ]) {
      final src = File(p).readAsStringSync();
      expect(src.contains('<bitmap'), isFalse, reason: '$p 不许再放图标位图');
      expect(src.contains('@color/launch_bg'), isTrue);
    }
  });
}

void _chapterGridTests() {
  test('章节目录网格固定 6 列：数字 1 / 10 / 100 宽度不同也不会错位', () {
    // 之前用 Wrap + ActionChip，chip 宽度随字数变化，
    // 第一行能塞 6 个、第二行只剩 5 个，列与列对不齐。
    expect(kChapterGridDelegate.crossAxisCount, 6);
    expect(kChapterGridDelegate.mainAxisSpacing, 8);
    expect(kChapterGridDelegate.crossAxisSpacing, 8);
  });

  testWidgets('网络图片占位不套呼吸动画 / 淡入：图片密集页不产生上百个 ticker', (tester) async {
    // 动画 / 写真详情一屏上百张封面。早期实现给每张图套一个 Shimmer
    // （AnimationController.repeat）+ 解码后一个 AnimatedOpacity，
    // 骨架 → 数据那一帧会集中创建 / 销毁上百个 ticker 和 opacity layer，
    // 在 MuMu 虚拟屏上直接停在 NEEDS-PAINT，整屏只剩 surface 色。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 62,
            height: 62,
            child: NetImage(url: 'https://invalid.example/missing.png'),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);

    expect(find.byType(SkeletonBox), findsOneWidget,
        reason: '加载 / 失败仍要有骨架色块，不能退化成纯白卡片');
    expect(find.byType(Shimmer), findsNothing,
        reason: '单张图片占位不该各起一条 AnimationController.repeat()');
    expect(find.byType(AnimatedOpacity), findsNothing,
        reason: '解码后不该再为每张图创建一个 opacity layer');
  });

  testWidgets('页面级骨架仍保留呼吸效果（只去掉单图动画）', (tester) async {
    await _pumpSkeleton(tester, const ContentDetailSkeleton());
    expect(tester.takeException(), isNull);
    expect(find.byType(Shimmer), findsWidgets,
        reason: '首页 / 聚合页 / 详情页骨架数量少，呼吸效果应保留');
  });

  testWidgets('内容详情进入页骨架：背景大图 / 长简介 / 两组 chip / 竖向目录', (tester) async {
    // 用户明确：小说「进入页」（封面 + 简介 + 题材这页）要骨架屏，
    // 而且骨架要按服务器返回数据的真实布局来，不能为了骨架而骨架。
    // 详情页统一成漫画那种「背景大图」后，原来的小封面已不存在。
    await _pumpSkeleton(tester, const ContentDetailSkeleton());
    expect(tester.takeException(), isNull);

    final sizes = _skeletonSizes(tester);
    // 真实页面用的是 SliverAppBar(expandedHeight: kDetailHeroHeight) + 整宽背景图。
    expect(sizes.any((s) => s.height == kDetailHeroHeight && s.width > 300),
        isTrue,
        reason: '骨架缺少整宽 ${kDetailHeroHeight.toInt()} 的头图块');
    // 简介是折叠态：3 行正文 + 一行「展开简介」开关。整段长简介默认不再铺开，
    // 所以骨架也不该按 6~8 行占位，否则数据一到会整块往上跳。
    expect(sizes.where((s) => s.height == 13).length, greaterThanOrEqualTo(4),
        reason: '简介应占 3 行 + 展开开关一行');
    // 题材 + 作者两组 chip，各有一个 44×14 的组名占位。
    expect(sizes.where((s) => s.width == 44 && s.height == 14).length,
        greaterThanOrEqualTo(2),
        reason: '题材 / 作者应该是两组 chip');
    // 目录是 ListTile 竖排（标题 + 两行文字），不是 6 列网格。
    // 有封面的内容（动画每集 / 写真章节）行首是 62×62 缩略图；但**不再是**
    // 44×44 的灰底序号块（用户反馈：没封面时那一列全是重复数字，没信息量，
    // 还把标题挤到第二列）。
    expect(sizes.where((s) => s.width == 62 && s.height == 62).length,
        greaterThanOrEqualTo(3),
        reason: '动画 / 写真目录行应有 62×62 封面占位');
    expect(sizes.where((s) => s.width == 44 && s.height == 44).length, 0,
        reason: '目录行不该再有 44×44 的序号块');
    expect(find.byType(GridView), findsNothing, reason: '内容详情不该出现章节网格');
    expect(find.byType(Shimmer), findsWidgets, reason: '进入页必须是骨架屏');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '进入页不是 loading 转圈');

    // 轻小说卷没有单卷封面（数据页 leading 为空），骨架行首也就不留块，
    // 否则骨架 → 数据会横向跳一下。
    await _pumpSkeleton(
        tester, const ContentDetailSkeleton(hasChapterCover: false));
    final novelSizes = _skeletonSizes(tester);
    expect(novelSizes.where((s) => s.width == 62 && s.height == 62).length, 0,
        reason: '轻小说目录行没有封面，骨架不该留 62×62 块');
  });

  testWidgets('详情页简介默认只显示 3 行，可手动展开看全文', (tester) async {
    const longText = '少年吃了地下迷宫的怪兽，变身最强！！'
        '刘谷鸣和儿时玩伴高坂真那，突然一同被召唤到异世界变成了勇者。'
        '真那发现自己有魔法的才能，但鸣却什么能力也没觉醒。'
        '在战力高强的第三位勇者被召唤过来之后，没有用处的他被推落通往地下迷宫的谷底……'
        '在濒死状态下遭受怪兽攻击的鸣，于绝望中察觉自己获得了「吞噬之瞳」的能力。';
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: ExpandableText(text: longText),
        ),
      ),
    ));

    // 折叠态：正文限 3 行 + 省略号，开关写「展开简介」。
    expect(tester.widget<Text>(find.text(longText)).maxLines, 3,
        reason: '简介默认最多显示 3 行');
    expect(find.text('展开简介'), findsOneWidget, reason: '超出 3 行要给展开入口');

    // 点开：完整正文（不限行数），开关变「收起简介」。
    await tester.tap(find.text('展开简介'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longText)).maxLines, isNull,
        reason: '展开后要显示完整简介，不是固定行数截断');
    expect(find.text('收起简介'), findsOneWidget, reason: '展开后可以再收回去');

    // 收回：回到 3 行。
    await tester.tap(find.text('收起简介'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longText)).maxLines, 3,
        reason: '收起后回到 3 行折叠态');
    expect(find.text('展开简介'), findsOneWidget);
  });

  testWidgets('简介不超过 3 行时不出现展开开关', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: ExpandableText(text: '短简介。'),
        ),
      ),
    ));
    expect(find.text('短简介。'), findsOneWidget);
    expect(find.text('展开简介'), findsNothing, reason: '没有溢出就不要放一个点了没反应的开关');
  });

  testWidgets('漫画详情进入页 / 下拉刷新骨架：整幅头图 + 4 列章节网格', (tester) async {
    // 精选「全新上架」点进漫画详情时，早期是「空 AppBar + 居中转圈」，
    // 用户要求改成与内容同样占位的骨架；该页下拉刷新也会重新走同一个
    // FutureBuilder 加载态，因此两者共用这里。
    await _pumpSkeleton(tester, const ComicDetailSkeleton());
    expect(tester.takeException(), isNull);

    expect(find.byType(CustomScrollView), findsOneWidget,
        reason: '真实详情页是 CustomScrollView，骨架应同构');
    final appBar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
    expect(appBar.expandedHeight, kDetailHeroHeight, reason: '头图占位高度须与真实一致');
    expect(appBar.pinned, isTrue, reason: '头图是 pinned SliverAppBar');
    expect(find.byType(FlexibleSpaceBar), findsOneWidget,
        reason: '头图应有封面 + 标题占位');
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(grid.gridDelegate, kChapterGridDelegate,
        reason: '章节网格必须复用真实 6 列 delegate，尺寸才不跳');
    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.byType(Shimmer), findsWidgets, reason: '必须是骨架屏');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '不能再用整屏转圈');
  });

  testWidgets('聚合页骨架：轮播 190 + 分组横滑卡，没有三列网格', (tester) async {
    await _pumpSkeleton(tester, const MediaIndexSkeleton());
    expect(tester.takeException(), isNull);

    final sizes = _skeletonSizes(tester);
    expect(sizes.any((s) => s.height == 190), isTrue, reason: '缺少 190 高轮播');
    expect(find.byType(GridView), findsNothing, reason: '聚合页真实布局里没有三列网格');
  });

  testWidgets('漫画 / 写真阅读器加载态：整屏一整块，不分页、不带圆角', (tester) async {
    // 漫画阅读器加载时就是一整屏占位色；早期做成「黑底 + 3 张 240/300 高
    // 圆角灰卡 + 16 内边距 + 14 间隙」，滚动会露黑边，数据到达还会三块一起
    // 跳走。写真改成同一套整页翻页后复用同一块整屏占位（`ReaderLoadingView`）。
    // 注意：这不是骨架屏 —— 轻小说正文是转圈，轻小说进入页是
    // ContentDetailSkeleton。
    await tester.pumpWidget(const MaterialApp(home: ReaderLoadingView()));
    expect(tester.takeException(), isNull);

    final box = find.byType(SkeletonBox);
    expect(box, findsOneWidget, reason: '整块占位只能有一块，不能按页切分');
    expect(find.byType(ListView), findsNothing, reason: '全屏占位不该是可滚动列表');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final rect = tester.getRect(box);
    expect(rect.topLeft, Offset.zero, reason: '占位必须从 (0,0) 铺满');
    final radius = tester.widget<SkeletonBox>(box).radius;
    final isSharp = radius is BorderRadius
        ? radius == BorderRadius.zero
        : (radius as num) == 0;
    expect(isSharp, isTrue, reason: '整屏占位不能有圆角，否则四角露底色');
  });

  testWidgets('首页 / 聚合页骨架轮播紧贴顶栏：顶部不留白色空位', (tester) async {
    // 真实布局里 CoverCarousel 是第一个 sliver，顶栏下方没有上边距。
    // 早期骨架多放了 SizedBox(height: 10)，用户截图里就是一截白色空位。
    for (final skeleton in <Widget>[
      const HomeSkeleton(),
      const MediaIndexSkeleton(),
    ]) {
      await _pumpSkeleton(tester, skeleton);
      expect(tester.takeException(), isNull);

      final first = find.byType(SkeletonBox).first;
      expect(tester.getRect(first).top, 0.0, reason: '轮播骨架必须从 y=0 开始，不能再留顶部间距');
      expect(tester.getSize(first).height, 190.0,
          reason: '轮播占位高度应与 CoverCarousel 一致');
      // 轮播块里要有底部标题条占位，不能是一整片纯色「空白」。
      expect(find.byType(Stack), findsWidgets);
    }
  });
}

void _chapterPagingTests() {
  test('章节分页：0 / 恰好 100 / 101 / 1000 的边界', () {
    expect(chapterPageRange(0, 0).pages, 0);
    expect(chapterPageRange(0, 0).isEmpty, isTrue);
    expect(chapterPageRange(0, 0).showPager, isFalse);

    // 恰好 100 话：一页装下，不显示分页器（用户截图里的 100 话就是这种）。
    final exact = chapterPageRange(100, 0);
    expect(exact.pages, 1);
    expect(exact.start, 0);
    expect(exact.count, 100);
    expect(exact.showPager, isFalse);

    // 101 话：第二页只有 1 条。
    final over = chapterPageRange(101, 1);
    expect(over.pages, 2);
    expect(over.start, 100);
    expect(over.count, 1);
    expect(over.showPager, isTrue);

    // 1000 话：第 10 页 900..999。
    final big = chapterPageRange(1000, 9);
    expect(big.pages, 10);
    expect(big.start, 900);
    expect(big.count, 100);
  });

  test('章节分页：页码越界会被夹回合法范围，不会越界取数', () {
    // 数据刷新后章节变少，旧页码必须夹回最后一页，否则 SliverChildBuilder
    // 会拿 chapters[200] 直接抛 RangeError。
    final clamped = chapterPageRange(120, 5);
    expect(clamped.pages, 2);
    expect(clamped.start, 100);
    expect(clamped.count, 20);
  });
}
