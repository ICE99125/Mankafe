import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/content.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/net_image.dart';
import '../widgets/paged_media.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';

/// TopicDetailScreen — 专题详情页，封面、期号、说明
class TopicDetailScreen extends StatefulWidget {
  final String pathWord;

  /// 首页 / 专题列表带过来的标题，详情接口回来前先占位
  final String title;

  /// 专题来自哪个频道：动画专题返回动画条目，详情页要按频道打开
  final MediaKind kind;

  const TopicDetailScreen({
    super.key,
    required this.pathWord,
    required this.title,
    this.kind = MediaKind.comic,
  });

  static void open(
    BuildContext context, {
    required String pathWord,
    required String title,
    MediaKind kind = MediaKind.comic,
  }) {
    if (pathWord.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TopicDetailScreen(
        pathWord: pathWord,
        title: title,
        kind: kind,
      ),
    ));
  }

  @override
  State<TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<TopicDetailScreen> {
  Future<TopicDetail>? _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = context.read<Repository>().topicDetail(widget.pathWord);
  }

  void _reloadDetail() {
    // 下拉刷新可能发生在页面已经 pop 之后（请求还在飞），这里先挡一下
    if (!mounted) return;
    setState(() {
      _detailFuture = context.read<Repository>().topicDetail(widget.pathWord);
    });
  }

  void _openItem(String pathWord) {
    if (widget.kind == MediaKind.comic) {
      openComicDetail(context, pathWord);
    } else {
      openContentDetail(context, widget.kind, pathWord);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    final nav = Navigator.of(context);
    return Scaffold(
      body: Column(
        children: [
          BrandBar(
            leading: BrandBackButton(onPressed: () => nav.pop()),
            // 顶栏只写页面名：具体是哪一期由下面页头里的系列名 / 标题 / 说明交代
            title: BrandTitle(name: t.sectionTopics),
          ),
          Expanded(
            child: PagedMediaList(
              load: (offset) => repo.topicContents(
                widget.pathWord,
                kind: widget.kind,
                offset: offset,
              ),
              // 下拉刷新时说明一起重拉：首页换了新一期、专题改名都只有详情接口知道，列表自己不会变
              onRefresh: () async => _reloadDetail(),
              headerSlivers: [
                SliverToBoxAdapter(child: _header(context, host)),
              ],
              // 专题条目整批都没有 `datetime_updated`：用扣掉日期行的度量
              gridDelegate: kTripleGridDelegateNoDate,
              skeleton:
                  const MediaGridSkeleton(textExtent: kCardTextExtentNoDate),
              emptyTitle: '这个专题还没有作品',
              emptyMessage: '专题内容来自线上接口，稍后刷新试试',
              itemBuilder: (context, comic) => MediaEntryCard(
                comic: comic,
                host: host,
                badge: comic.statusLabel,
                onTap: () => _openItem(comic.pathWord),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String? host) {
    return FutureBuilder<TopicDetail>(
      future: _detailFuture,
      builder: (context, snapshot) {
        final error = snapshot.error;
        if (error != null) return _TopicHeaderError(onRetry: _reloadDetail);
        final detail = snapshot.data;
        if (detail == null) return const _TopicHeaderSkeleton();
        return _TopicHeader(
          detail: detail,
          host: host,
          fallbackTitle: widget.title,
        );
      },
    );
  }
}

/// _TopicHeader — 页头：封面横幅 + 专题系列日期+ 标题 + 说明
class _TopicHeader extends StatelessWidget {
  final TopicDetail detail;
  final String? host;

  /// 详情接口没给 `title` 时用入口页带来的标题（首页专题卡的那串）
  final String fallbackTitle;

  const _TopicHeader({
    required this.detail,
    required this.fallbackTitle,
    this.host,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final cover = resolveImageUrl(detail.cover, host: host) ?? '';
    final description = detail.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cover.isNotEmpty)
          AspectRatio(
            aspectRatio: imageAspect(cover, fallback: 3.72),
            child: NetImage(
              url: cover,
              fit: BoxFit.cover,
              errorBuilder: (_) =>
                  ColoredBox(color: scheme.surfaceContainerHighest),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      // 服务端给了系列名（`series.name`，如熱門漫畫專題）就直接用，缺字段时退回页面名
                      detail.seriesName.isNotEmpty
                          ? detail.seriesName
                          : t.sectionTopics,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (detail.createdAt.isNotEmpty) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      detail.createdAt,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                detail.title.isEmpty ? fallbackTitle : detail.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 10),
                // 说明默认4 行：本期这段约占3 行，长说明才需要展开，否则页头会把作品列表整块推到屏幕外
                ExpandableText(
                  text: description,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.6),
                  collapsedLines: 4,
                  expandLabel: '展开说明',
                  collapseLabel: '收起说明',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
      ],
    );
  }
}

/// _TopicHeaderError — 说明加载失败：页头退化成一条可重试的提示，作品列表照常显示
class _TopicHeaderError extends StatelessWidget {
  final VoidCallback onRetry;

  const _TopicHeaderError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '专题说明加载失败',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// _TopicHeaderSkeleton — 说明未回来时的页头骨架：尺寸和真实页头一致，数据到达不跳布局
class _TopicHeaderSkeleton extends StatelessWidget {
  const _TopicHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3.72,
            child: SkeletonBox(radius: 0),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SkeletonBox(width: 64, height: 16, radius: 4),
                    SizedBox(width: AppSpacing.sm),
                    SkeletonBox(width: 72, height: 12, radius: 4),
                  ],
                ),
                SizedBox(height: 12),
                SkeletonBox(width: 260, height: 22, radius: 4),
                SizedBox(height: 12),
                SkeletonBox(width: double.infinity, height: 12, radius: 4),
                SizedBox(height: AppSpacing.sm),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.8,
                  child: SkeletonBox(height: 12, radius: 4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
