import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/content.dart';
import '../models/media_page.dart';
import '../models/sort_spec.dart';
import '../services/http_cache.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'comic_detail_screen.dart';

/// DiscoverScreen — 独立发现页：顶栏自带搜索框，结果区复用 [DiscoverView]
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final ValueNotifier<String> _query = ValueNotifier<String>('');
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(_syncController);
  }

  void _syncController() {
    if (_controller.text != _query.value) {
      _controller.text = _query.value;
    }
  }

  @override
  void dispose() {
    _query.removeListener(_syncController);
    _query.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          BrandBar(
            title: const BrandTitle(name: '发现'),
            search: BrandSearchField(
              hint: '搜索漫画名、作者或题材',
              controller: _controller,
              onChanged: (v) => _query.value = v,
            ),
            actions: [
              ValueListenableBuilder<String>(
                valueListenable: _query,
                builder: (_, q, __) => q.isEmpty
                    ? const SizedBox.shrink()
                    : BrandIconButton(
                        icon: Icons.close_rounded,
                        tooltip: '清除搜索',
                        onPressed: () => _query.value = '',
                      ),
              ),
            ],
          ),
          Expanded(child: DiscoverView(query: _query)),
        ],
      ),
    );
  }
}

/// DiscoverView — 可嵌入的发现视图，题材与地区筛选 + 排序栏 + 三列结果网格
class DiscoverView extends StatefulWidget {
  final ValueNotifier<String> query;

  /// 顶栏叠在页面上的高度：首屏先垫这段，滚动后内容才会走到毛玻璃背后
  final double topPad;

  const DiscoverView({super.key, required this.query, this.topPad = 0});

