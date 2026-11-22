import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/comic.dart';
import 'comic_card.dart';

/// 详情页头图高度，四个详情页与骨架屏共用
const double kDetailHeroHeight = 320;

/// 书名离头图底边的距离：展开30，收起18
const double _kExpandedTitleGap = 30;
const double _kCollapsedTitleGap = 18;

/// 收起后的书名字号，与导航栏标题一致
const double _kTitleFontSize = 16;

/// 展开时的书名字号倍数，16 × 1.6 = 25.6
const double kExpandedTitleScale = 1.6;

/// 书名右侧留白，给顶栏按钮与角标让位
const double _kTitleRightInset = 84;

/// 头图下沿的圆角
const double kHeroCornerRadius = 24;

const SystemUiOverlayStyle _lightStatusBar = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

const SystemUiOverlayStyle _darkStatusBar = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

double _lerp(double begin, double end, double t) => begin + (end - begin) * t;

/// 0 → 还是头图（下沿圆角24）；1 → 已经收进顶栏（方角）
double _collapseToSquare(double t) => ((t - 0.55) / 0.45).clamp(0.0, 1.0);

/// DetailHeroBar — 四个详情页共用的沉浸式头图，书名随折叠收进顶栏
class DetailHeroBar extends StatelessWidget {
  const DetailHeroBar({
    super.key,
    required this.comic,
    required this.title,
    required this.collapse,
    this.actions = const [],
    this.expandedHeight = kDetailHeroHeight,
  });

  final Comic comic;

  /// 压在头图上的书名，也是收进导航栏后的书名
  final String title;

  /// 0 = 完全展开，1 = 完全折叠
  final double collapse;

  final List<Widget> actions;
  final double expandedHeight;

  /// 把滚动 offset 换成 [collapse]：0 完全展开，1 完全折叠
  static double collapseOf(
      double offset, double expandedHeight, double topPadding) {
    final span = expandedHeight - kToolbarHeight - topPadding;
    if (span <= 0) return 1;
    return (offset / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final t = collapse.clamp(0.0, 1.0);

    // 标题 bottom 按 flexibleSpace 剩余高度量：展开贴底30，收起离底18
    final titleGap = _lerp(_kExpandedTitleGap, _kCollapsedTitleGap, t);
    final titleScale = _lerp(kExpandedTitleScale, 1, t);
    final titleLeft = _lerp(16, 56, t);
    // 展开时整行都能用，快收进顶栏了才把右边让给 actions
    final titleRight = _lerp(16, _kTitleRightInset, t);
    // 布局宽度按缩放后的可视宽度给，超出的书名在放大前就省略
    final titleWidth = (screenWidth - titleLeft - titleRight) / titleScale;

    // 字重随折叠过渡
    final titleWeight =
        FontWeight.lerp(FontWeight.w500, FontWeight.w500, t) ?? FontWeight.w500;

    // 白色内容区上沿的圆角高度：展开24，随折叠收到0
    final lip = kHeroCornerRadius * (1 - _collapseToSquare(t));

    // 白字 → onSurface，收好后是深色标题
    final titleColor = Color.lerp(
      Colors.white,
      scheme.onSurface,
      ((t - 0.70) / 0.22).clamp(0.0, 1.0),
    )!;
    final titleShadow = 1 - ((t - 0.66) / 0.24).clamp(0.0, 1.0);
    // 顶栏图标同理：压在图上用白色，收到页面底色上换成 onSurface
    final iconColor = Color.lerp(
      Colors.white,
      scheme.onSurface,
      ((t - 0.60) / 0.35).clamp(0.0, 1.0),
    )!;

    // 头图上的图标统一挂在40dp 深色圆底上，浅色封面也看得清
    Widget chrome(Widget child) => IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              // 前景色必须一起给，否则全局 iconButtonTheme 会把白色图标染成深色
              foregroundColor: iconColor,
              backgroundColor: Colors.black.withValues(alpha: 0.34 * (1 - t)),
              shape: const CircleBorder(),
              minimumSize: const Size(40, 40),
              fixedSize: const Size(40, 40),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          child: child,
        );

    return SliverAppBar(
      pinned: true,
      expandedHeight: expandedHeight,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: iconColor),
      systemOverlayStyle: t < 0.85 ? _lightStatusBar : _darkStatusBar,
      leading: Navigator.of(context).canPop()
          ? Center(child: chrome(const BackButton()))
          : null,
      actions: [
        for (final action in actions)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: chrome(action),
          ),
        const SizedBox(width: 8),
      ],
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          // 大图交给 FlexibleSpaceBar：自带 parallax，收到底时会自己淡出成顶栏底色
          FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: _background(context, t),
          ),
          // 收口：白色内容区上沿做成圆角朝下，压在图片下沿，随折叠收掉
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: lip,
            child: IgnorePointer(
              child: lip <= 0
                  ? const SizedBox.shrink()
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(lip),
                        ),
                      ),
                    ),
            ),
          ),
          // 全程唯一的书名：一直可见，滚多少走多少
          Positioned(
            left: titleLeft,
            bottom: titleGap,
            width: titleWidth,
            child: Transform.scale(
              scale: titleScale,
              alignment: AlignmentDirectional.bottomStart,
              child: _HeroTitle(
                title: title,
                color: titleColor,
                shadow: titleShadow,
                weight: titleWeight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _background(BuildContext context, double t) {
    final scheme = Theme.of(context).colorScheme;
    // 大图洗白比 FlexibleSpaceBar 自带的淡出稍早，给标题留出换色时间
    final wash = ((t - 0.58) / 0.30).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 封面按宽度铺满取上半段，避免裁进封面下半段的大字书名
        CoverImage(
          comic: comic,
          width: double.infinity,
          height: double.infinity,
          radius: BorderRadius.zero,
          alignment: Alignment.topCenter,
        ),
        // 顶部压暗：白色状态栏 / 返回箭头压在浅色封面上也看得清
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.42),
                Colors.black.withValues(alpha: 0.16),
                Colors.transparent,
              ],
              stops: const [0, 0.12, 0.40],
            ),
          ),
        ),
        // 底部压暗给白字书名稳定底色，这一段挂在头图盒子底部
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0.82),
              ],
              stops: const [0.32, 0.62, 1],
            ),
          ),
        ),
        // 折叠越深越接近页面底色
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: 0.95 * wash),
            ),
          ),
        ),
      ],
    );
  }
}

/// _HeroTitle — 压在头图上的书名，字号固定，超出省略
class _HeroTitle extends StatelessWidget {
  const _HeroTitle({
    required this.title,
    required this.color,
    required this.shadow,
    required this.weight,
  });

  final String title;

  /// 白色（压在图 / 深色遮罩上）→ onSurface（收进浅色顶栏）
  final Color color;

  /// 投影强度：白字阶段靠它压住浅色封面，收进顶栏后收掉
  final double shadow;

  /// 800（图上大字）→ 700（顶栏标题）
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: _kTitleFontSize,
        height: 1.2,
        fontWeight: weight,
        color: color,
        shadows: shadow <= 0
            ? null
            : [
                Shadow(
                  blurRadius: 12,
                  color: Colors.black.withValues(alpha: 0.54 * shadow),
                  offset: const Offset(0, 2),
                ),
                Shadow(
                  blurRadius: 3,
                  color: Colors.black.withValues(alpha: 0.87 * shadow),
                ),
              ],
      ),
    );
  }
}
