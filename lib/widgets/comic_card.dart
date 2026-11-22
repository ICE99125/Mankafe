import 'package:flutter/material.dart';

import '../models/comic.dart';
import '../services/image_url.dart';
import '../theme/app_theme.dart';
import 'net_image.dart';

/// CoverImage — 封面，相对路径经 [resolveImageUrl] 拼 CDN，失败给首字占位
class CoverImage extends StatelessWidget {
  final Comic comic;
  final double? width;
  final double? height;
  final BorderRadius radius;
  final String? host;

  /// 裁切对齐方式，宽幅场景用 [Alignment.topCenter]
  final Alignment alignment;

  const CoverImage({
    super.key,
    required this.comic,
    this.width,
    this.height,
    this.host,
    this.radius = const BorderRadius.all(Radius.circular(14)),
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final expand = width == double.infinity || height == double.infinity;
    final content = _content(context);
    return ClipRRect(
      borderRadius: radius,
      child: expand
          ? SizedBox.expand(child: content)
          : SizedBox(
              width: width,
              height: height,
              child: content,
            ),
    );
  }

  Widget _content(BuildContext context) {
    final url = resolveImageUrl(comic.cover ?? '', host: host);
    if (url != null && url.isNotEmpty) {
      // 加载中给骨架、失败自动重试一次，最终落到首字占位
      return NetImage(
        url: url,
        fit: BoxFit.cover,
        alignment: alignment,
        decodeWidth: width == null || width == double.infinity ? null : width,
        errorBuilder: (_) => _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    // 失败占位：纯色 surface + 书名首字
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          comic.name.isEmpty ? '漫' : comic.name.substring(0, 1),
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 42,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// ComicCard — 封面在上的竖版卡片
class ComicCard extends StatelessWidget {
  final Comic comic;
  final double width;
  final String? badge;
  final String? subtitle;
  final VoidCallback onTap;

  const ComicCard({
    super.key,
    required this.comic,
    required this.onTap,
    this.width = 124,
    this.badge,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShape.mdRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: CoverImage(
                    comic: comic,
                    width: double.infinity,
                    height: double.infinity,
                    radius: AppShape.mdRadius,
                  ),
                ),
                if (badge != null)
                  Positioned(
                    left: 7,
                    top: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              comic.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle ?? comic.lastChapter,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// ComicTile — 横向条目
class ComicTile extends StatelessWidget {
  final Comic comic;
  final String? trailing;
  final String? leadingBadge;

  /// 副标题覆盖，避免拼出空作者 / 0 人气
  final String? subtitle;
  final VoidCallback onTap;

  const ComicTile({
    super.key,
    required this.comic,
    required this.onTap,
    this.trailing,
    this.leadingBadge,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      leading: Stack(
        children: [
          CoverImage(comic: comic, width: 52, height: 74),
          if (leadingBadge != null)
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Text(
                  leadingBadge!,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onPrimary),
                ),
              ),
            ),
        ],
      ),
      title: Text(comic.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          subtitle ??
              '${comic.authorLabel}  ·  ${comic.themeLabel}\n${comic.lastChapter}  ·  ${comic.popularLabel} 人气',
          maxLines: 2,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      trailing: trailing != null
          ? Text(trailing!, style: theme.textTheme.labelMedium)
          : Icon(Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
