import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// PagePager — 通用分页器：`上一页 | 区间 + 页码 | 下一页`
class PagePager extends StatelessWidget {
  /// 当前页（0 起始）
  final int page;

  /// 总页数，至少为1
  final int pageCount;

  /// 服务端给的全量条数，用于算区间与页码
  final int total;

  /// 每页条数
  final int pageSize;

  /// 翻页回调，参数是目标页（0 起始）
  final ValueChanged<int> onPage;

  final EdgeInsetsGeometry padding;

  const PagePager({
    super.key,
    required this.page,
    required this.pageCount,
    required this.total,
    required this.pageSize,
    required this.onPage,
    this.padding = const EdgeInsets.fromLTRB(8, 4, 8, 6),
  });

  /// 只有一页时不占高度：一条写死的第1 / 1 页纯属占位
  bool get visible => pageCount > 1;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 末页可能不满一整页，end 要按 total 收口，不能显示成21-40 / 35
    final start = page * pageSize + 1;
    final end = ((page + 1) * pageSize).clamp(0, total);
    final hasPrev = page > 0;
    final hasNext = page < pageCount - 1;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          _PagerButton(
            icon: Icons.chevron_left_rounded,
            label: t.prevPage,
            onPressed: hasPrev ? () => onPage(page - 1) : null,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.pageRange(start, end, total),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.pageOf(page + 1, pageCount),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _PagerButton(
            icon: Icons.chevron_right_rounded,
            label: t.nextPage,
            iconAfter: true,
            onPressed: hasNext ? () => onPage(page + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// _PagerButton — 分页按钮：首页 / 末页时置灰不可点，左右等宽避免中间文字抖动
class _PagerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool iconAfter;
  final VoidCallback? onPressed;

  const _PagerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconAfter = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = enabled ? scheme.primary : scheme.outline;
    final parts = <Widget>[
      Icon(icon, size: 20, color: fg),
      const SizedBox(width: 2),
      Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    ];
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: iconAfter ? parts.reversed.toList() : parts,
      ),
    );
  }
}
