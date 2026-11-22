/// 浏览页公共 MD3 组件：轮播、筛选、排序、榜单、专题、三列网格卡片
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/comic.dart';
import '../models/sort_spec.dart';
import '../services/image_url.dart';
import '../theme/app_theme.dart';
import 'net_image.dart';

/// CarouselSlide — 轮播的一帧数据
class CarouselSlide {
  final String title;
  final String? imageUrl;
  final String? subtitle;
  final VoidCallback? onTap;

  const CarouselSlide({
    required this.title,
    this.imageUrl,
    this.subtitle,
    this.onTap,
  });
}

/// _CoverImage — 统一封面渲染，URL 为空时给占位
class _CoverImage extends StatelessWidget {
  final String? url;
  final double? width;
  final double? height;
  final Alignment alignment;

  const _CoverImage({
    required this.url,
    this.width,
    this.height,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 22,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
    if (url != null && url!.isNotEmpty) {
      return NetImage(
        url: url!,
        width: width,
        height: height,
        alignment: alignment,
        errorBuilder: (_) => placeholder,
      );
    }
    return SizedBox(width: width, height: height, child: placeholder);
  }
}

/// CoverCarousel — 大图轮播，自动播放 + 首尾克隆无缝循环
class CoverCarousel extends StatefulWidget {
  final List<CarouselSlide> slides;
  final double height;
  final bool showArrows;

  /// 自动播放间隔，[Duration.zero] 关闭自动播放
  final Duration autoPlayInterval;

  const CoverCarousel({
    super.key,
    required this.slides,
    this.height = 152,
    this.showArrows = false,
    this.autoPlayInterval = const Duration(seconds: 4),
  });

