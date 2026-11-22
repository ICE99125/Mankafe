import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/content.dart';
import '../models/home_index.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/request_error.dart';
import '../widgets/net_image.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'catalog_more_screen.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';
import 'link_screen.dart';
import '../services/http_cache.dart';

/// IndexBundle — 聚合页的一次加载结果：h5 首页 + 补充的真实题材标签
typedef IndexBundle = ({MediaIndex index, List<ThemeTag> tags});

/// MediaIndexScreen — 动画 / 写真频道的聚合首页
class MediaIndexScreen extends StatefulWidget {
  final MediaKind kind;

  /// 嵌进频道页（写真首页分段）时不再自带 BrandBar / Scaffold
  final bool embedded;

  const MediaIndexScreen(
      {super.key, required this.kind, this.embedded = false});

  @override
  State<MediaIndexScreen> createState() => _MediaIndexScreenState();
}

class _MediaIndexScreenState extends State<MediaIndexScreen> {
  late Future<IndexBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<IndexBundle> _load() async {
    final repo = context.read<Repository>();
    final index = await repo.mediaIndex(widget.kind);
    var tags = index.tags;
    // postIndex 不下发 tags
    if (tags.length < 24) {
      try {
        final extra = await repo.themeTags(widget.kind);
        if (extra.length > tags.length) tags = extra;
      } catch (error) {
        // 补充标签失败不遮住已成功的主页数据，只在调试日志留痕
        if (kDebugMode) debugPrint('[mediaIndex] 补充题材标签失败: $error');
      }
    }
    return (index: index, tags: tags);
  }

  void _retry() => setState(() => _future = _load());

