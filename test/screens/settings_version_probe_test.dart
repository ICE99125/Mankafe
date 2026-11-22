import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/settings_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/device_profile.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// 设置页「新版本探测」：真实接口结构 → 展示 → 复制 → 自定义请求版本号。
///
/// 这组用例同时钉住三件事：
/// 1. `/api/v3/system/appVersion/last` 的返回能在界面上正确显示；
/// 2. 自定义版本号会真的出现在**请求头**里（不是只改了界面文字）；
/// 3. 复制下载地址走的是系统剪贴板通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DeviceProfile.customVersionEnabled = false;
    DeviceProfile.customVersion = DeviceProfile.version;
    DeviceProfile.customVersionCode = DeviceProfile.versionCode;
  });

  late _Harness harness;
  late List<http.BaseRequest> requests;

  setUp(() {
    requests = <http.BaseRequest>[];
    harness = _Harness(requests);
  });

  testWidgets('探测到新版本：名称/版本/非强制更新/下载地址齐全', (tester) async {
    await _pumpSettings(tester, harness);

    await _tapProbe(tester);

    expect(find.text('Android 正式版'), findsOneWidget);
    expect(find.text('3.1.1'), findsOneWidget);
    expect(find.text('最新版本'), findsOneWidget);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('非强制更新'), findsOneWidget);
    // 地址文本整串仍在（界面单行省略，逻辑上不截断），也用于剪贴板用例。
    expect(find.textContaining('copymanga.release_20261110_3.1.1.apk'),
        findsWidgets);
    // 只有 android 带下载地址，复制入口也只能有一个。
    expect(find.text('复制下载地址'), findsOneWidget);
    // 没更新的渠道整块隐藏。
    expect(find.text('IOS版'), findsNothing);
    expect(find.text('Android 舊版'), findsNothing);
  });

  testWidgets('下载地址只占一行，复制做成按钮压在地址下面', (tester) async {
    await _pumpSettings(tester, harness);
    await _tapProbe(tester);
    await _reveal(tester, find.text('复制下载地址'));

    final urlFinder = find.textContaining('copymanga.release_20261110_3.1.1.apk');
    final urlText = tester.widget<Text>(urlFinder);
    expect(urlText.maxLines, 1);
    expect(urlText.softWrap, isFalse);

    // 复制是按钮（可点、通栏），不是地址块里的一行小字。
    final copyButton =
        find.ancestor(of: find.text('复制下载地址'), matching: find.byType(FilledButton));
    expect(copyButton, findsOneWidget);
    expect(tester.getRect(copyButton).top,
        greaterThan(tester.getRect(urlFinder).bottom));
  });

  testWidgets('复制下载地址：写入系统剪贴板', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _pumpSettings(tester, harness);
    await _tapProbe(tester);

    await _reveal(tester, find.text('复制下载地址'));
    await tester.tap(find.text('复制下载地址'));
    await tester.pump();

    expect(copied, contains('copymanga.release_20261110_3.1.1.apk'));
    expect(copied, startsWith('https://s3.mangafunb.fun/'));
  });

  testWidgets('版本号输入框常驻展开：直接改就进请求头', (tester) async {
    await _pumpSettings(tester, harness);

    // 没有开关，一进来就是当前配置，两个输入框立刻可编辑。
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('3.1.0'), findsWidgets);

    await tester.enterText(find.byType(TextField).at(0), '9.9.9');
    await tester.enterText(find.byType(TextField).at(1), '200');
    await tester.pump();

    expect(DeviceProfile.effectiveVersion, '9.9.9');
    expect(DeviceProfile.effectiveVersionCode, '200');

    await _tapProbe(tester);

    final probe = requests.where(
        (r) => r.url.path.endsWith('/system/appVersion/last')).toList();
    expect(probe, hasLength(1));
    final headers = probe.single.headers;
    expect(headers['version'], '9.9.9');
    expect(headers['versionCode'], '200');
    expect(headers['user-agent'], 'COPY/9.9.9');
    expect(headers['referer'], 'com.copymanga.app-9.9.9');
  });

  testWidgets('一键填入最新版本：versionCode 按本地 +1 估算并提示', (tester) async {
    await _pumpSettings(tester, harness);
    await _tapProbe(tester);

    await _reveal(tester, find.text('一键填入最新版本'));
    await tester.tap(find.text('一键填入最新版本'));
    await tester.pump();

    expect(DeviceProfile.customVersionEnabled, isTrue);
    expect(DeviceProfile.effectiveVersion, '3.1.1');
    expect(DeviceProfile.effectiveVersionCode, '85');
    expect(find.text('已填入 3.1.1 / 85'), findsOneWidget);
  });

  testWidgets('请求头已是 3.1.1：不再提示有新版本', (tester) async {
    DeviceProfile.customVersionEnabled = true;
    DeviceProfile.customVersion = '3.1.1';
    DeviceProfile.customVersionCode = '85';
    await _pumpSettings(tester, harness);

    await _tapProbe(tester);

    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('复制下载地址'), findsNothing);
  });

  testWidgets('版本号必填：清空任一字段回落到 3.1.0 / 84', (tester) async {
    await _pumpSettings(tester, harness);

    await tester.enterText(find.byType(TextField).at(0), '9.9.9');
    await tester.pump();
    expect(DeviceProfile.effectiveVersion, '9.9.9');

    // version 被清空 → version / versionCode 一起回落默认。
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.pump();
    expect(DeviceProfile.customVersionEnabled, isFalse);
    expect(DeviceProfile.effectiveVersion, '3.1.0');
    expect(DeviceProfile.effectiveVersionCode, '84');
    expect(find.text('3.1.0'), findsWidgets);
    expect(find.text('84'), findsWidgets);

    // versionCode 同理。
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();
    expect(DeviceProfile.effectiveVersion, '3.1.0');
    expect(DeviceProfile.effectiveVersionCode, '84');
  });

  testWidgets('接口失败：显示错误提示而不是空白', (tester) async {
    final failing = _Harness(requests, fail: true);
    await _pumpSettings(tester, failing);
    await _tapProbe(tester);

    expect(find.textContaining('探测失败'), findsOneWidget);
  });

  testWidgets('设置页不再有展开态大标题：标题只在顶部导航栏', (tester) async {
    await _pumpSettings(tester, harness);
    final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
    expect(bar.expandedHeight, isNull);
    expect(bar.pinned, isTrue);
    // 标题贴着顶部（紧凑导航栏里），第一个分组标题紧随其后：
    // large 版本会把「外观」推到 200+ 的位置。
    expect(tester.getTopLeft(find.text('设置')).dy, lessThan(64));
    expect(tester.getTopLeft(find.text('外观')).dy, lessThan(120));
  });

  testWidgets('探测与一键填入各占一行、等宽且不溢出', (tester) async {
    await _pumpSettings(tester, harness, size: const Size(360, 760));
    await _tapProbe(tester);
    expect(tester.takeException(), isNull);

    await _reveal(tester, find.text('探测新版本'));
    Rect buttonRect(String label) => tester.getRect(find.ancestor(
          of: find.text(label),
          matching:
              find.byWidgetPredicate((w) => w is SizedBox && w.height == 52),
        ));
    final probe = buttonRect('探测新版本');
    final fill = buttonRect('一键填入最新版本');
    expect(probe.width, closeTo(fill.width, 1));
    // 分两行：一键填入整条压在探测按钮下面。
    expect(fill.top, greaterThan(probe.bottom - 1));
  });
}