  @override
  State<CoverCarousel> createState() => _CoverCarouselState();
}

class _CoverCarouselState extends State<CoverCarousel>
    with WidgetsBindingObserver {
  static const Duration _slideTransition = Duration(milliseconds: 280);

  PageController? _controller;
  Timer? _timer;

  /// 当前展示帧在 `widget.slides` 里的下标（0 起）
  int _index = 0;

  /// PageView 当前物理页，首尾各有一张克隆帧
  /// 0 = 末帧克隆，1…n = 真实帧，n+1 = 首帧克隆
  int _page = 1;

  bool _dragging = false;
  bool _autoPlayEnabled = true;
  bool _resumed = true;

  int get _count => widget.slides.length;
  bool get _looping => _count > 1;
  int get _initialPage => _looping ? 1 : 0;
  int get _itemCount => _looping ? _count + 2 : _count;

  /// 物理页 → 真实帧下标
  int _slideAt(int page) {
    final n = _count;
    if (!_looping) return 0;
    return (page - 1 + n) % n;
  }

  @override
  void initState() {
    super.initState();
    _page = _initialPage;
    _controller = PageController(initialPage: _page);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面被 IndexedStack 静音或系统关闭动画时不自动翻页
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final animationsOff =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final enabled = tickerEnabled && !animationsOff;
    if (enabled != _autoPlayEnabled) {
      _autoPlayEnabled = enabled;
    }
    // 首次挂载时上面不会触发，这里无条件起一次定时器
    _armAutoPlay();
  }

  @override
  void didUpdateWidget(CoverCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final n = _count;
    if (oldWidget.slides.length != n) {
      _dragging = false;
      final target = _looping ? 1 : 0;
      _page = target;
      _index = _slideAt(target);
      // 帧数变了旧物理页可能越界，等这一帧布局完成再跳
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final controller = _controller;
        if (controller == null || !controller.hasClients) return;
        controller.jumpToPage(target);
        _armAutoPlay();
      });
    } else if (n > 0) {
      _index = _slideAt(_page);
    }
    // 只有间隔变化才重排定时器，避免父级重建不断推迟自动播放
    if (oldWidget.autoPlayInterval != widget.autoPlayInterval) {
      _armAutoPlay();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    _armAutoPlay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  bool get _shouldAutoPlay =>
      widget.autoPlayInterval > Duration.zero &&
      _count > 1 &&
      _autoPlayEnabled &&
      _resumed &&
      !_dragging;

  /// 从当前时刻重新计时
  void _armAutoPlay() {
    _timer?.cancel();
    _timer = null;
    if (!_shouldAutoPlay) return;
    _timer = Timer(widget.autoPlayInterval, _autoAdvance);
  }

  void _autoAdvance() {
    _timer = null;
    if (!mounted || !_shouldAutoPlay) return;
    final controller = _controller;
    if (controller == null || !controller.hasClients) {
      _armAutoPlay();
      return;
    }
    // _page 落在1…n，加1 最多到 n+1 首帧克隆，永远有下一页
    controller.animateToPage(
      _page + 1,
      duration: _slideTransition,
      curve: Curves.easeOut,
    );
    _armAutoPlay();
  }

  /// 翻到首尾克隆帧后，在同一帧内无动画跳回真实帧
  void _normalizeLoopPage(int page) {
    if (!_looping) return;
    if (page == 0) {
      _jumpAfterFrame(_count);
    } else if (page == _count + 1) {
      _jumpAfterFrame(1);
    }
  }

  void _jumpAfterFrame(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_looping) return;
      final controller = _controller;
      if (controller == null || !controller.hasClients) return;
      controller.jumpToPage(page);
      _page = page;
      _index = _slideAt(page);
    });
  }

  void _handlePageChanged(int page) {
    if (!mounted) return;
    _page = page;
    _index = _slideAt(page);
    setState(() {});
    _normalizeLoopPage(page);
  }

  /// 手指拖动时暂停自动播放，松手后重新计时
  bool _handleScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _timer?.cancel();
      _timer = null;
    } else if (notification is ScrollEndNotification && _dragging) {
      _dragging = false;
      _armAutoPlay();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slides = widget.slides;
    if (slides.isEmpty) return const SizedBox.shrink();
    final active = _index.clamp(0, slides.length - 1);

    return Padding(
      // 横幅收进16dp 栅格并做圆角，顶部留8dp
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: AppShape.mdRadius,
            child: SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: _handleScroll,
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: _itemCount,
                      onPageChanged: _handlePageChanged,
                      itemBuilder: (context, page) {
                        final slide = slides[_slideAt(page)];
                        return GestureDetector(
                          onTap: slide.onTap,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _CoverImage(
                                url: slide.imageUrl,
                                // 横幅从顶部裁切，避免把封面自带的大标题裁进标题条
                                alignment: Alignment.topCenter,
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                      AppSpacing.base,
                                      AppSpacing.lg,
                                      AppSpacing.base,
                                      AppSpacing.md),
                                  decoration: BoxDecoration(
                                    // 文字背后压一层短渐变保证可读
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: 0),
                                        Colors.black.withValues(alpha: 0.55),
                                      ],
                                    ),
                                  ),
                                  child: Text(
                                    slide.subtitle == null ||
                                            slide.subtitle == slide.title
                                        ? slide.title
                                        : '${slide.title}  ·  ${slide.subtitle}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(slides.length, (i) {
              final selected = i == active;
              return AnimatedContainer(
                duration: AppMotion.medium1,
                curve: AppMotion.standard,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: selected ? 12 : 6,
                height: 4,
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

/// TextTabRow — 纯文字筛选行，expand 时均分整行，否则横向滚动
class TextTabRow extends StatelessWidget {
  final List<String> labels;
  final String value;
  final ValueChanged<String> onChanged;
  final bool expand;

  const TextTabRow({
    super.key,
    required this.labels,
    required this.value,
    required this.onChanged,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget item(String label) {
      final selected = label == value;
      return InkWell(
        onTap: () => onChanged(label),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: expand ? 6 : 10,
            vertical: 9,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      );
    }

    if (expand) {
      return Row(
        children:
            labels.map((l) => Expanded(child: Center(child: item(l)))).toList(),
      );
    }
    return SizedBox(
      height: 42,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        scrollDirection: Axis.horizontal,
        itemCount: labels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 2),
        itemBuilder: (context, i) => Center(child: item(labels[i])),
      ),
    );
  }
}

/// SortBar — 两颗胶囊切换排序维度，点已选中的那颗翻转方向
class SortBar extends StatelessWidget {
  final SortField field;
  final bool desc;
  final void Function(SortField field, bool desc) onChanged;
  final String dateLabel;
  final String popularLabel;

  const SortBar({
    super.key,
    required this.field,
    required this.desc,
    required this.onChanged,
    this.dateLabel = '更新时间',
    this.popularLabel = '热度',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    IconData directionIcon(bool descending) =>
        descending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded;

    Widget pill({
      required SortField sortField,
      required String label,
      required IconData icon,
    }) {
      final active = field == sortField;
      // 未选中时按默认的降序提示，选中后才是当前真实方向
      final descending = active ? desc : true;
      final foreground = active ? scheme.onPrimary : scheme.onSurfaceVariant;
      return ChoiceChip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: Icon(icon, size: 18, color: foreground),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            // 热度那颗只有火苗图标，靠尾部箭头提示方向
            if (active && sortField == SortField.popular) ...[
              const SizedBox(width: 2),
              Icon(directionIcon(descending), size: 14, color: foreground),
            ],
          ],
        ),
        selected: active,
        showCheckmark: false,
        tooltip: active
            ? '$label · ${descending ? '降序' : '升序'}（再点一下切换）'
            : '$label · 按${descending ? '降序' : '升序'}排列',
        onSelected: (_) => onChanged(sortField, active ? !desc : true),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.base, AppSpacing.xs, AppSpacing.base, AppSpacing.xs),
      child: Row(
        children: [
          pill(
            sortField: SortField.date,
            label: dateLabel,
            icon: directionIcon(field == SortField.date ? desc : true),
          ),
          const SizedBox(width: AppSpacing.sm),
          pill(
            sortField: SortField.popular,
            label: popularLabel,
            icon: Icons.local_fire_department_outlined,
          ),
        ],
      ),
    );
  }
}

