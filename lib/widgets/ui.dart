import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/link.dart';
import '../services/route_manager.dart';
import '../theme/app_theme.dart';

/// SurfaceCard — 官方 Card 的薄封装，颜色 / 圆角 / 裁剪走 CardTheme
class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;

  /// 自定义圆角，不传走 CardTheme 的12dp
  final BorderRadius? radius;

  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.base),
    this.color,
    this.onTap,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      shape: radius == null
          ? null
          : RoundedRectangleBorder(borderRadius: radius!),
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// SectionHeader — 区块标题，可选副标题与右侧文字动作
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(
        AppSpacing.base, AppSpacing.lg, AppSpacing.sm, AppSpacing.sm),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: scheme.onSurface),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// ExpandableText — 简介折叠块，默认只露 [collapsedLines] 行
class ExpandableText extends StatefulWidget {
  const ExpandableText({
    super.key,
    required this.text,
    this.style,
    this.collapsedLines = 3,
    this.expandLabel = '展开简介',
    this.collapseLabel = '收起简介',
  });

  final String text;
  final TextStyle? style;
  final int collapsedLines;
  final String expandLabel;
  final String collapseLabel;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ExpandableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一位置换了正文时自动收回，不把展开状态带给新内容
    if (oldWidget.text != widget.text) _expanded = false;
  }

  /// 按当前可用宽度量一遍：正文是否超过 [ExpandableText.collapsedLines] 行
  bool _overflows(BuildContext context, double maxWidth, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: widget.collapsedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    return overflows;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? Theme.of(context).textTheme.bodyMedium;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final overflows = _overflows(context, width, style);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: AppMotion.medium2,
              curve: AppMotion.standard,
              alignment: Alignment.topLeft,
              child: Text(
                widget.text,
                maxLines: _expanded ? null : widget.collapsedLines,
                overflow:
                    _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (overflows) _toggle(style),
          ],
        );
      },
    );
  }

  Widget _toggle(TextStyle? style) {
    final theme = Theme.of(context);
    return TextButton(
      onPressed: () => setState(() => _expanded = !_expanded),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.only(right: AppSpacing.sm),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.colorScheme.primary,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_expanded ? widget.collapseLabel : widget.expandLabel),
          const SizedBox(width: AppSpacing.xs),
          Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
        ],
      ),
    );
  }
}

/// EmptyState — 空状态：图标 + 标题 + 可选说明与操作
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.base),
            Text(title, style: theme.textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

Color linkHealthColor(LinkHealth health, ColorScheme scheme) => switch (health) {
      LinkHealth.online => const Color(0xFF2E9E63),
      LinkHealth.offline => scheme.error,
      LinkHealth.checking => scheme.tertiary,
      LinkHealth.unknown => scheme.outline,
    };

/// LinkDot — 链路健康状态圆点
class LinkDot extends StatelessWidget {
  final LinkHealth health;
  final double size;

  const LinkDot({super.key, required this.health, this.size = 8});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: linkHealthColor(health, Theme.of(context).colorScheme),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// OriginChip — 链路来源标签
class OriginChip extends StatelessWidget {
  final LinkOrigin origin;
  const OriginChip({super.key, required this.origin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlighted = origin == LinkOrigin.discovered;
    final bg = highlighted
        ? scheme.tertiaryContainer
        : scheme.surfaceContainerHighest;
    final fg = highlighted
        ? scheme.onTertiaryContainer
        : scheme.onSurfaceVariant;
    return Chip(
      label: Text(origin.label),
      backgroundColor: bg,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: theme.textTheme.labelSmall?.copyWith(color: fg),
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// LinkStatusBanner — 当前链路提示条
class LinkStatusBanner extends StatelessWidget {
  final bool compact;
  final VoidCallback? onOpen;
  const LinkStatusBanner({super.key, this.compact = false, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Consumer<RouteManager>(
      builder: (context, routes, _) {
        final link = routes.activeLink;
        return Material(
          color: scheme.surfaceContainerLow,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.base, vertical: AppSpacing.md),
              child: Row(
                children: [
                  Icon(Icons.hub, size: 24, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.base),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '当前链路 · ${link.name}',
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            LinkDot(health: link.health),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          compact
                              ? '${routes.mode.label} · ${link.healthLabel}${link.latencyMs != null ? ' · ${link.latencyMs} ms' : ''}'
                              : '${link.baseUrl} · ${routes.onlineCount} 条链路畅通',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right,
                      color: scheme.onSurfaceVariant, size: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
