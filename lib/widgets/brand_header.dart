import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// BrandBarScrollScope — 一级页面滚动状态，顶栏据此切换毛玻璃
class BrandBarScrollScope extends InheritedNotifier<ValueNotifier<bool>> {
  const BrandBarScrollScope({
    super.key,
    required ValueNotifier<bool> scrolled,
    required super.child,
  }) : super(notifier: scrolled);

  static bool scrolledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BrandBarScrollScope>()
          ?.notifier
          ?.value ??
      false;
}

/// BrandBar — M3 Top app bar 封装，可带搜索框与 Tab
class BrandBar extends StatelessWidget {
  final Widget? leading;
  final Widget title;
  final Widget? search;
  final List<Widget> actions;
  final Widget? bottom;

  /// 标题行高度，M3 small top app bar 为64dp
  final double height;

  /// 玻璃层底部是否画发丝线
  final bool glassBorder;

  /// 是否自带玻璃层，页面用 [BrandGlassPanel] 包整块时传 false
  final bool glass;

  const BrandBar({
    super.key,
    this.leading,
    required this.title,
    this.search,
    this.actions = const [],
    this.bottom,
    this.height = 64,
    this.glassBorder = true,
    this.glass = true,
  });

  @override
  Widget build(BuildContext context) {
    final searchHeight = search == null ? 0.0 : 48.0 + AppSpacing.sm;
    final bottomHeight = (bottom == null ? 0.0 : 48.0) + searchHeight;
    // AppBar 在无界高度里无法自测高度，这里给它一个确定的盒子
    final topInset = MediaQuery.paddingOf(context).top;
    // 被 push 的页面自动补返回键：按 route.isFirst 判断，canPop() 在转场期间会误判
    final route = ModalRoute.of(context);
    final effectiveLeading = leading ??
        ((route == null || route.isFirst)
            ? null
            : BrandBackButton(onPressed: () => Navigator.of(context).pop()));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 未滚动时不透明，离开顶部后切半透明毛玻璃 + 发丝线
    final scrolled = BrandBarScrollScope.scrolledOf(context);
    return SizedBox(
      height: topInset + height + bottomHeight,
      child: Stack(
        children: [
          if (scrolled && glass)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 玻璃层用最浅的 surfaceContainerLowest 压到62%，底图透过模糊露出
                      color:
                          scheme.surfaceContainerLowest.withValues(alpha: 0.62),
                      border: glassBorder
                          ? Border(
                              bottom: BorderSide(
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.5),
                                width: 0.5,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: AppBar(
              primary: false,
              toolbarHeight: height,
              backgroundColor:
                  (scrolled || !glass) ? Colors.transparent : scheme.surface,
              scrolledUnderElevation: 0,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              leading: effectiveLeading,
              titleSpacing: effectiveLeading == null ? AppSpacing.base : 0,
              title: title,
              actions: actions,
              bottom: bottomHeight == 0
                  ? null
                  : PreferredSize(
                      preferredSize: Size.fromHeight(bottomHeight),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (search != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  AppSpacing.base,
                                  0,
                                  AppSpacing.base,
                                  AppSpacing.sm),
                              child: search!,
                            ),
                          if (bottom != null) bottom!,
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// BrandGlassPanel — 与顶栏同一套玻璃规格的固定区域
class BrandGlassPanel extends StatelessWidget {
  final Widget child;
  final bool border;

  const BrandGlassPanel({
    super.key,
    required this.child,
    this.border = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scrolled = BrandBarScrollScope.scrolledOf(context);
    if (!scrolled) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: border
              ? Border(
                  bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                    width: 0.5,
                  ),
                )
              : null,
        ),
        child: child,
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest.withValues(alpha: 0.62),
                  border: border
                      ? Border(
                          bottom: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                            width: 0.5,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 顶栏返回键：M3 标准48dp 热区、24dp `arrow_back`
class BrandBackButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String tooltip;

  const BrandBackButton(
      {super.key, required this.onPressed, this.tooltip = '返回'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.arrow_back),
      iconSize: 24,
      color: Theme.of(context).colorScheme.onSurface,
    );
  }
}

/// BrandTitle — 顶栏品牌名，版本号做成右下角小徽标
class BrandTitle extends StatelessWidget {
  final String name;
  final String? version;

  const BrandTitle({super.key, required this.name, this.version});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: theme.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    );
    if (version == null) return title;
    // 右侧 / 下侧留白是徽标落脚位，徽标只有一角压在名称上
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 34, bottom: 2),
          child: title,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: _VersionBadge(label: version!),
        ),
      ],
    );
  }
}

/// _VersionBadge — 压在名称右下角的版本胶囊
class _VersionBadge extends StatelessWidget {
  final String label;

  const _VersionBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onPrimary,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

/// BrandSearchField — SearchBar 封装，48dp 高、24dp 圆角
class BrandSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;
  final TextEditingController? controller;

  const BrandSearchField({
    super.key,
    this.hint = '搜索',
    this.onSubmitted,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bar = SearchBar(
      controller: controller,
      hintText: hint,
      leading: Icon(Icons.search, color: scheme.onSurfaceVariant, size: 22),
      elevation: const WidgetStatePropertyAll(0),
      // 比页面底色深一档的 tonal 填充，不描边也能看出边界
      backgroundColor: WidgetStatePropertyAll(
        Color.alphaBlend(
            scheme.onSurface.withValues(alpha: 0.08), scheme.surface),
      ),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: AppSpacing.md),
      ),
      constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      ),
      hintStyle: WidgetStatePropertyAll(
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onTap: onTap,
    );
    if (!readOnly) return bar;
    // 只读形态：保留外观，屏蔽输入，点击透传给 onTap
    return GestureDetector(onTap: onTap, child: IgnorePointer(child: bar));
  }
}

/// BrandIconButton — 顶栏右侧图标按钮（48dp 热区）
class BrandIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const BrandIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 24,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

/// BrandTextAction — 顶栏右侧文字动作
class BrandTextAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;

  const BrandTextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18),
            const SizedBox(width: AppSpacing.sm),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// BrandTabBar — M3 primary tabs，48dp 高
class BrandTabBar extends StatelessWidget implements PreferredSizeWidget {
  final List<String> labels;
  final TabController? controller;
  final ValueChanged<int>? onTap;

  const BrandTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: controller,
      onTap: onTap,
      isScrollable: labels.length > 4,
      tabAlignment: labels.length > 4 ? TabAlignment.start : TabAlignment.fill,
      tabs: labels.map((l) => Tab(text: l)).toList(),
      dividerHeight: 0,
    );
  }
}

/// SurfaceTabBar — M3 secondary tabs，用于内容层筛选
class SurfaceTabBar extends StatelessWidget implements PreferredSizeWidget {
  final List<String> labels;
  final TabController? controller;
  final ValueChanged<int>? onTap;

  const SurfaceTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    return TabBar.secondary(
      controller: controller,
      onTap: onTap,
      isScrollable: labels.length > 4,
      tabAlignment: labels.length > 4 ? TabAlignment.start : TabAlignment.fill,
      tabs: labels.map((l) => Tab(text: l)).toList(),
      dividerHeight: 0,
    );
  }
}