/// 探测按钮在「新版本探测」卡片里，标题同名的只有这一个。
Future<void> _tapProbe(WidgetTester tester) async {
  await _reveal(tester, find.text('探测新版本'));
  await tester.tap(find.text('探测新版本'));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  // scrollUntilVisible 只保证「在列表里」，条目仍可能停在视口外沿，
  // 点下去会落到屏幕之外；ensureVisible 再把它推进可视区。
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(WidgetTester tester, _Harness h,
    {Size size = const Size(500, 900)}) async {
  tester.view.physicalSize = size;
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
      home: const SettingsScreen(),
    ),
  ));
  await tester.pump();
}

/// 一律不缓存，避开 `flutter test` 里 dart:io 的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _Harness {
  _Harness(this.requests, {this.fail = false});

  final List<http.BaseRequest> requests;
  final bool fail;

  late final AppState state = AppState();
  late final RouteManager routes = RouteManager()..autoFallback = false;
  late final Repository repo = Repository(
    ApiClient(routes, httpClient: _client(), cache: _NoCache()),
    routes,
    state,
  );

  http.Client _client() => MockClient((request) async {
        requests.add(request);
        if (fail) {
          return http.Response('boom', 500);
        }
        return http.Response(
          jsonEncode({
            'code': 200,
            'message': 'ok',
            'results': {
              'android': {
                'name': 'Android 正式版',
                'update': true,
                'version': '3.1.1',
                'url':
                    'https://s3.mangafunb.fun/project/apk/copy/copymanga.release_20261110_3.1.1.apk',
                'forced': false,
              },
              'ios': {
                'name': 'IOS版',
                'update': false,
                'version': '',
                'url': '',
                'forced': false,
              },
              'androidTest': {
                'name': 'Android 舊版',
                'update': false,
                'forced': false,
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
}
