import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'browse_widgets.dart';
import 'detail_hero.dart';

/// SkeletonColors — 骨架配色，由当前 ColorScheme 推导
class SkeletonColors {
  final Color base;
  final Color highlight;

  const SkeletonColors({required this.base, required this.highlight});

  factory SkeletonColors.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = scheme.surfaceContainerHighest;
    final highlight = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
      base,
    );
    return SkeletonColors(base: base, highlight: highlight);
  }
}

/// SkeletonShimmer — 扫光容器，一条动画驱动整块骨架
class SkeletonShimmer extends StatefulWidget {
  final Widget child;

  const SkeletonShimmer({super.key, required this.child});

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统关闭动画时停在中间帧
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disabled) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkeletonColors.of(context);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-1.6 + 3.2 * t, 0),
              end: Alignment(-0.6 + 3.2 * t, 0),
              colors: [colors.base, colors.highlight, colors.base],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

/// 兼容旧调用点的名字
class Shimmer extends StatelessWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SkeletonShimmer(child: child);
}

/// 骨架底色，用于不套扫光的场景
Color skeletonColor(BuildContext context) => SkeletonColors.of(context).base;

/// 基础色块。宽高传 `double.infinity` 时铺满父级约束
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;

  /// 圆角：dp 数值或 [BorderRadius]
  final Object radius;
  final Color? color;

  const SkeletonBox({
    super.key,
    this.width = double.infinity,
    this.height = 12,
    this.radius = AppShape.xs,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkeletonColors.of(context);
    final value = radius;
    final borderRadius = value is BorderRadius
        ? value
        : BorderRadius.circular((value as num).toDouble());
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color ?? colors.base,
        borderRadius: borderRadius,
      ),
    );
  }
}

/// 文字行占位：高度按 M3 文本行高给（bodyMedium 默认12，titleMedium 16）
class SkeletonText extends StatelessWidget {
  final double width;
  final double height;
  final double radius;

  const SkeletonText({
    super.key,
    this.width = double.infinity,
    this.height = 12,
    this.radius = AppShape.xs,
  });

  @override
  Widget build(BuildContext context) => SkeletonBox(
        width: width,
        height: height,
        radius: radius,
      );
}

/// SkeletonCircle — 圆形骨架
class SkeletonCircle extends StatelessWidget {
  final double size;
  const SkeletonCircle({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) => SkeletonBox(
        width: size,
        height: size,
        radius: size / 2,
      );
}

/// 图片占位：只描述宽高比与圆角，尺寸由父级布局决定
class SkeletonImage extends StatelessWidget {
  final double aspectRatio;
  final double radius;

  const SkeletonImage({
    super.key,
    this.aspectRatio = 3 / 4,
    this.radius = kCardRadius,
  });

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: aspectRatio,
        child: SkeletonBox(height: double.infinity, radius: radius),
      );
}

/// 轮播骨架，与 [CoverCarousel] 同版式
class CarouselSkeleton extends StatelessWidget {
  final double height;

