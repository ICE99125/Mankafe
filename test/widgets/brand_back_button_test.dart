import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/widgets/brand_header.dart';

/// 顶栏返回键的归属：只有**被 push 出来的页面**才带返回键。
///
/// 一级页面（首页 / 频道 / 书架…）永远不该带——包括它被详情页盖住期间
/// 重建过、详情页再 pop 回它的时候。旧实现用 `Navigator.canPop()` 判断，
/// 于是「盖住期间重建」会把返回箭头烘进一级页面顶栏，且回来后没有任何东西
/// 再重建那行顶栏，箭头就一直在（点一下才消失）。
void main() {
  testWidgets('一级页面被详情页盖住期间重建，返回后顶栏不留返回键', (tester) async {
    // 顶栏挂在一个会自己刷新的容器下，用来模拟真实的重建来源：
    // 数据回包、键盘/MediaQuery 变化、pop 转场都会触发这类重建。
    final rebuildSignal = ValueNotifier<int>(0);
    final homeBarKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: rebuildSignal,
            builder: (context, _) => BrandBar(
              key: homeBarKey,
              title: const BrandTitle(name: '漫咖'),
            ),
          ),
        ),
      ),
    );

    // 栈里只有一级页面：没有返回键。
    expect(find.byIcon(Icons.arrow_back, skipOffstage: false), findsNothing);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    // 点进详情页，被 push 出来的页面自动带返回键。
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: BrandBar(title: BrandTitle(name: '详情')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // 详情页盖在上面时，一级页面重建一次——此刻栈里还有两条 route，
    // 旧实现就是在这一步把返回箭头画进了被盖住的顶栏。
    rebuildSignal.value++;
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(homeBarKey, skipOffstage: false),
        matching: find.byIcon(Icons.arrow_back, skipOffstage: false),
      ),
      findsNothing,
    );

    // 返回一级页面：整屏只剩一级页面自己的顶栏，不能挂着返回键。
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back, skipOffstage: false), findsNothing);
  });

  testWidgets('启动页 pushReplacement 成主壳后，主壳顶栏不带返回键', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _StartupStub()));

    // 转场走完，启动页那条 route 已被替换掉。
    await tester.pumpAndSettle();

    expect(find.text('漫咖'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back, skipOffstage: false), findsNothing);
  });
}

/// 仿 `BootstrapScreen`：首帧之后用 `pushReplacement` 换成主壳。
class _StartupStub extends StatefulWidget {
  const _StartupStub();

  @override
  State<_StartupStub> createState() => _StartupStubState();
}

class _StartupStubState extends State<_StartupStub> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          pageBuilder: (_, __, ___) => const Scaffold(
            body: BrandBar(title: BrandTitle(name: '漫咖')),
          ),
          transitionDuration: const Duration(milliseconds: 180),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('启动中')));
}
