import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/chapter.dart';
import '../services/image_url.dart';
import 'net_image.dart';
import 'ui.dart';

/// CommentCountButton — 顶栏评论入口：图标右上角挂一个总数角标，点进去才是评论列表
class CommentCountButton extends StatelessWidget {
  final int count;
  final VoidCallback onPressed;
  final String tooltip;

  const CommentCountButton({
    super.key,
    required this.count,
    required this.onPressed,
    this.tooltip = '',
  });

  String get _label => count > 99 ? '99+' : '$count';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip.isEmpty ? null : tooltip,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        alignment: AlignmentDirectional.topEnd,
        // 往上、往右挪一点，pill 只贴着图标的右上角，不压住图标本身
        offset: const Offset(4, -14),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        label: Text(
          _label,
          style: const TextStyle(
            fontSize: 9,
            height: 1.1,
            fontWeight: FontWeight.w500,
          ),
        ),
        // 图标不带颜色：详情页头图展开时顶栏图标是白色、收起后转深色
        child: const Icon(Icons.forum_outlined),
      ),
    );
  }
}

/// CommentAvatar — 评论头像，无头像或加载失败退回昵称首字
class CommentAvatar extends StatelessWidget {
  final String name;
  final String avatar;
  final String? host;
  final double size;

  const CommentAvatar({
    super.key,
    required this.name,
    this.avatar = '',
    this.host,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '读' : String.fromCharCode(name.runes.first);
    final hue = (name.hashCode % 360).abs().toDouble();
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HSVColor.fromAHSV(1, hue, 0.42, 0.74).toColor(),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w500,
        ),
      ),
    );

    final url = resolveImageUrl(avatar, host: host);
    if (url == null) return fallback;
    // 外面套一层定尺寸的框：头像在 `Row` 里，父级沿主轴给的是无界约束
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: NetImage(
          url: url,
          width: size,
          height: size,
          decodeWidth: size,
          fit: BoxFit.cover,
          errorBuilder: (_) => fallback,
        ),
      ),
    );
  }
}

/// 评论时间：刚刚 / N 分钟前 / N 小时前 / N 天前，超过30 天显示日期
String commentTimeLabel(AppLocalizations t, String raw) {
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (parsed == null) return raw.length >= 10 ? raw.substring(0, 10) : raw;
  final diff = DateTime.now().difference(parsed);
  if (diff.isNegative) return t.formatDate(parsed);
  if (diff.inMinutes < 1) return t.justNow;
  if (diff.inHours < 1) return t.minutesAgo(diff.inMinutes);
  if (diff.inDays < 1) return t.hoursAgo(diff.inHours);
  if (diff.inDays < 30) return t.daysAgo(diff.inDays);
  return t.formatDate(parsed);
}

/// CommentTile — 评论列表里的一条：头像 + 昵称 / 时间 + 正文 + 回复入口
class CommentTile extends StatelessWidget {
  final ComicComment comment;
  final String? host;
  final VoidCallback? onReply;
  final VoidCallback? onToggleReplies;

  /// 非空时在操作行右侧显示删除（只给自己的评论）
  final VoidCallback? onDelete;
  final bool expanded;
  final bool loadingReplies;

