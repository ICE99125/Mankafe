import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/widgets/browse_widgets.dart';

/// 轮播自动播放的回归用例：
/// - 多帧默认自动前进，末帧后无缝回到第一帧（首尾克隆帧不能多显示一个圆点）；
/// - 只有一帧时不动；
/// - 被 TickerMode 静音的页面（底部 tab 切走）暂停，切回后继续；
/// - autoPlayInterval 传 Duration.zero 可关闭。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget _carousel({
  int frames = 3,
  Duration interval = const Duration(seconds: 1),
}) {
  return CoverCarousel(
    slides: [
      for (var i = 0; i < frames; i++) CarouselSlide(title: '第$i帧'),
    ],
    autoPlayInterval: interval,
  );
}

PageController _controller(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!;

Future<void> _pumpUntilPage(
  WidgetTester tester,
  PageController controller,
  double page,
) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (controller.page == page) return;
  }
  fail('轮播没有翻到第 $page 页（当前 ${controller.page}）');
}

void main() {
  testWidgets('多帧轮播自动播放，并在末帧后无缝回到第一帧', (tester) async {
    await tester.pumpWidget(_host(_carousel()));

    final controller = _controller(tester);
    expect(controller.page, 1.0, reason: '第一帧对应物理页 1（前面是末帧克隆）');
    // 克隆帧不参与圆点：3 帧只能有 3 个指示点。
    expect(find.byType(AnimatedContainer), findsNWidgets(3));

    await _pumpUntilPage(tester, controller, 2.0);
    await _pumpUntilPage(tester, controller, 3.0);
    // 末帧之后翻到尾部克隆帧，再在同一帧内跳回第一帧。
    await _pumpUntilPage(tester, controller, 1.0);
    expect(controller.page, 1.0);
  });

  testWidgets('只有一帧时不自动播放', (tester) async {
    await tester.pumpWidget(_host(_carousel(frames: 1)));

    final controller = _controller(tester);
    expect(controller.page, 0.0);
    await tester.pump(const Duration(seconds: 3));
    expect(controller.page, 0.0, reason: '单帧轮播没有下一页可翻');
  });

  testWidgets('切到被 TickerMode 静音的页面后暂停，切回继续播放', (tester) async {
    Widget host({required bool tickerEnabled}) => _host(
          TickerMode(enabled: tickerEnabled, child: _carousel()),
        );

    await tester.pumpWidget(host(tickerEnabled: true));
    final controller = _controller(tester);
    expect(controller.page, 1.0);

    await tester.pumpWidget(host(tickerEnabled: false));
    await tester.pump(const Duration(seconds: 3));
    expect(controller.page, 1.0, reason: '底部 tab 切走后不能继续自动翻页');

    await tester.pumpWidget(host(tickerEnabled: true));
    await _pumpUntilPage(tester, controller, 2.0);
  });

  testWidgets('autoPlayInterval 为 Duration.zero 时关闭自动播放', (tester) async {
    await tester.pumpWidget(
      _host(_carousel(interval: Duration.zero)),
    );

    final controller = _controller(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.page, 1.0);
  });
}
