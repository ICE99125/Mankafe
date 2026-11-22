import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/widgets/paged_image_reader.dart';

/// 用空 URL 的页做占位：不联网、不读盘，只验证翻页 / 工具栏 / 缩放这些交互。
List<ReaderPageImage> _blankPages(int count) =>
    List<ReaderPageImage>.generate(count, (_) => const ReaderPageImage.url(''));

Widget _harness(
  List<ReaderPageImage> pages, {
  int initialPage = 0,
  ValueChanged<int>? onPageChanged,
  VoidCallback? onPrev,
  VoidCallback? onNext,
  bool showIndicator = true,
  ReadDirection direction = ReadDirection.horizontal,
}) {
  return MaterialApp(
    // 固定中文，文案断言不随测试机 locale 变化；delegates 与 app.dart 保持一致，
    // 否则 zh_CN 下拿不到 MaterialLocalizations（返回键 tooltip 就取不到）。
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: PagedImageReader(
        pages: pages,
        title: '月刊少女野崎君',
        subtitle: '第01卷',
        albumTitle: '月刊少女野崎君 第01卷',
        onBack: () {},
        initialPage: initialPage,
        showIndicator: showIndicator,
        direction: direction,
        onPageChanged: onPageChanged,
        onPrev: onPrev,
        onNext: onNext,
      ),
    ),
  );
}

/// 双指张开：从倍率 1 放大到约 4 倍（`maxScale`）。
Future<void> _pinchOut(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(PageView));
  final first = await tester.startGesture(center - const Offset(10, 0));
  final second = await tester.startGesture(center + const Offset(10, 0));
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await first.moveBy(const Offset(-6, 0));
    await second.moveBy(const Offset(6, 0));
    await tester.pump();
  }
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

