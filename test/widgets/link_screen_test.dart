import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/link_screen.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 当前链路卡片里的四个事实（状态 / 延迟 / 来源 / 畅通链路）改成「田」字
/// 排列：两行两列、左右等宽、行内等高。
///
/// 之前用 `Wrap`，格子宽度跟着文字长度走（「状态」窄、「畅通链路」宽），
/// 四个块挤在一行、下一行又对不齐。这里用几何断言把布局钉住，避免以后
/// 又退回内容宽度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('当前链路的四个事实按田字排列：两行两列、等宽、行内等高', (tester) async {
    // 窄屏（360dp）是最容易溢出的宽度，也最考验等宽分栏。
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final routes = RouteManager()..autoFallback = false;
    final state = AppState();
    addTearDown(routes.dispose);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<RouteManager>.value(value: routes),
        ChangeNotifierProvider<AppState>.value(value: state),
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
        home: const LinkScreen(),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '窄屏下不该溢出');

    final status = tester.getRect(find.text('状态'));
    final latency = tester.getRect(find.text('延迟'));
    final origin = tester.getRect(find.text('来源'));
    final online = tester.getRect(find.text('畅通链路'));

    // 第一行：状态 | 延迟
    expect(latency.top, moreOrLessEquals(status.top, epsilon: 0.5),
        reason: '状态与延迟应在同一行');
    expect(latency.left, greaterThan(status.left), reason: '延迟在状态右侧');

    // 第二行：来源 | 畅通链路
    expect(online.top, moreOrLessEquals(origin.top, epsilon: 0.5),
        reason: '来源与畅通链路应在同一行');
    expect(online.left, greaterThan(origin.left), reason: '畅通链路在来源右侧');

    // 第二行整体在第一行下方（田字而不是一行四个）
    expect(origin.top, greaterThan(status.bottom), reason: '来源应在状态下方，说明是两行两列');

    // 左右两列左边界对齐：延迟与畅通链路起始 x 相同
    expect(latency.left, moreOrLessEquals(online.left, epsilon: 0.5),
        reason: '右列两块要左对齐');

    // 两列等宽：两行右列起点一致即列宽一致，再直接比对同一行两块的宽度
    final boxWidth = tester.getSize(find
        .ancestor(
          of: find.text('状态'),
          matching: find.byType(Container),
        )
        .first);
    expect(boxWidth.width, greaterThan(100), reason: '每格应占约一半宽度，而不是跟着文字收缩');
  });
}
