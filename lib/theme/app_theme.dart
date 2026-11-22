import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ContentFirstPageTransitionsBuilder — 页面转场：位移 + 恒定不透明
class ContentFirstPageTransitionsBuilder extends PageTransitionsBuilder {
  const ContentFirstPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.02),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: AppMotion.emphasizedDecelerate,
        reverseCurve: AppMotion.emphasizedAccelerate,
      )),
      child: child,
    );
  }
}

/// AppMotion — 动效 token，曲线与时长
class AppMotion {
  AppMotion._();

  /// emphasized decelerate — cubic-bezier(0.05, 0.7, 0.1, 1.0)
  static const Curve emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// emphasized accelerate — cubic-bezier(0.3, 0.0, 0.8, 0.15)
  static const Curve emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// standard — cubic-bezier(0.2, 0.0, 0.0, 1.0)
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);

  static const Duration short1 = Duration(milliseconds: 100);
  static const Duration short2 = Duration(milliseconds: 150);
  static const Duration medium1 = Duration(milliseconds: 200);
  static const Duration medium2 = Duration(milliseconds: 250);
  static const Duration long1 = Duration(milliseconds: 400);
  static const Duration long2 = Duration(milliseconds: 500);
}

/// AppShape — 形状 token（`md.sys.shape.corner.*`）
class AppShape {
  AppShape._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double button = 20;
  static const double lg = 16;
  static const double xl = 28;

  static BorderRadius get xsRadius => BorderRadius.circular(xs);
  static BorderRadius get smRadius => BorderRadius.circular(sm);
  static BorderRadius get mdRadius => BorderRadius.circular(md);
  static BorderRadius get buttonRadius => BorderRadius.circular(button);
  static BorderRadius get lgRadius => BorderRadius.circular(lg);
  static BorderRadius get xlRadius => BorderRadius.circular(xl);
  static const BorderRadius sheetTopRadius =
      BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius searchBarRadius =
      BorderRadius.all(Radius.circular(xl));
}

/// AppSpacing — 间距 token：4 的倍数，页面栅格16dp，区块之间24dp
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double base = 16;
  static const double lg = 24;
  static const double xl = 32;

  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: base);
  static const EdgeInsets pageV = EdgeInsets.fromLTRB(base, base, base, 0);
}

/// AppTheme — Material 3 主题
class AppTheme {
  AppTheme._();

  static const List<SeedPreset> seedPresets = [
    SeedPreset('晴空蓝', Color(0xFF0061A4)),
    SeedPreset('鸢尾紫', Color(0xFF6750A4)),
    SeedPreset('湖青', Color(0xFF00696D)),
    SeedPreset('珊瑚', Color(0xFF984061)),
    SeedPreset('靛蓝', Color(0xFF4355B9)),
    SeedPreset('秋栗', Color(0xFF8B5000)),
  ];

  static Color seedOf(int index) =>
      seedPresets[index.clamp(0, seedPresets.length - 1).toInt()].color;

  static ThemeData light(Color seed) => fromScheme(
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
      );

  static ThemeData dark(Color seed) => fromScheme(
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      );

