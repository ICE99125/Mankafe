import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/home_index.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/net_image.dart';
import '../widgets/skeleton.dart';
import '../widgets/request_error.dart';
import 'catalog_more_screen.dart';
import '../services/http_cache.dart';

/// TopicListScreen — 专题系列更多页，分页加载
class TopicListScreen extends StatefulWidget {
  final MediaKind kind;

  const TopicListScreen({super.key, this.kind = MediaKind.comic});

  @override
  State<TopicListScreen> createState() => _TopicListScreenState();
}

class _TopicListScreenState extends State<TopicListScreen> {
  static const int _pageSize = 12;

  final List<HomeTopic> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final offset = reset ? 0 : _items.length;
      final list = await context.read<Repository>().topics(
            offset: offset,
            limit: _pageSize,
            type: widget.kind == MediaKind.animation ? 21 : null,
          );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(list);
        _hasMore = list.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.kind == MediaKind.animation
            ? t.animationTopicListTitle
            : t.topicListTitle),
      ),
      body: _loading
          ? const _TopicListSkeleton()
          : _items.isEmpty && _error != null
              ? RequestErrorState(
                  error: _error!, onRetry: () => _load(reset: true))
              : _items.isEmpty
                  ? Center(child: Text(t.emptyUpdatesTitle))
                  : RefreshIndicator(
                      onRefresh: () {
                        HttpCache.instance.markAllStale();
                        return _load(reset: true);
                      },
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: _items.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          if (index == _items.length) return _footer(t);
                          return _TopicRow(
                            topic: _items[index],
                            host: host,
                            onTap: () => CatalogMoreScreen.openTopicContents(
                              context,
                              pathWord: _items[index].pathWord,
                              title: _items[index].title,
                              kind: widget.kind,
                            ),
                          );
                        },
                      ),
                    ),
    );
  }

  Widget _footer(AppLocalizations t) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(t.noMore, style: Theme.of(context).textTheme.bodySmall),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: OutlinedButton(
        onPressed: () => _load(),
        child: Text(t.loadMore),
      ),
    );
  }
}

/// _TopicRow — 专题卡，封面与标题
class _TopicRow extends StatelessWidget {
  final HomeTopic topic;
  final String? host;
  final VoidCallback onTap;

  const _TopicRow({
    required this.topic,
    required this.host,
    required this.onTap,
  });

  /// 按封面 URL 的尺寸后缀取宽高比，缺省2.5
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = resolveImageUrl(topic.cover, host: host) ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: imageAspect(url, fallback: 2.5),
                child: NetImage(
                  url: url,
                  fit: BoxFit.cover,
                  errorBuilder: (_) =>
                      ColoredBox(color: scheme.surfaceContainerHighest),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              topic.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (topic.period.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  topic.period,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// _TopicListSkeleton — 专题列表首屏骨架
class _TopicListSkeleton extends StatelessWidget {
  const _TopicListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: 4,
        separatorBuilder: (_, __) => const SizedBox(height: 16),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AspectRatio(
                aspectRatio: 3.72,
                child: SkeletonBox(
                  radius: 12,
                ),
              ),
              const SizedBox(height: 8),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: i.isEven ? 0.7 : 0.5,
                child: const SkeletonBox(
                  height: 15,
                  radius: 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