/// RankBadge — 榜单名次徽章，前三名实心高对比色块
class RankBadge extends StatelessWidget {
  final int rank;

  const RankBadge({super.key, required this.rank});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top3 = rank <= 3;
    final Color background = switch (rank) {
      1 => scheme.tertiary,
      2 => scheme.primary,
      3 => scheme.secondary,
      _ => scheme.surfaceContainerHighest,
    };
    final Color foreground = switch (rank) {
      1 => scheme.onTertiary,
      2 => scheme.onPrimary,
      3 => scheme.onSecondary,
      _ => scheme.onSurface,
    };
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: top3 ? null : Border.all(color: scheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: Text(
        '$rank',
        style: TextStyle(
          fontSize: top3 ? 15 : 13,
          fontWeight: FontWeight.w500,
          color: foreground,
          height: 1,
        ),
      ),
    );
  }
}

/// RankRow — 榜单条目：左封面 + 标题 / 作者 / 热度 + 右侧名次徽章
class RankRow extends StatelessWidget {
  final int rank;
  final String title;
  final String author;
  final String popular;
  final String? coverUrl;
  final VoidCallback onTap;

  const RankRow({
    super.key,
    required this.rank,
    required this.title,
    required this.author,
    required this.popular,
    required this.onTap,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _CoverImage(
                url: coverUrl,
                width: 88,
                height: 122,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.whatshot_rounded,
                          size: 14, color: scheme.tertiary),
                      const SizedBox(width: 4),
                      Text(
                        popular,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            RankBadge(rank: rank),
          ],
        ),
      ),
    );
  }
}

/// TopicSlide — 专题横滑卡片的数据
class TopicSlide {
  final String title;
  final String? imageUrl;
  final String? badge;

  const TopicSlide({
    required this.title,
    this.imageUrl,
    this.badge,
  });
}

/// TopicStrip — 专题横向卡片，左下角可选角标，底部标题条
class TopicStrip extends StatelessWidget {
  final List<TopicSlide> slides;
  final VoidCallback? onTap;

  /// 逐张卡的点击回调（优先于 [onTap]）
  final ValueChanged<int>? onSlideTap;

  /// 卡片高度，为0 时按2.5:1 由卡片宽度推出
  final double height;

  const TopicStrip({
    super.key,
    required this.slides,
    this.onTap,
    this.onSlideTap,
    this.height = 0,
  });