  /// 动态取色入口：把系统壁纸生成的 scheme 直接交给这里
  static ThemeData fromScheme(ColorScheme scheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
    );
    final textTheme = _textTheme(base.textTheme);

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ContentFirstPageTransitionsBuilder(),
          TargetPlatform.fuchsia: ContentFirstPageTransitionsBuilder(),
          TargetPlatform.linux: ContentFirstPageTransitionsBuilder(),
          TargetPlatform.windows: ContentFirstPageTransitionsBuilder(),
          TargetPlatform.iOS: ContentFirstPageTransitionsBuilder(),
          TargetPlatform.macOS: ContentFirstPageTransitionsBuilder(),
        },
      ),
      // Top app bar：surface 容器、onSurface 前景、64dp 高、无阴影
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 3,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: 16,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 24),
        actionsIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 24),
        systemOverlayStyle: _overlayStyle(scheme),
      ),
      // Navigation bar：80dp 高，surfaceContainerHigh 底
      navigationBarTheme: NavigationBarThemeData(
        height: 80,
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
            size: 24,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          );
        }),
      ),
      // Primary tabs：surface 上的3dp primary 指示条，没有整条色带
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle: textTheme.labelLarge,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 3),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        ),
        splashBorderRadius: BorderRadius.circular(AppShape.sm),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          shape: RoundedRectangleBorder(borderRadius: AppShape.buttonRadius),
          textStyle: textTheme.labelLarge,
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          shape: RoundedRectangleBorder(borderRadius: AppShape.buttonRadius),
          textStyle: textTheme.labelLarge,
          elevation: 1,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          shape: RoundedRectangleBorder(borderRadius: AppShape.buttonRadius),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          shape: RoundedRectangleBorder(borderRadius: AppShape.buttonRadius),
          textStyle: textTheme.labelLarge,
          foregroundColor: scheme.primary,
        ),
      ),
      // 不写死 foregroundColor，避免盖掉 filled 按钮的前景
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          iconSize: 24,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 2,
        highlightElevation: 2,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(borderRadius: AppShape.lgRadius),
      ),
      // Filled card：surfaceContainerLowest 压在 surface 页面上
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
      ),
      // Chip / Tag：无边框胶囊
      chipTheme: ChipThemeData(
        backgroundColor: Color.alphaBlend(
            scheme.onSurface.withValues(alpha: 0.08), scheme.surface),
        selectedColor: scheme.primary,
        disabledColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        labelStyle: textTheme.labelMedium?.copyWith(color: scheme.onSurface),
        secondaryLabelStyle:
            textTheme.labelMedium?.copyWith(color: scheme.onPrimary),
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
        // 胶囊比默认 M3 chip 再小一档：labelMedium + 更窄的左右留白
        shape: const StadiumBorder(),
        side: BorderSide.none,
        showCheckmark: true,
        checkmarkColor: scheme.onPrimary,
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      ),
      // List item：标题 bodyLarge、副标题 bodyMedium，左右16dp
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: textTheme.bodyLarge?.copyWith(color: scheme.onSurface),
        subtitleTextStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        minVerticalPadding: AppSpacing.xs,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
        shape: const RoundedRectangleBorder(),
      ),
      // Filled text field：4dp 圆角、surfaceContainerHighest 底
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide.none,
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide(color: scheme.primary, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppShape.xsRadius,
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.base, vertical: 16),
        hintStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        labelStyle:
            textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      // Alert dialog：28dp 圆角、surfaceContainerHigh
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: AppShape.xlRadius),
        titleTextStyle: textTheme.headlineSmall?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      // Modal bottom sheet：28dp 顶部圆角、surfaceContainerLow、拖拽条
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        modalElevation: 0,
        shape:
            const RoundedRectangleBorder(borderRadius: AppShape.sheetTopRadius),
        clipBehavior: Clip.antiAlias,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
        textStyle: textTheme.bodyLarge,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(AppShape.xs),
        ),
        textStyle:
            textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
        insetPadding: const EdgeInsets.all(AppSpacing.base),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
      ),
    );
  }

  static SystemUiOverlayStyle _overlayStyle(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    );
  }

  /// M3 2021 字体阶梯：字号 / 行高 / 字重严格按 token
  static TextTheme _textTheme(TextTheme base) {
    TextStyle? s(
      TextStyle? style, {
      required FontWeight weight,
      required double height,
      double? size,
    }) {
      return style?.copyWith(
        fontWeight: weight,
        height: height,
        fontSize: size,
        letterSpacing: 0,
        fontFamilyFallback: const [
          'Roboto',
          'Noto Sans SC',
          'Source Han Sans SC',
          'PingFang SC',
          'Microsoft YaHei',
        ],
      );
    }

    return base.copyWith(
      displayLarge: s(base.displayLarge, weight: FontWeight.w400, height: 1.12),
      displayMedium:
          s(base.displayMedium, weight: FontWeight.w400, height: 1.16),
      displaySmall: s(base.displaySmall, weight: FontWeight.w400, height: 1.22),
      headlineLarge:
          s(base.headlineLarge, weight: FontWeight.w400, height: 1.25),
      headlineMedium:
          s(base.headlineMedium, weight: FontWeight.w400, height: 1.29),
      headlineSmall:
          s(base.headlineSmall, weight: FontWeight.w400, height: 1.33),
      titleLarge: s(base.titleLarge, weight: FontWeight.w400, height: 1.27),
      titleMedium: s(base.titleMedium, weight: FontWeight.w500, height: 1.5),
      titleSmall: s(base.titleSmall, weight: FontWeight.w500, height: 1.43),
      bodyLarge: s(base.bodyLarge, weight: FontWeight.w400, height: 1.5),
      bodyMedium: s(base.bodyMedium, weight: FontWeight.w400, height: 1.43),
      bodySmall: s(base.bodySmall, weight: FontWeight.w400, height: 1.33),
      labelLarge: s(base.labelLarge, weight: FontWeight.w500, height: 1.43),
      labelMedium: s(base.labelMedium, weight: FontWeight.w500, height: 1.33),
      labelSmall: s(base.labelSmall, weight: FontWeight.w500, height: 1.45),
    );
  }
}

/// AppScrollBehavior — 鼠标也能按住拖动滚动
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      };
}

/// SeedPreset — 主题种子色预设
class SeedPreset {
  final String label;
  final Color color;
  const SeedPreset(this.label, this.color);
}