  const CarouselSkeleton({super.key, this.height = 152});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.base, AppSpacing.sm, AppSpacing.base, 0),
        child: Column(
          children: [
            SkeletonBox(
              width: double.infinity,
              height: height,
              radius: 12,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: SkeletonBox(
                    width: i == 0 ? 15 : 6,
                    height: 6,
                    radius: 6,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// SkeletonGate — 首屏骨架闸门，最短展示 minVisible 后淡入内容
class SkeletonGate extends StatefulWidget {
  final bool loading;
  final Widget skeleton;
  final Widget child;
  final Duration minVisible;

  const SkeletonGate({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.child,
    this.minVisible = const Duration(milliseconds: 350),
  });

  @override
  State<SkeletonGate> createState() => _SkeletonGateState();
}

class _SkeletonGateState extends State<SkeletonGate> {
  bool _minElapsed = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.minVisible).then((_) {
      if (!mounted) return;
      setState(() => _minElapsed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final showSkeleton = widget.loading || !_minElapsed;
    return AnimatedSwitcher(
      duration: AppMotion.medium1,
      switchInCurve: AppMotion.standard,
      switchOutCurve: AppMotion.standard,
      child: showSkeleton
          ? KeyedSubtree(
              key: const ValueKey('skeleton'), child: widget.skeleton)
          : KeyedSubtree(key: const ValueKey('content'), child: widget.child),
    );
  }
}

// 共享骨架片段

/// 网格封面卡骨架，与 [RichGridCard] 同版式
Widget mediaCardSkeleton(BuildContext context, bool shelfStyle) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: scheme.surfaceContainerLowest,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonImage(
          aspectRatio: kCardCoverAspectRatio,
          radius: 0,
        ),
        const SizedBox(height: kCardCoverTitleGap),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonText(width: double.infinity, height: 16, radius: 4),
              SizedBox(height: 4),
              SkeletonText(width: 88, height: 16, radius: 4),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 三列内容网格骨架（精选热门更新 / 轻小说 / 动画 / 书架 / 发现）
class MediaGridSkeleton extends StatelessWidget {
  final int count;
  final bool shelfStyle;
  final EdgeInsetsGeometry padding;

  /// 文字区高度，默认与完整卡片一致
  final double? textExtent;

  const MediaGridSkeleton({
    super.key,
    this.count = 6,
    this.shelfStyle = false,
    this.textExtent,
    this.padding = const EdgeInsets.fromLTRB(
        AppSpacing.base, 0, AppSpacing.base, AppSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: GridView.builder(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        gridDelegate: textExtent == null
            ? kTripleGridDelegate
            : TripleGridDelegate(textExtent: textExtent!),
        itemCount: count,
        itemBuilder: (context, i) => mediaCardSkeleton(context, shelfStyle),
      ),
    );
  }
}

/// [MediaGridSkeleton] 的 box 版本，用在 Column / SliverToBoxAdapter 里
class MediaGridBoxSkeleton extends StatelessWidget {
  final int count;
  final bool shelfStyle;

  const MediaGridBoxSkeleton({
    super.key,
    this.count = 6,
    this.shelfStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.base, 0, AppSpacing.base, AppSpacing.lg),
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        gridDelegate: kTripleGridDelegate,
        itemCount: count,
        itemBuilder: (context, i) => mediaCardSkeleton(context, shelfStyle),
      ),
    );
  }
}

/// 横滑文字 tab 行骨架
class TextTabsSkeleton extends StatelessWidget {
  final int count;
  const TextTabsSkeleton({super.key, this.count = 5});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          itemCount: count,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.lg),
          itemBuilder: (context, i) => const Center(
            child: SkeletonText(width: 56, height: 14, radius: 7),
          ),
        ),
      ),
    );
  }
}

/// 发现页整页骨架：筛选行 + 三列结果网格
class DiscoverSkeleton extends StatelessWidget {
  const DiscoverSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.sm),
        const TextTabsSkeleton(),
        const TextTabsSkeleton(count: 4),
        const SizedBox(height: AppSpacing.sm),
        MediaGridSkeleton(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.base, AppSpacing.sm, AppSpacing.base, AppSpacing.lg),
        ),
      ],
    );
  }
}

