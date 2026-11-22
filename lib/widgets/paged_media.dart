import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import 'browse_widgets.dart';
import 'request_error.dart';
import 'skeleton.dart';
import 'ui.dart';
import '../services/http_cache.dart';

/// PagedMediaList — 上拉分页列表，四个 tab 共用
class PagedMediaList extends StatefulWidget {
  final Future<MediaPage> Function(int offset) load;
  final List<Widget> headerSlivers;
  final Widget Function(BuildContext context, Comic comic) itemBuilder;
  final bool Function(Comic comic)? filter;
  final String emptyTitle;
  final String emptyMessage;
  final String? filteredEmptyTitle;
  final String? filteredEmptyMessage;
  final Object? resetKey;

  /// 首屏骨架（sliver）
  final Widget? skeleton;

  /// 三列网格的行高度量
  final SliverGridDelegate? gridDelegate;

  /// 下拉刷新时额外要刷新的东西（例如分类页的题材标签行）
  final Future<void> Function()? onRefresh;

  /// 单列列表（排行榜按行排），不再走三列网格
  final bool singleColumn;

  /// 单列模式下的 index 版 itemBuilder：排行榜需要行号做名次
  final Widget Function(BuildContext context, Comic comic, int index)?
      indexedItemBuilder;

  /// 固定顶栏的高度
  final double refreshEdgeOffset;

  const PagedMediaList({
    super.key,
    required this.load,
    required this.itemBuilder,
    required this.emptyTitle,
    required this.emptyMessage,
    this.headerSlivers = const [],
    this.filter,
    this.filteredEmptyTitle,
    this.filteredEmptyMessage,
    this.resetKey,
    this.skeleton,
    this.onRefresh,
    this.singleColumn = false,
    this.indexedItemBuilder,
    this.refreshEdgeOffset = 0,
    this.gridDelegate,
  });

  @override
  State<PagedMediaList> createState() => _PagedMediaListState();
}

class _PagedMediaListState extends State<PagedMediaList> {
  final ScrollController _controller = ScrollController();
  final List<Comic> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;
  Object? _moreError;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void didUpdateWidget(PagedMediaList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) {
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (_controller.position.extentAfter < 480) {
      _load(reset: false);
    }
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || _loadingMore || !_hasMore)) return;
    final id = ++_requestId;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
        _moreError = null;
      } else {
        _loadingMore = true;
        _moreError = null;
      }
    });
    try {
      final page = await widget.load(reset ? 0 : _items.length);
      if (!mounted || id != _requestId) return;
      setState(() {
        if (reset) _items.clear();
        final seen = _items.map((c) => c.pathWord).toSet();
        for (final c in page.items) {
          if (seen.add(c.pathWord)) _items.add(c);
        }
        // 服务端给空页就别再往下试了（例如写真总榜翻到2044 条之后）
        _hasMore = page.hasMore && page.items.isNotEmpty;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || id != _requestId) return;
      if (kDebugMode) {
        debugPrint('[paged] 加载失败 offset=${reset ? 0 : _items.length}: $error');
      }
      setState(() {
        if (reset) {
          _error = error;
          _hasMore = true;
        } else {
          _moreError = error;
        }
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final filtered =
        widget.filter == null ? _items : _items.where(widget.filter!).toList();
    final filtering = widget.filter != null;
    _fillViewportIfNeeded();

    return RefreshIndicator(
      edgeOffset: widget.refreshEdgeOffset,
      onRefresh: () async {
        HttpCache.instance.markAllStale();
        await Future.wait([
          _load(reset: true),
          if (widget.onRefresh != null) widget.onRefresh!(),
        ]);
      },
      child: CustomScrollView(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          ...widget.headerSlivers,
          if (_error != null && _items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: RequestErrorState(
                error: _error!,
                onRetry: () => _load(reset: true),
              ),
            )
          else if (_loading && _items.isEmpty)
            // 骨架是 box 组件（GridView），必须包成 sliver 再塞进 slivers
            SliverToBoxAdapter(
                child: widget.skeleton ?? const MediaGridSkeleton())
          else if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.inbox_rounded,
                title: widget.emptyTitle,
                message: widget.emptyMessage,
              ),
            )
          else if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.filter_alt_off_rounded,
                title: widget.filteredEmptyTitle ?? widget.emptyTitle,
                message: widget.filteredEmptyMessage ?? widget.emptyMessage,
              ),
            )
          else if (widget.singleColumn)
            // 排行榜：和精选页一致的单列行，行间1dp 分隔线缩进16
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final comic = filtered[i];
                  final row = widget.indexedItemBuilder != null
                      ? widget.indexedItemBuilder!(context, comic, i)
                      : widget.itemBuilder(context, comic);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      row,
                      if (i < filtered.length - 1)
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                  );
                },
                childCount: filtered.length,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              sliver: SliverGrid(
                gridDelegate: widget.gridDelegate ?? kTripleGridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => widget.itemBuilder(context, filtered[i]),
                  childCount: filtered.length,
                ),
              ),
            ),
          if (_items.isNotEmpty && !filtering) _footerSliver(context),
          if (filtered.isNotEmpty && filtering)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                child: Text(
                  t.shelfFilteredHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 内容撑不满一屏时主动补下一页
  void _fillViewportIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _loadingMore || !_hasMore) return;
      if (!_controller.hasClients) return;
      // IndexedStack 里未选中的页面也会 build
      final position = _controller.position;
      if (!position.hasContentDimensions) return;
      if (position.maxScrollExtent <= 0) _load(reset: false);
    });
  }

  Widget _footerSliver(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget child;
    if (_loadingMore) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_moreError != null) {
      child = TextButton.icon(
        onPressed: () => _load(reset: false),
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text(t.loadMoreFailed),
      );
    } else if (!_hasMore) {
      child = Text(
        t.noMore,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.outline),
      );
    } else {
      // 还有下一页但当前没有请求在飞，给一个可点的入口，末尾不要再留一个看不见的 SizedBox
      child = TextButton(
        onPressed: () => _load(reset: false),
        child: Text(t.loadMore),
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: Center(child: child),
      ),
    );
  }
}

/// MediaEntryCard — 三列网格的数据卡片，封面、作者、热度、日期均来自接口
class MediaEntryCard extends StatelessWidget {
  final Comic comic;
  final VoidCallback onTap;
  final String? host;
  final String? badge;

  const MediaEntryCard({
    super.key,
    required this.comic,
    required this.onTap,
    this.host,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final author =
        comic.authors.isEmpty ? comic.statusLabel : comic.authors.join(' / ');
    return RichGridCard(
      title: comic.name,
      author: author,
      coverUrl: resolveImageUrl(comic.cover ?? '', host: host),
      popular: comic.popular > 0 ? _compact(comic.popular) : null,
      date: comic.updatedDateLabel,
      badge: badge,
      onTap: onTap,
    );
  }

  static String _compact(int value) {
    if (value >= 10000) {
      final v = value / 10000;
      return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}万';
    }
    return '$value';
  }
}
