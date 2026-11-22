import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/app_info.dart';
import 'package:mankafe/widgets/brand_header.dart';

/// 顶栏品牌区的排版：名字加粗，版本号是压在名字右下角的小徽标。
void main() {
  testWidgets('名字加粗，版本徽标压在名字右下角', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BrandBar(
            title: BrandTitle(name: '漫咖', version: AppInfo.versionLabel),
          ),
        ),
      ),
    );

    expect(find.text('漫咖'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    final nameWidget = tester.widget<Text>(find.text('漫咖'));
    expect(nameWidget.style?.fontWeight, FontWeight.w700);

    final name = tester.getRect(find.text('漫咖'));
    final version = tester.getRect(find.text('v1.0.0'));
    // 在右下角：垂直上压住名字的下半部，水平上从名字右边缘探出去。
    expect(version.center.dy, greaterThan(name.center.dy));
    expect(version.center.dx, greaterThan(name.center.dx));
    // 仍有一角压在名字上，不是完全飘到右边。
    expect(version.left, lessThan(name.right));
  });

  testWidgets('不传版本号时只画名称，不带徽标', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BrandBar(title: BrandTitle(name: '书架'))),
      ),
    );

    expect(find.text('书架'), findsOneWidget);
    expect(find.textContaining('v1.0.0'), findsNothing);
  });
}