/// 排行榜列表骨架，与 [RankRow] 同尺寸
class RankListSkeleton extends StatelessWidget {
  final int count;
  const RankListSkeleton({super.key, this.count = 8});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: count,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              const SkeletonBox(width: 88, height: 122, radius: 10),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    // 标题：固定两行，第一行铺满、第二行短一截
                    SkeletonText(width: double.infinity, height: 18, radius: 4),
                    SizedBox(height: 4),
                    SkeletonText(width: 140, height: 18, radius: 4),
                    SizedBox(height: 10),
                    // 作者
                    SkeletonText(width: 96, height: 12, radius: 4),
                    SizedBox(height: 10),
                    // 热度：小圆 + 数字
                    Row(
                      children: [
                        SkeletonCircle(size: 14),
                        SizedBox(width: 4),
                        SkeletonText(width: 52, height: 12, radius: 4),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const SkeletonBox(width: 32, height: 32, radius: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页精选整页骨架：Banner + 推荐网格 + 榜单行
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          // Banner：与真实 CoverCarousel 同 padding、同高度、同圆角
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.base, AppSpacing.sm, AppSpacing.base, 0),
            child: ClipRRect(
              borderRadius: AppShape.mdRadius,
              child: const SkeletonBox(height: 152, radius: AppShape.md),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                4,
                (i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child:
                      SkeletonBox(width: i == 0 ? 12 : 6, height: 4, radius: 2),
                ),
              ),
            ),
          ),
          _sectionHeaderSkeleton(action: true),
          const MediaGridBoxSkeleton(count: 6),
          _sectionHeaderSkeleton(),
          const SizedBox(height: AppSpacing.sm),
          const RankListSkeleton(count: 3),
          _sectionHeaderSkeleton(),
          const MediaGridBoxSkeleton(count: 3),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

/// 内容频道（轻小说 / 写真 / 动画）首屏骨架
class MediaIndexSkeleton extends StatelessWidget {
  const MediaIndexSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.base, AppSpacing.sm, AppSpacing.base, 0),
            child: ClipRRect(
              borderRadius: AppShape.mdRadius,
              child: const SkeletonBox(height: 152, radius: AppShape.md),
            ),
          ),
          _sectionHeaderSkeleton(action: true),
          const MediaGridBoxSkeleton(count: 6),
          _sectionHeaderSkeleton(action: true),
          const SizedBox(height: AppSpacing.sm),
          const RankListSkeleton(count: 4),
        ],
      ),
    );
  }
}

/// 详情页首屏骨架，版式与真实详情页对齐
class ComicDetailSkeleton extends StatelessWidget {
  const ComicDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const _DetailSkeletonBody();
}

/// ContentDetailSkeleton — 内容详情页骨架
class ContentDetailSkeleton extends StatelessWidget {
  final bool hasChapterCover;
  const ContentDetailSkeleton({super.key, this.hasChapterCover = true});

  @override
  Widget build(BuildContext context) =>
      _DetailSkeletonBody(hasChapterCover: hasChapterCover);
}