  const CommentTile({
    super.key,
    required this.comment,
    this.host,
    this.onReply,
    this.onToggleReplies,
    this.onDelete,
    this.expanded = false,
    this.loadingReplies = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CommentAvatar(
          name: comment.userName,
          avatar: comment.avatar,
          host: host,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      comment.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    commentTimeLabel(t, comment.createdAt),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                comment.content,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (onReply != null)
                    InkWell(
                      onTap: onReply,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 2),
                        child: Text(
                          t.reply,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  if (onToggleReplies != null) ...[
                    if (onReply != null) const SizedBox(width: 14),
                    InkWell(
                      onTap: onToggleReplies,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (loadingReplies)
                              const SizedBox(
                                width: 11,
                                height: 11,
                                child:
                                    CircularProgressIndicator(strokeWidth: 1.6),
                              )
                            else
                              Icon(Icons.chat_bubble_outline_rounded,
                                  size: 13, color: scheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              t.commentReplyCount(comment.replyCount),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.primary),
                            ),
                            Icon(
                              expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 14,
                              color: scheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (onDelete != null) ...[
                    // 紧跟在回复 / N 条回复后面，不要用 Spacer 顶到最右边：吐槽页没有回复按钮
                    if (onReply != null || onToggleReplies != null)
                      const SizedBox(width: 14),
                    InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 2),
                        child: Text(
                          t.commentDelete,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// CommentThreadList — 一条评论下面的整棵回复树（扁平渲染 + 按 `parent_id` 缩进）
class CommentThreadList extends StatelessWidget {
  final List<ComicComment> replies;
  final String rootId;
  final String? host;
  final void Function(ComicComment reply)? onReply;

  /// 只对自己的回复传：删除这条回复
  final void Function(ComicComment reply)? onDelete;

  /// 哪一条能删（只给自己的回复）
  final bool Function(ComicComment reply)? canDelete;

  const CommentThreadList({
    super.key,
    required this.replies,
    required this.rootId,
    this.onReply,
    this.onDelete,
    this.canDelete,
    this.host,
  });

  /// 按 `parent_id` 还原层级
  int _depthOf(ComicComment reply) {
    var depth = 1;
    var parent = reply.parentId;
    final byId = {for (final r in replies) r.id: r};
    final seen = <String>{};
    while (parent.isNotEmpty && parent != rootId && seen.add(parent)) {
      final node = byId[parent];
      if (node == null) break;
      depth += 1;
      parent = node.parentId;
    }
    return depth;
  }

  /// 子回复按时间正序（先说的在上面），没有时间就保持接口顺序
  List<ComicComment> get _ordered {
    final list = [...replies];
    list.sort((a, b) {
      final at = DateTime.tryParse(a.createdAt.replaceFirst(' ', 'T'));
      final bt = DateTime.tryParse(b.createdAt.replaceFirst(' ', 'T'));
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6, left: 4),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final reply in _ordered)
            Padding(
              padding: EdgeInsets.only(
                left: (_depthOf(reply) - 1) * 14.0,
                bottom: 10,
              ),
              child: CommentReplyTile(
                comment: reply,
                host: host,
                // 直接回复根评论时不重复回复 @楼主，位置已经说明了
                showTarget: reply.parentId != rootId,
                onReply: onReply == null ? null : () => onReply!(reply),
                onDelete: (onDelete == null ||
                        (canDelete != null && !canDelete!(reply)))
                    ? null
                    : () => onDelete!(reply),
              ),
            ),
        ],
      ),
    );
  }
}

/// CommentReplyTile — 回复树里的一条，带被回复人昵称
class CommentReplyTile extends StatelessWidget {
  final ComicComment comment;
  final String? host;
  final bool showTarget;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  const CommentReplyTile({
    super.key,
    required this.comment,
    this.host,
    this.showTarget = false,
    this.onReply,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CommentAvatar(
          name: comment.userName,
          avatar: comment.avatar,
          host: host,
          size: 28,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      comment.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    commentTimeLabel(t, comment.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
              if (showTarget && comment.replyUserName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    t.commentReplyTo(comment.replyUserName),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.primary, fontSize: 10.5),
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                comment.content,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
              if (onReply != null || onDelete != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    children: [
                      if (onReply != null)
                        InkWell(
                          onTap: onReply,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2, vertical: 1),
                            child: Text(
                              t.reply,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                      if (onDelete != null) ...[
                        if (onReply != null) const SizedBox(width: 14),
                        InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2, vertical: 1),
                            child: Text(
                              t.commentDelete,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// CommentPreviewCard — 详情页留言摘要卡，正文最多3 行
class CommentPreviewCard extends StatelessWidget {
  final ComicComment comment;
  final String? host;
  final VoidCallback? onTap;

  const CommentPreviewCard({
    super.key,
    required this.comment,
    this.host,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: const BorderRadius.all(Radius.circular(16)),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommentAvatar(
            name: comment.userName,
            avatar: comment.avatar,
            host: host,
            size: 34,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      commentTimeLabel(t, comment.createdAt),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  comment.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                if (comment.replyCount > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded,
                          size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(
                        t.commentReplyCount(comment.replyCount),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