  @override
  State<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<DiscoverView>
    with AutomaticKeepAliveClientMixin {
  static const List<String> _regions = ['全部', '日漫', '韩漫', '美漫', '已完结'];

  /// 连续自动续页的上限：地区 / 进度是本地过滤，日漫在一页21 条里可能只命中2 条
  static const int _maxAutoPages = 8;

  String _keyword = '';
  String _themeLabel = '全部';
  String _themePath = '';
  String _region = '全部';

  /// 排序维度 + 方向：`_sortDesc` 为 true 时线上 `ordering` 带负号
  SortField _sortField = SortField.date;
  bool _sortDesc = true;

  final ScrollController _controller = ScrollController();

  /// 发现页固定筛选区：不随列表滚，高度实测后垫给列表首屏，滚动时网格从它底下穿过
  final GlobalKey _filterKey = GlobalKey();
  double _filterHeight = 0;
  final List<Comic> _items = <Comic>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;
  Object? _moreError;
  int _requestId = 0;
  int _autoPages = 0;
  bool _fillScheduled = false;

  /// 题材筛选来自真实的 `/api/v3/theme/comic/count`
  late Future<List<ThemeTag>> _tagFuture;
  List<ThemeTag> _tags = const [];

  List<Comic> get _filtered => _applyRegion(_items);

  /// 首屏：还没拿到任何数据、也没有错误 → 整页骨架
  bool get _firstLoad => _loading && _items.isEmpty && _error == null;

  @override
  bool get wantKeepAlive => true;

  void _measureFilter() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _filterKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _filterHeight).abs() < 0.5) return;
      setState(() => _filterHeight = size.height);
    });
  }

  @override
  void initState() {
    super.initState();
    _keyword = widget.query.value.trim();
    _tagFuture = context.read<Repository>().themeTags(MediaKind.comic);
    _controller.addListener(_onScroll);
    widget.query.addListener(_onQueryChanged);
    _load(reset: true);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    widget.query.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    if (!mounted) return;
    final next = widget.query.value.trim();
    if (next == _keyword) return;
    setState(() => _keyword = next);
    _reload();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    // 用户自己往下滚，重新给他一拨自动续页的额度
    _autoPages = 0;
    _maybeLoadMore();
  }

  Future<MediaPage> _fetch(int offset) {
    final repo = context.read<Repository>();
    if (_keyword.isNotEmpty) {
      return repo.searchPage(_keyword, offset: offset);
    }
    return repo.comicPage(
      theme: _themePath,
      ordering: orderingParam(_sortField, desc: _sortDesc),
      offset: offset,
    );
  }

  List<Comic> _applyRegion(List<Comic> source) {
    if (_region == '日漫') {
      return source.where((c) => c.region == 'jp').toList();
    }
    if (_region == '韩漫') {
      return source.where((c) => c.region == 'kr').toList();
    }
    if (_region == '美漫') {
      return source.where((c) => c.region == 'en' || c.region == 'us').toList();
    }
    if (_region == '已完结') {
      return source.where((c) => c.statusLabel == '已完结').toList();
    }
    return source;
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || _loadingMore || !_hasMore)) return;
    final id = ++_requestId;
    setState(() {
      if (reset) {
        _loading = true;
        // 重置时把在飞的下一页也作废，否则 _loadingMore 会一直挂着
        _loadingMore = false;
        _error = null;
        _moreError = null;
        _autoPages = 0;
      } else {
        _loadingMore = true;
        _moreError = null;
      }
    });
    try {
      final page = await _fetch(reset ? 0 : _items.length);
      if (!mounted || id != _requestId) return;
      setState(() {
        if (reset) _items.clear();
        final seen = _items.map((c) => c.pathWord).toSet();
        var added = 0;
        for (final c in page.items) {
          if (seen.add(c.pathWord)) {
            _items.add(c);
            added++;
          }
        }
        // added == 0：服务端忽略 offset 或整页重复，再翻也不会前进
        _hasMore = page.hasMore && page.items.isNotEmpty && added > 0;
        _loading = false;
        _loadingMore = false;
      });
      _scheduleFillCheck();
    } catch (error) {
      if (!mounted || id != _requestId) return;
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

  /// 接近末尾 / 内容撑不满一屏时自动续页
  void _maybeLoadMore() {
    if (!mounted) return;
    if (_loading || _loadingMore || !_hasMore) return;
    // 上一页失败后等用户点重试，不要自动重试成死循环
    if (_moreError != null) return;
    if (_items.isEmpty) return;
    if (_autoPages >= _maxAutoPages) return;
    if (!_controller.hasClients) {
      _scheduleFillCheck();
      return;
    }
    if (_controller.position.extentAfter > 240) return;
    _autoPages++;
    _load(reset: false);
  }

  void _scheduleFillCheck() {
    if (_fillScheduled) return;
    _fillScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fillScheduled = false;
      _maybeLoadMore();
    });
  }

  /// 换题材 / 地区 / 排序 / 关键词后重新从第一页拉
  void _reload() {
    if (_controller.hasClients) _controller.jumpTo(0);
    _load(reset: true);
  }

  /// 下拉刷新：结果和题材标签一起重拉，并抬高缓存水位线强制走网络
  Future<void> _refreshAll() async {
    HttpCache.instance.markAllStale();
    final repo = context.read<Repository>();
    final tags = repo.themeTags(MediaKind.comic);
    // 注意用块体：箭头函数会把赋值结果（Future）当作返回值，setState 会断言失败
    setState(() {
      _tagFuture = tags;
    });
    await Future.wait([
      _load(reset: true),
      tags.catchError((_) => <ThemeTag>[]),
    ]);
  }

  void _clearAll() {
    widget.query.value = '';
    setState(() {
      _keyword = '';
      _themeLabel = '全部';
      _themePath = '';
      _region = '全部';
      _sortField = SortField.date;
      _sortDesc = true;
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final host = context.read<Repository>().imageHost;

    // 首屏整页骨架（内部已包含题材行占位）
    if (_firstLoad) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPad),
        child: const SingleChildScrollView(
          physics: NeverScrollableScrollPhysics(),
          child: DiscoverSkeleton(),
        ),
      );
    }

    if (!_firstLoad && _items.isNotEmpty) _scheduleFillCheck();

    final filtered = _filtered;
    _measureFilter();
    final topPad = widget.topPad + _filterHeight;

    return Stack(
      children: [
        Positioned.fill(
          child: RefreshIndicator(
            edgeOffset: topPad,
            onRefresh: _refreshAll,
            child: CustomScrollView(
              controller: _controller,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (topPad > 0)
                  SliverToBoxAdapter(child: SizedBox(height: topPad)),
                ..._resultSlivers(filtered, host),
              ],
            ),
          ),
        ),
        // 题材 / 地区 / 排序全部是胶囊且固定不滚
        Positioned(
          top: widget.topPad,
          left: 0,
          right: 0,
          child: BrandGlassPanel(
            child: KeyedSubtree(
              key: _filterKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_keyword.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Chip(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text('搜索：$_keyword'),
                          onDeleted: _clearAll,
                          deleteIcon: const Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                    ),
                  _themeFilterRow(),
                  _regionChipRow(),
                  SortBar(
                    field: _sortField,
                    desc: _sortDesc,
                    onChanged: (field, desc) {
                      if (field == _sortField && desc == _sortDesc) return;
                      setState(() {
                        _sortField = field;
                        _sortDesc = desc;
                      });
                      _reload();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 地区 / 进度行：原来是一排可变色的纯文字 tab，现在统一成无边框胶囊
  Widget _regionChipRow() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _regions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final label = _regions[i];
          return Center(
            child: ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              label: Text(label),
              selected: _region == label,
              onSelected: (_) {
                if (label == _region) return;
                // 地区 / 进度是本地过滤，不用重新请求：保留已加载的页，过滤后不够一屏就继续往下补页
                setState(() {
                  _region = label;
                  _autoPages = 0;
                });
                _scheduleFillCheck();
              },
            ),
          );
        },
      ),
    );
  }

  List<Widget> _resultSlivers(List<Comic> filtered, String? host) {
    final t = AppLocalizations.of(context);
    if (_error != null && _items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: RequestErrorState(
            error: _error!,
            onRetry: () => _load(reset: true),
          ),
        ),
      ];
    }
    if (_items.isEmpty && !_hasMore) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: '没有找到相关漫画',
            message: '换个关键词，或把题材 / 地区筛选切回「全部」',
            action: FilledButton.tonal(
              onPressed: _clearAll,
              child: const Text('清除筛选条件'),
            ),
          ),
        ),
      ];
    }
    return [
      if (filtered.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          sliver: SliverGrid(
            gridDelegate: kTripleGridDelegate,
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final c = filtered[i];
                return RichGridCard(
                  title: c.name,
                  author: c.authorLabel,
                  popular: c.popularLabel,
                  date: c.updatedDateLabel,
                  coverUrl: resolveImageUrl(c.cover ?? '', host: host),
                  badge: c.statusLabel,
                  onTap: () => openComicDetail(context, c.pathWord),
                );
              },
              childCount: filtered.length,
            ),
          ),
        )
      else
        // 当前筛选一页都没命中，但服务端还有数据：给一句话，别只剩空白
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
            child: Text(
              '当前筛选下这一批没有结果，可以继续加载后面的内容',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ),
      _footerSliver(t),
    ];
  }

  /// 列表末尾：加载中转圈 / 失败重试 / 加载更多 / 到底提示
  Widget _footerSliver(AppLocalizations t) {
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
      child = TextButton(
        onPressed: () {
          _autoPages = 0;
          _load(reset: false);
        },
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

  /// 题材行：`GET /api/v3/theme/comic/count` 下发72 个题材
  Widget _themeFilterRow() {
    return FutureBuilder<List<ThemeTag>>(
      future: _tagFuture,
      builder: (context, snap) {
        if (snap.hasData && snap.data!.isNotEmpty) _tags = snap.data!;
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('题材标签加载失败，可继续浏览全部漫画',
                      style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () {
                    final repo = context.read<Repository>();
                    setState(() {
                      _tagFuture = repo.themeTags(MediaKind.comic);
                    });
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        if (!snap.hasData) {
          // 题材标签重试 / 慢响应时也用与真实 tab 同构的骨架，不再退回顶部进度条
          return const TextTabsSkeleton();
        }
        final labels = <String>['全部', ..._tags.map((t) => t.name)];
        final selected = labels.contains(_themeLabel) ? _themeLabel : '全部';
        return SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: labels.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final label = labels[i];
              return Center(
                child: ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(label),
                  selected: selected == label,
                  onSelected: (_) {
                    if (label == _themeLabel) return;
                    final tag = _tags.where((t) => t.name == label).toList();
                    setState(() {
                      _themeLabel = label;
                      _themePath = tag.isEmpty ? '' : tag.first.pathWord;
                      _keyword = '';
                      widget.query.value = '';
                    });
                    _reload();
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}