void main() {
  group('版式', () {
    testWidgets('顶栏作品名 / 话名 + 底栏页码 / 总数 + 进度条', (tester) async {
      await tester.pumpWidget(_harness(_blankPages(3)));
      await tester.pump();

      expect(find.text('月刊少女野崎君'), findsOneWidget);
      expect(find.text('第01卷'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // 进度与第一页一致（1/3）。
      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(1 / 3, 0.001));
    });

    testWidgets('初始页由调阅方指定：写真续看直接落在上次页码', (tester) async {
      await tester.pumpWidget(_harness(_blankPages(9), initialPage: 4));
      await tester.pump();
      expect(find.text('5 / 9'), findsOneWidget);
    });

    testWidgets('关掉「显示阅读进度」时底栏中间显示话名，不画进度条', (tester) async {
      await tester.pumpWidget(
          _harness(_blankPages(3), showIndicator: false));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('1 / 3'), findsNothing);
      expect(find.text('第01卷'), findsWidgets);
    });
  });

  group('翻页', () {
    testWidgets('点右三分之一 → 下一页，回调带真实下标', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(find.text('2 / 3'), findsOneWidget);
      expect(seen, [1]);
    });

    testWidgets('点左三分之一 → 上一页', (tester) async {
      await tester.pumpWidget(_harness(_blankPages(3), initialPage: 1));
      await tester.pump();
      expect(find.text('2 / 3'), findsOneWidget);

      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.1, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('单指拖动可以翻页（缩放层不能把横向拖动吃掉）', (tester) async {
      // 关键的回归点：每页都套了缩放层。拖动距离必须明显超过半页，
      // 否则 PageView 会按「不到中点」判回原页，看起来像没翻（这不是手势被吃）。
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(find.text('2 / 3'), findsOneWidget);
      expect(seen, [1]);
    });

    testWidgets('上下滚动模式：滑到页底再继续滑就翻页', (tester) async {
      // 占位页高 1200、视口 600：先滚 600 到底，再滑 600 才是「滑到头继续滑」。
      await tester.pumpWidget(
          _harness(_blankPages(3), direction: ReadDirection.vertical));
      await tester.pump();

      await tester.drag(find.byType(PageView), const Offset(0, -1200));
      await tester.pumpAndSettle();

      expect(find.text('2 / 3'), findsOneWidget);
    });

    testWidgets('末页继续点下一页不会越界', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_harness(_blankPages(2),
          initialPage: 1, onPageChanged: (_) => calls++));
      await tester.pump();

      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.9, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('上一话 / 下一话按回调走，没有回调时按钮禁用', (tester) async {
      var prev = 0;
      var next = 0;
      await tester.pumpWidget(_harness(_blankPages(2),
          onPrev: () => prev++, onNext: () => next++));
      await tester.pump();

      await tester.tap(find.text('上一话'));
      await tester.tap(find.text('下一话'));
      expect(prev, 1);
      expect(next, 1);

      await tester.pumpWidget(_harness(_blankPages(2)));
      await tester.pump();
      final prevButton =
          tester.widget<TextButton>(find.ancestor(
        of: find.text('上一话'),
        matching: find.byType(TextButton),
      ));
      expect(prevButton.onPressed, isNull, reason: '没有上一话时按钮必须禁用');
    });
  });

  group('工具栏', () {
    testWidgets('点中间收 / 放顶栏底栏，整页图始终在', (tester) async {
      await tester.pumpWidget(_harness(_blankPages(2)));
      await tester.pump();

      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.5, size.height * 0.5));
      await tester.pumpAndSettle();
      expect(find.text('月刊少女野崎君'), findsNothing);
      expect(find.byType(PageView), findsOneWidget);

      await tester.tapAt(Offset(size.width * 0.5, size.height * 0.5));
      await tester.pumpAndSettle();
      expect(find.text('月刊少女野崎君'), findsOneWidget);
    });
  });

  group('缩放', () {
    testWidgets('双指放大后单指拖动是平移，不再翻页', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      await _pinchOut(tester);
      // 真的放大了：页面内层的 Transform 矩阵倍率 > 1。
      final scales = tester
          .widgetList<Transform>(find.descendant(
              of: find.byType(PageView), matching: find.byType(Transform)))
          .map((widget) => widget.transform.getMaxScaleOnAxis());
      expect(scales.any((scale) => scale > 1.01), isTrue,
          reason: '双指张开后页面必须真的放大');

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(seen, isEmpty, reason: '放大状态下的拖动应该平移图片，不能翻页');
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('放大状态下点左侧只开关工具栏，不翻页', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      await _pinchOut(tester);
      final size = tester.getSize(find.byType(PageView));
      await tester.tapAt(Offset(size.width * 0.1, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(seen, isEmpty, reason: '放大时点两侧不该翻页');
      expect(find.text('月刊少女野崎君'), findsNothing,
          reason: '第一下点击只收工具栏');
    });

    testWidgets('双指捏回 1x 后恢复翻页', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      await _pinchOut(tester);
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget, reason: '放大时不翻页');

      // 双指捏合回 1x（两指不要收到同一个点：间距为 0 时缩放比会退化）。
      final center = tester.getCenter(find.byType(PageView));
      final first = await tester.startGesture(center - const Offset(140, 0));
      final second = await tester.startGesture(center + const Offset(140, 0));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await first.moveBy(const Offset(9, 0));
        await second.moveBy(const Offset(-9, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget,
          reason: '缩回 1x 后单指拖动必须恢复翻页');
      expect(seen, [1]);
    });

    testWidgets('放大后拖到图片底边继续拖 → 进入下一页（不用先捏回 1x）', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(
          _harness(_blankPages(3), onPageChanged: seen.add));
      await tester.pump();

      await _pinchOut(tester);
      // 4 倍下纵向可平移 (4-1)*600/2 = 900，拖 1200 先到底、再溢出 300。
      await tester.drag(find.byType(PageView), const Offset(0, -1200));
      await tester.pumpAndSettle();

      expect(seen, [1], reason: '放大后拖到底继续拖必须能翻页');
      expect(find.text('2 / 3'), findsOneWidget);
    });

    testWidgets('放大后拖到图片顶边继续拖 → 回到上一页', (tester) async {
      final seen = <int>[];
      await tester.pumpWidget(_harness(_blankPages(3),
          initialPage: 1, onPageChanged: seen.add));
      await tester.pump();

      await _pinchOut(tester);
      await tester.drag(find.byType(PageView), const Offset(0, 1200));
      await tester.pumpAndSettle();

      expect(seen, [0]);
      expect(find.text('1 / 3'), findsOneWidget);
    });
  });

  group('铺满宽度', () {
    late Directory dir;
    late File pageFile;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('paged_reader_fit');
      pageFile = File('${dir.path}/page-1.png');
      await pageFile.writeAsBytes(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1, //
      ]);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('图片按宽度铺满：宽度等于屏宽，超高部分在页内上下滚动', (tester) async {
      await tester.pumpWidget(_harness(_blankPages(2)));
      await tester.pump();

      final scroll = find.descendant(
        of: find.byType(PageView),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroll, findsWidgets, reason: '每页都要能上下滚动');
      expect(tester.getSize(scroll.first).width, 800.0,
          reason: '滚动区宽度就是屏宽，图按宽度铺满而不是缩到中间一条');

      final position = tester
          .state<ScrollableState>(find.descendant(
            of: scroll.first,
            matching: find.byType(Scrollable),
          ))
          .position;
      expect(position.maxScrollExtent, greaterThan(0),
          reason: '占位页高宽比 2:3，比视口高，必须有滚动余量');

      // 1x 下竖向拖动只滚动页内：左右翻页模式里竖着划一下不该翻页。
      await tester.drag(find.byType(PageView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(position.pixels, greaterThan(0));
    });

    testWidgets('本地页用 fitWidth（不是 contain，不会再缩成窄条）', (tester) async {
      await tester.pumpWidget(
          _harness(<ReaderPageImage>[ReaderPageImage.local(pageFile)]));
      await tester.pump();

      final image = tester.widget<Image>(find
          .descendant(
            of: find.byType(PageView),
            matching: find.byType(Image),
          )
          .first);
      expect(image.fit, BoxFit.fitWidth);
      expect(tester.getSize(find.byType(Image).first).width, 800.0);
    });
  });

  group('保存到相册', () {
    // 造图要用真实 I/O：testWidgets 的 body 跑在 FakeAsync zone 里，
    // 直接 await 文件读写会永远等不到回调（表现为用例 10 分钟超时）。
    late Directory dir;
    late File pageFile;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('paged_reader_album');
      pageFile = File('${dir.path}/page-1.png');
      await pageFile.writeAsBytes(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1, //
      ]);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('长按整页图弹出「保存到相册」操作表', (tester) async {
      await tester.pumpWidget(
          _harness(<ReaderPageImage>[ReaderPageImage.local(pageFile)]));
      await tester.pump();

      await tester.longPress(find.byType(PageView));
      // 操作表是模态路由：用定量的 pump 等动画，别用 pumpAndSettle
      // （弹层里有持续动画时会一直等下去）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final t = AppLocalizations.of(tester.element(find.byType(BottomSheet)));
      expect(find.text(t.saveToAlbum), findsOneWidget);
      expect(find.text(t.saveToAlbumHint), findsOneWidget);
      expect(find.text(t.pageLabel(1)), findsOneWidget);
      // 只验证入口，不真的点保存：点了会往本机相册目录写文件。
      await tester.tapAt(const Offset(20, 20)); // 点空白处收起操作表
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(t.saveToAlbum), findsNothing);
    });
  });
}