  Future<void> _refresh() async {
    // 用户主动刷新：把缓存水位线抬高，这次一定走网络
    HttpCache.instance.markAllStale();
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  void _openItem(String id) {
    if (id.isEmpty) return;
    openContentDetail(context, widget.kind, id);
  }

  /// 轮播按服务端 `type` 打开对应真实详情接口，不假设聚合页频道与轮播类型一致
  void _openBanner(HomeBanner banner) {
    final id = banner.routeId();
    if (!banner.isContent) {
      _showBannerInfo(banner);
      return;
    }
    switch (banner.target) {
      case BannerTarget.comic:
        openComicDetail(context, id);
      case BannerTarget.animation:
        openContentDetail(context, MediaKind.animation, id);
      case BannerTarget.photo:
        openContentDetail(context, MediaKind.photo, id);
      case BannerTarget.external:
      case BannerTarget.unknown:
        _showBannerInfo(banner);
    }
  }

  /// 只展示服务端下发的标题 / 简介
  void _showBannerInfo(HomeBanner banner) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(banner.title,
                style: Theme.of(ctx)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w500)),
            if (banner.subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(banner.subtitle, style: Theme.of(ctx).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }

  /// 排序项来自 cartoonIndex 的 `ordering`
  void _openOrdering(ThemeTag ordering) {
    CatalogMoreScreen.openFilter(
      context,
      kind: widget.kind,
      title: '${widget.kind.label} · ${ordering.name}',
      ordering: ordering.pathWord,
    );
  }

  /// 动画用 `theme=path_word`，写真用 `tag=path_word`
  void _openTag(ThemeTag tag) {
    CatalogMoreScreen.openFilter(
      context,
      kind: widget.kind,
      title: '${widget.kind.label} · ${tag.name}',
      theme: widget.kind == MediaKind.photo ? '' : tag.pathWord,
      tag: widget.kind == MediaKind.photo ? tag.pathWord : '',
    );
  }

  void _openTopic(HomeTopic topic) {
    if (topic.pathWord.isEmpty) return;
    CatalogMoreScreen.openTopicContents(
      context,
      pathWord: topic.pathWord,
      title: topic.title,
      kind: widget.kind,
    );
  }

  /// 榜单类分组按热度排序，其余按更新时间排序
  String _groupOrdering(String key) =>
      key.toLowerCase().contains('rank') ? 'popular' : '-datetime_updated';

  void _openGroup(MediaIndexGroup group) {
    final repo = context.read<Repository>();
    final ordering = _groupOrdering(group.key);
    CatalogMoreScreen.openLoader(
      context,
      title: '${group.title} · 全部',
      kind: widget.kind,
      subtitle: '${widget.kind.label} · 线上排序 $ordering',
      load: (offset) => repo.filteredPage(
        widget.kind,
        ordering: ordering,
        offset: offset,
      ),
    );
  }

  void _openAll() {
    final repo = context.read<Repository>();
    CatalogMoreScreen.openLoader(
      context,
      title: '全部${widget.kind.label}',
      kind: widget.kind,
      subtitle: '${widget.kind.label} · 线上完整列表',
      load: (offset) => repo.filteredPage(widget.kind, offset: offset),
    );
  }

  void _openLinks() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LinkScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final content = FutureBuilder<IndexBundle>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return RequestErrorState(
            error: snapshot.error!,
            onRetry: _retry,
          );
        }
        // 聚合页骨架：轮播、全部列表、排序与题材 chip、专题与分组横滑
        if (!snapshot.hasData) return const MediaIndexSkeleton();
        final bundle = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: _slivers(context, t, bundle),
          ),
        );
      },
    );

    // 嵌进写真频道的首页分段：顶栏和分段 tab 由频道页提供
    if (widget.embedded) return content;

    return Scaffold(
      body: Column(
        children: [
          BrandBar(
            leading: BrandBackButton(
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: BrandTitle(name: '${widget.kind.label} · 聚合'),
            actions: [
              BrandIconButton(
                icon: Icons.hub_outlined,
                tooltip: '网络链路',
                onPressed: _openLinks,
              ),
              BrandIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新',
                onPressed: _retry,
              ),
            ],
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  List<Widget> _slivers(
    BuildContext context,
    AppLocalizations t,
    IndexBundle bundle,
  ) {
    final host = context.read<Repository>().imageHost;
    final index = bundle.index;
    final out = <Widget>[];

    // 1) 轮播：animation 的 comic.path_word 是动画 path_word
    final banners = index.banners.where((b) => b.isContent).take(8).toList();
    if (banners.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: CoverCarousel(
          slides: banners
              .map((b) => CarouselSlide(
                    title: b.title.isEmpty ? b.subtitle : b.title,
                    subtitle: b.subtitle.isEmpty ? null : b.subtitle,
                    imageUrl: resolveImageUrl(b.cover, host: host),
                    onTap: () => _openBanner(b),
                  ))
              .toList(),
        ),
      ));
    }

    // 2) 完整频道列表入口（真实分页接口）
    out.add(SliverToBoxAdapter(
      child: SectionHeader(
        title: '全部${widget.kind.label}',
        subtitle:
            'GET ${widget.kind == MediaKind.animation ? '/api/v3/cartoons' : '/api/v3/posts'}',
        actionLabel: t.homeMore,
        onAction: _openAll,
      ),
    ));

    // 3) 服务端下发的排序项（动画频道）
    if (index.orderings.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('排序方式',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: index.orderings
                    .map((o) => ActionChip(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          avatar: const Icon(Icons.sort_rounded, size: 16),
                          label: Text(o.name),
                          onPressed: () => _openOrdering(o),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ));
    }

    // 4) 题材 / 标签：全部来自真实 count 接口，值用 path_word
    if (bundle.tags.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.kind == MediaKind.photo ? '标签' : '题材',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: bundle.tags
                    .take(18)
                    .map((tag) => ActionChip(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(tag.count > 0
                              ? '${tag.name} · ${tag.count}'
                              : tag.name),
                          onPressed: () => _openTag(tag),
                        ))
                    .toList(),
              ),
              if (bundle.tags.length > 18)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _showAllTags(bundle.tags),
                    icon: const Icon(Icons.expand_more_rounded, size: 16),
                    label: Text('全部${bundle.tags.length}个标签'),
                  ),
                ),
            ],
          ),
        ),
      ));
    }

    // 5) 专题：cartoonIndex 的 topics 是 {list:[...]} 信封
    if (index.topics.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: SectionHeader(
          title: t.sectionTopics,
          subtitle: 'GET /api/v3/topic/{path_word}/contents',
        ),
      ));
      out.add(SliverToBoxAdapter(
        child: SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: index.topics.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _TopicCard(
              topic: index.topics[i],
              host: host,
              onTap: () => _openTopic(index.topics[i]),
            ),
          ),
        ),
      ));
    }

    // 6) 推荐 / 榜单 / 最新分组：横向卡片，更多进入真实分页列表
    for (final group in index.groups) {
      out.add(SliverToBoxAdapter(
        child: SectionHeader(
          title: group.title,
          subtitle: group.total > 0 ? '线上共 ${group.total} 条' : '来自线上接口',
          actionLabel: t.homeMore,
          onAction: () => _openGroup(group),
        ),
      ));
      out.add(SliverToBoxAdapter(
        child: SizedBox(
          height: 212,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: group.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _IndexCard(
              comic: group.items[i],
              host: host,
              onTap: () => _openItem(group.items[i].pathWord),
            ),
          ),
        ),
      ));
    }

    out.add(const SliverToBoxAdapter(child: SizedBox(height: 28)));
    return out;
  }

  void _showAllTags(List<ThemeTag> tags) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('全部标签（${tags.length}）',
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: tags
                  .map((tag) => ActionChip(
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(tag.name),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _openTag(tag);
                        },
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// _TopicCard — 专题横滑卡：封面来自 `topics[].cover`，点击进入真实专题内容页
class _TopicCard extends StatelessWidget {
  final HomeTopic topic;
  final String? host;
  final VoidCallback onTap;

  const _TopicCard({
    required this.topic,
    required this.host,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 220,
          height: 104,
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetImage(
                url: resolveImageUrl(topic.cover, host: host) ?? '',
                fit: BoxFit.cover,
                errorBuilder: (_) => ColoredBox(color: scheme.primaryContainer),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xAA000000)],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 8,
                child: Text(
                  topic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// _IndexCard — 分组横向卡片：封面 / 标题 / 作者全部来自接口，不使用任何本地占位图
class _IndexCard extends StatelessWidget {
  final Comic comic;
  final String? host;
  final VoidCallback onTap;

  const _IndexCard({
    required this.comic,
    required this.host,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 112,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: NetImage(
                  url: resolveImageUrl(comic.cover ?? '', host: host) ?? '',
                  fit: BoxFit.cover,
                  errorBuilder: (_) =>
                      ColoredBox(color: scheme.primaryContainer),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              comic.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w500, height: 1.25),
            ),
            const SizedBox(height: 2),
            Text(
              comic.authorLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