/// _DetailSkeletonBody — 详情骨架的实际布局
class _DetailSkeletonBody extends StatelessWidget {
  final bool hasChapterCover;
  const _DetailSkeletonBody({this.hasChapterCover = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: AppSpacing.lg + bottomInset),
      children: [
        // 大封面方角铺满，底部压一条圆角白卡上沿
        SizedBox(
          height: kDetailHeroHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: SkeletonShimmer(
                  child: SkeletonBox(
                    width: double.infinity,
                    height: double.infinity,
                    radius: BorderRadius.zero,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: kHeroCornerRadius,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(kHeroCornerRadius),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SkeletonShimmer(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.base, AppSpacing.base, AppSpacing.base, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 作者 / 地区 / 人气：真实是一行文字
                const SkeletonText(width: 210, height: 14, radius: 4),
                const SizedBox(height: AppSpacing.base),
                // 题材 / 状态 chip 行，骨架只画一整条
                const SkeletonBox(width: 268, height: 30, radius: AppShape.sm),
                const SizedBox(height: AppSpacing.base),
                // 简介：三行，末行短一截
                const SkeletonText(height: 14, radius: 4),
                const SizedBox(height: AppSpacing.sm),
                const SkeletonText(height: 14, radius: 4),
                const SizedBox(height: AppSpacing.sm),
                const SkeletonText(width: 180, height: 14, radius: 4),
                const SizedBox(height: AppSpacing.lg),
                // 两颗大胶囊按钮（续读 / 收藏）
                Row(
                  children: const [
                    Expanded(
                      child: SkeletonBox(height: 56, radius: 28),
                    ),
                    SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: SkeletonBox(height: 56, radius: 28),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (hasChapterCover) ...[
          const SizedBox(height: AppSpacing.lg),
          SkeletonShimmer(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 章节目录 + 右侧倒序
                  Row(
                    children: const [
                      SkeletonText(width: 88, height: 20, radius: 4),
                      Spacer(),
                      SkeletonText(width: 36, height: 14, radius: 4),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    gridDelegate: kChapterGridDelegate,
                    itemCount: 12,
                    itemBuilder: (context, i) => const SkeletonBox(
                      height: 40,
                      radius: AppShape.sm,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 个人中心骨架：头像行 + 统计行 + 列表行
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.base, AppSpacing.lg,
                AppSpacing.base, AppSpacing.base),
            child: Row(
              children: const [
                SkeletonCircle(size: 56),
                SizedBox(width: AppSpacing.base),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonText(width: 120, height: 20, radius: 4),
                      SizedBox(height: AppSpacing.sm),
                      SkeletonText(width: 80, height: 12, radius: 4),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.base, vertical: AppSpacing.sm),
            child: Row(
              children: List.generate(
                3,
                (i) => const Expanded(
                  child: Column(
                    children: [
                      SkeletonText(width: 48, height: 16, radius: 4),
                      SizedBox(height: 6),
                      SkeletonText(width: 32, height: 10, radius: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(),
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.base, vertical: AppSpacing.md),
              child: Row(
                children: const [
                  SkeletonBox(width: 24, height: 24, radius: AppShape.xs),
                  SizedBox(width: AppSpacing.base),
                  SkeletonText(width: 96, height: 14, radius: 4),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 书架 / 收藏网格骨架
class BookShelfSkeleton extends StatelessWidget {
  const BookShelfSkeleton({super.key});

  @override
  Widget build(BuildContext context) =>
      const MediaGridSkeleton(shelfStyle: true);
}

/// 搜索结果骨架：搜索框 + 结果行
class SearchResultSkeleton extends StatelessWidget {
  final int count;
  const SearchResultSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.base, AppSpacing.sm,
                AppSpacing.base, AppSpacing.base),
            child: SkeletonBox(height: 56, radius: AppShape.xl),
          ),
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.base, vertical: AppSpacing.sm),
              child: Row(
                children: [
                  const SkeletonBox(width: 56, height: 75, radius: kCardRadius),
                  const SizedBox(width: AppSpacing.base),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SkeletonText(height: 16, radius: 4),
                        SizedBox(height: AppSpacing.sm),
                        SkeletonText(width: 120, height: 12, radius: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 轻小说列表骨架（列表行，而不是三列封面）
class NovelListSkeleton extends StatelessWidget {
  final int count;
  const NovelListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: Row(
            children: [
              const SkeletonBox(width: 64, height: 88, radius: kCardRadius),
              const SizedBox(width: AppSpacing.base),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SkeletonText(height: 16, radius: 4),
                    SizedBox(height: AppSpacing.sm),
                    SkeletonText(width: 140, height: 12, radius: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 评论 / 通用列表骨架：每行一个40dp 圆 + 两行文字
class TileListSkeleton extends StatelessWidget {
  final int count;
  const TileListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.base),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              SkeletonCircle(size: 40),
              SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonText(width: 96, height: 12, radius: 4),
                    SizedBox(height: AppSpacing.sm),
                    SkeletonText(height: 12, radius: 4),
                    SizedBox(height: 6),
                    SkeletonText(width: 180, height: 12, radius: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 漫画阅读器整屏骨架：铺满，不留 padding、圆角与扫光
class ReaderSkeleton extends StatelessWidget {
  const ReaderSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(
      child: SkeletonBox(height: double.infinity, radius: 0),
    );
  }
}

/// 区块标题骨架，与 [SectionHeader] 同外距
Widget _sectionHeaderSkeleton({
  double titleWidth = 96,
  bool subtitle = false,
  bool action = false,
}) {
  return Builder(
    builder: (context) {
      final colors = SkeletonColors.of(context);
      Widget box(double w, double h) => Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: colors.base,
              borderRadius: BorderRadius.circular(AppShape.xs),
            ),
          );
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.base, AppSpacing.lg, AppSpacing.base, AppSpacing.sm),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                box(titleWidth, 16),
                if (subtitle) ...[
                  const SizedBox(height: 6),
                  box(math.min(titleWidth + 40, 200), 12),
                ],
              ],
            ),
            const Spacer(),
            if (action) box(48, 14),
          ],
        ),
      );
    },
  );
}