  @override
  Widget build(BuildContext context) {
    // 空数据不渲染
    if (slides.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 卡片宽约屏宽60%，高度按2.5:1 由宽度推出
        final width = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * 0.6).clamp(180.0, 360.0)
            : 220.0;
        final cardHeight = height > 0 ? height : width / 2.5;
        return SizedBox(
          height: cardHeight,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: slides.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final slide = slides[i];
              return InkWell(
                onTap: onSlideTap != null ? () => onSlideTap!(i) : onTap,
                borderRadius: BorderRadius.circular(12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: width,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _CoverImage(url: slide.imageUrl),
                        // 底部半透明黑条 + 左对齐单行标题
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.centerLeft,
                            color: Colors.black.withValues(alpha: 0.55),
                            child: Text(
                              slide.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 三列卡片统一度量：封面3:4、标题固定2 行、副信息各1 行
const double kCardCoverAspectRatio = 3 / 4; // 宽 / 高
const double kCardRadius = 12;
const double kCardCoverTitleGap = 7;
const double kCardTitleHeight = 36; // 2 行 × 17.5，留 1px 余量
const double kCardTitleAuthorGap = 3;
const double kCardAuthorHeight = 16;
const double kCardAuthorPopularGap = 4;
const double kCardPopularHeight = 16;
const double kCardPopularDateGap = 2;
const double kCardDateHeight = 14;
const double kCardBottomPadding = 8;
const double kCardTextExtent = kCardCoverTitleGap +
    kCardTitleHeight +
    kCardTitleAuthorGap +
    kCardAuthorHeight +
    kCardAuthorPopularGap +
    kCardPopularHeight +
    kCardPopularDateGap +
    kCardDateHeight +
    kCardBottomPadding;

/// RichGridCard — 三列网格卡片：封面 + 两行标题 + 作者 + 热度 + 日期
class RichGridCard extends StatelessWidget {
  final String title;
  final String author;
  final String? popular;
  final String? date;
  final String? coverUrl;
  final String? badge;
  final VoidCallback onTap;

  const RichGridCard({
    super.key,
    required this.title,
    required this.author,
    required this.onTap,
    this.coverUrl,
    this.popular,
    this.date,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // M3 Card 承载封面与文字，前景 InkWell 铺满整张卡做按压高亮
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(kCardRadius)),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: kCardCoverAspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // BoxFit.cover 把任意源图比例裁切成统一尺寸
                    _CoverImage(url: coverUrl),
                    if (badge != null)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(10, 0, 10, kCardBottomPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: kCardCoverTitleGap),
                    // 固定2 行高度：单行标题也占满
                    SizedBox(
                      height: kCardTitleHeight,
                      width: double.infinity,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                          height: 1.25,
                        ),
                      ),
                    ),
                    // 没有作者就不占行高
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: kCardTitleAuthorGap),
                      SizedBox(
                        height: kCardAuthorHeight,
                        width: double.infinity,
                        child: Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant, fontSize: 11),
                        ),
                      ),
                    ],
                    const SizedBox(height: kCardAuthorPopularGap),
                    // 热度行始终占位，缺失时留空，避免行高随数据变化
                    SizedBox(
                      height: kCardPopularHeight,
                      width: double.infinity,
                      child: popular == null
                          ? null
                          : Row(
                              children: [
                                Icon(Icons.whatshot_rounded,
                                    size: 13, color: scheme.tertiary),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    popular!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    // 没有日期就不占行高
                    if (date != null && date!.isNotEmpty) ...[
                      const SizedBox(height: kCardPopularDateGap),
                      SizedBox(
                        height: kCardDateHeight,
                        width: double.infinity,
                        child: Text(
                          date!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.outline, fontSize: 10),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // 前景状态层：铺满整张卡，高亮覆盖图片和文字
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kCardRadius),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TripleGridDelegate — 三列网格统一间距与行高
class TripleGridDelegate extends SliverGridDelegate {
  /// 文字区高度，默认是完整卡片
  final double textExtent;

  const TripleGridDelegate({this.textExtent = kCardTextExtent});

  static const int crossAxisCount = 3;
  static const double mainAxisSpacing = 16;
  static const double crossAxisSpacing = 12;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final childCrossExtent = (constraints.crossAxisExtent -
            crossAxisSpacing * (crossAxisCount - 1)) /
        crossAxisCount;
    final childMainExtent =
        childCrossExtent / kCardCoverAspectRatio + textExtent;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMainExtent + mainAxisSpacing,
      crossAxisStride: childCrossExtent + crossAxisSpacing,
      childMainAxisExtent: childMainExtent,
      childCrossAxisExtent: childCrossExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(TripleGridDelegate oldDelegate) =>
      oldDelegate.textExtent != textExtent;
}

/// 三列网格统一间距，避免各页面各写一套
const SliverGridDelegate kTripleGridDelegate = TripleGridDelegate();

/// 无日期行的网格度量：扣掉日期行间距与高度
const double kCardTextExtentNoDate =
    kCardTextExtent - kCardPopularDateGap - kCardDateHeight;

const SliverGridDelegate kTripleGridDelegateNoDate =
    TripleGridDelegate(textExtent: kCardTextExtentNoDate);

/// 章节目录网格：固定4 列等宽，格子放章节名
const SliverGridDelegateWithFixedCrossAxisCount kChapterGridDelegate =
    SliverGridDelegateWithFixedCrossAxisCount(
  crossAxisCount: 4,
  mainAxisSpacing: 10,
  crossAxisSpacing: 8,
  childAspectRatio: 2.2,
);

/// MoreActions — 更多 / 换一批双按钮
class MoreActions extends StatelessWidget {
  final String moreLabel;
  final VoidCallback? onMore;
  final String? shuffleLabel;
  final VoidCallback? onShuffle;

  /// 换一批请求进行中：按钮禁用并显示进度圈
  final bool shuffling;

  const MoreActions({
    super.key,
    required this.moreLabel,
    required this.onMore,
    this.shuffleLabel,
    this.onShuffle,
    this.shuffling = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: _MoreActionButton(
              icon: Icons.menu_rounded,
              label: moreLabel,
              onPressed: onMore,
            ),
          ),
          if (shuffleLabel != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: _MoreActionButton(
                icon: Icons.autorenew_rounded,
                label: shuffleLabel!,
                onPressed: shuffling ? null : onShuffle,
                loading: shuffling,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// _MoreActionButton — 更多操作里的图标按钮
class _MoreActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const _MoreActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final color = scheme.primary;
    return SizedBox(
      height: 46,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          backgroundColor:
              enabled ? scheme.surface : scheme.surfaceContainerHighest,
          side: BorderSide(
            color:
                enabled ? color.withValues(alpha: 0.4) : scheme.outlineVariant,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: color.withValues(alpha: 0.5),
                ),
              )
            else
              Icon(icon, size: 18),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// RecommendRow — 推荐位横排三卡，batch 每 +1 轮转3 张
class RecommendRow extends StatelessWidget {
  final List<Comic> pool;
  final int batch;
  final String? host;
  final ValueChanged<Comic> onTap;

  /// 动画推荐卡只有标题 / 热度 / 日期，不占作者行
  final bool showAuthor;
  final bool showDate;

  const RecommendRow({
    super.key,
    required this.pool,
    required this.batch,
    required this.onTap,
    this.host,
    this.showAuthor = true,
    this.showDate = false,
  });

  @override
  Widget build(BuildContext context) {
    if (pool.isEmpty) return const SizedBox.shrink();
    final count = pool.length < 3 ? pool.length : 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final width = (constraints.maxWidth - 32 - gap * (count - 1)) / count;
        Widget card(int i) {
          final comic = pool[(batch * 3 + i) % pool.length];
          return SizedBox(
            width: width,
            child: RichGridCard(
              title: comic.name,
              author: showAuthor ? comic.authorLabel : '',
              coverUrl: resolveImageUrl(comic.cover ?? '', host: host),
              popular: comic.popularLabel,
              date: showDate && comic.updatedAt.length >= 10
                  ? comic.updatedAt.substring(0, 10)
                  : null,
              onTap: () => onTap(comic),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                card(i),
              ],
            ],
          ),
        );
      },
    );
  }
}
