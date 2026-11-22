import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/content.dart';
import '../models/home_index.dart';
import '../models/media_page.dart';
import '../models/sort_spec.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/paged_media.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'catalog_more_screen.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';
import 'topic_list_screen.dart';
import '../services/http_cache.dart';
import '../theme/app_theme.dart';

/// 写真频道顶栏下的四个分段
enum _PhotoSection { home, newest, discover, rank }

/// 写真排行榜并排的三个 tag
enum _PhotoRankTab {
  week('周榜'),
  month('月榜'),
  total('总榜单');

  final String label;

  const _PhotoRankTab(this.label);

  static const List<String> labels = ['周榜', '月榜', '总榜单'];
}

/// CatalogScreen — 轻小说 / 写真 / 动画分类页，列表 + 搜索 + 题材筛选
class CatalogScreen extends StatefulWidget {
  final CatalogKind kind;

  const CatalogScreen({super.key, required this.kind});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _controller = TextEditingController();
  String _keyword = '';
  String _submitted = '';

  /// 排序维度 + 方向，`_sortDesc` 为 true 时 ordering 带负号（降序）
  SortField _sortField = SortField.date;
  bool _sortDesc = true;
  String _themePath = '';
  String _themeLabel = '全部';
  List<ThemeTag> _tags = const [];
  late Future<List<ThemeTag>> _tagFuture;

  /// 小说页固定筛选区高度，用于给列表首屏垫高
  final GlobalKey _fixedHeaderKey = GlobalKey();
  double _fixedHeaderHeight = 0;

  /// 写真「发现 / 排行榜」固定筛选区高度
  final GlobalKey _photoFixedKey = GlobalKey();
  double _photoFixedHeight = 0;

  /// 动画频道 pinned 筛选头高度
  final GlobalKey _stickyFilterKey = GlobalKey();
  double _stickyFilterHeight = 0;

  /// 动画 / 写真频道的聚合内容（轮播 / 推荐 / 专题）
  Future<MediaIndex>? _indexFuture;

  /// 推荐位槽位码，服务端聚合接口不下发，客户端写死
  static const String _recPos = '3200301';

  /// 推荐位一屏3 条，offset 每次推这么多
  static const int _recBatchSize = 3;

  /// 最近一次换一批取到的一屏；null 表示仍在聚合首屏
  List<Comic>? _recItems;
  int _recOffset = 0;

  /// 该推荐位的总条数，0 表示未知
  int _recTotal = 0;
  bool _recShuffling = false;

  /// 写真频道的顶栏分段，只给写真用
  _PhotoSection _section = _PhotoSection.home;

  /// 「发现」选中的标签：0 = 全部，之后对应 `_tags[index - 1]`
  int _photoTagIndex = 0;

  /// 「排行榜」选中的并排 tag
  _PhotoRankTab _rankTab = _PhotoRankTab.week;

  /// 周榜 / 月榜续页的 posts 游标
  final Map<String, int> _rankPostOffset = {};

  MediaKind get _kind => widget.kind.mediaKind;

  /// 当前排序对应的线上 ordering（降序带负号）
  String get _ordering => orderingParam(_sortField, desc: _sortDesc);

  void _setSort(SortField field, bool desc) {
    if (field == _sortField && desc == _sortDesc) return;
    setState(() {
      _sortField = field;
      _sortDesc = desc;
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tagFuture = context.read<Repository>().themeTags(_kind);
    // 写真「首页 / 排行榜」与动画频道需要聚合接口
    if (_kind == MediaKind.animation || _kind == MediaKind.photo) {
      _indexFuture = _loadIndex();
    }
  }

  Future<MediaIndex> _loadIndex() {
    // 重新拉聚合页时，推荐位回到首屏
    _recItems = null;
    _recOffset = 0;
    return context.read<Repository>().mediaIndex(_kind);
  }

  /// 推荐换一批，按 offset 真请求，到末尾回到第一屏
  Future<void> _shuffleRecommend() async {
    if (_recShuffling) return;
    final repo = context.read<Repository>();
    var next = _recOffset + _recBatchSize;
    if (_recTotal > 0 && next >= _recTotal) next = 0;
    setState(() => _recShuffling = true);
    try {
      var batch = await repo.recommendBatch(
        pos: _recPos,
        limit: _recBatchSize,
        offset: next,
      );
      // total 未知时可能已越过末页，回到第一屏再取一次
      if (batch.items.isEmpty && next > 0) {
        next = 0;
        batch = await repo.recommendBatch(
          pos: _recPos,
          limit: _recBatchSize,
          offset: 0,
        );
      }
      if (!mounted) return;
      setState(() {
        _recShuffling = false;
        if (batch.items.isNotEmpty) {
          _recItems = batch.items;
          _recOffset = next;
        }
        if (batch.total > 0) _recTotal = batch.total;
      });
      if (batch.items.isEmpty) _tip('暂时没有更多推荐了');
    } catch (error) {
      if (!mounted) return;
      setState(() => _recShuffling = false);
      _tip('换一批失败：$error');
    }
  }

  void _tip(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _controller.clear();
    setState(() {
      _keyword = '';
      _submitted = '';
    });
  }

  /// 重新拉题材标签，失败后由 FutureBuilder 给出重试入口
  Future<void> _reloadTags() async {
    HttpCache.instance.markAllStale();
    final repo = context.read<Repository>();
    final future = repo.themeTags(_kind);
    final indexFuture =
        (_kind == MediaKind.animation || _kind == MediaKind.photo)
            ? repo.mediaIndex(_kind)
            : null;
    setState(() {
      _tags = const [];
      _tagFuture = future;
      if (indexFuture != null) {
        _indexFuture = indexFuture;
        // 下拉刷新回到首屏，换一批的翻页进度一并清零
        _recItems = null;
        _recOffset = 0;
      }
    });
    try {
      await future;
      if (indexFuture != null) await indexFuture;
    } catch (_) {
      // 失败由 FutureBuilder 渲染成「点击重试」，这里只是别让下拉刷新报错
    }
  }

  void _openTag(ThemeTag tag) {
    CatalogMoreScreen.openFilter(
      context,
      kind: _kind,
      title: '${widget.kind.label} · ${tag.name}',
      theme: _kind == MediaKind.photo ? '' : tag.pathWord,
      tag: _kind == MediaKind.photo ? tag.pathWord : '',
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildLive();
  }

  /// 量固定筛选区高度
  void _measureFixedHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _fixedHeaderKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _fixedHeaderHeight).abs() < 0.5) return;
      setState(() => _fixedHeaderHeight = size.height);
    });
  }

  void _measurePhotoFixed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _photoFixedKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _photoFixedHeight).abs() < 0.5) return;
      setState(() => _photoFixedHeight = size.height);
    });
  }

  /// 量 pinned 筛选头高度，chip 行与排序行高度随字体缩放
  void _measureStickyFilter() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _stickyFilterKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _stickyFilterHeight).abs() < 0.5) return;
      setState(() => _stickyFilterHeight = size.height);
    });
  }

  Widget _buildLive() {
    // 写真频道：顶栏自带分段 tab，内容按分段切换
    if (_kind == MediaKind.photo) return _photoChannel();

    final keyword = _submitted.trim();

    // 动画频道：聚合区随列表滚动，题材 + 排序钉在顶栏下沿
    if (_kind == MediaKind.animation) {
      _measureStickyFilter();
      final barH = MediaQuery.paddingOf(context).top + 64 + 56;
      return Stack(
        children: [
          Positioned.fill(
            child: _mediaList(
                headerSlivers: _animationHeaders(keyword, barH: barH),
                refreshEdgeOffset: barH),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // 顶栏不画底边，与下面钉住的筛选头拼成整块玻璃
            child: _brandBar(glassBorder: false),
          ),
        ],
      );
    }

    // 小说：顶栏 + 筛选区是一整块玻璃，列表首屏垫这段高度
    _measureFixedHeader();
    final barH = MediaQuery.paddingOf(context).top + 64 + 56;
    final topPad = barH + _fixedHeaderHeight;
    return Stack(
      children: [
        Positioned.fill(child: _mediaList(topPad: topPad)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: BrandGlassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brandBar(glassBorder: false, glass: false),
                KeyedSubtree(
                  key: _fixedHeaderKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _themeBar(),
                      SortBar(
                        field: _sortField,
                        desc: _sortDesc,
                        onChanged: _setSort,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 真实分页列表，写真「全新上架」与搜索结果共用
  Widget _mediaList(
      {List<Widget> headerSlivers = const [],
      double topPad = 0,
      double? refreshEdgeOffset}) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final keyword = _submitted.trim();
    final host = repo.imageHost;

    return PagedMediaList(
      resetKey: '$keyword|$_ordering|$_themePath',
      refreshEdgeOffset: refreshEdgeOffset ?? topPad,
      onRefresh: _reloadTags,
      load: (offset) => keyword.isEmpty
          ? repo.filteredPage(
              _kind,
              theme: _kind == MediaKind.photo ? '' : _themePath,
              tag: _kind == MediaKind.photo ? _themePath : '',
              ordering: _ordering,
              offset: offset,
            )
          : repo.searchMedia(_kind, keyword, offset: offset),
      emptyTitle: keyword.isEmpty
          ? (_kind == MediaKind.photo ? t.emptyPhotoTitle : t.emptyNovelTitle)
          : t.emptySearchTitle,
      emptyMessage: keyword.isEmpty
          ? (_kind == MediaKind.photo
              ? t.emptyPhotoMessage
              : t.emptyNovelMessage)
          : t.emptySearchMessage,
      itemBuilder: (context, comic) => MediaEntryCard(
        comic: comic,
        host: host,
        badge: _kind == MediaKind.novel ? null : comic.statusLabel,
        onTap: () => openContentDetail(context, _kind, comic.pathWord),
      ),
      headerSlivers: [
        if (topPad > 0) SliverToBoxAdapter(child: SizedBox(height: topPad)),
        ...headerSlivers,
      ],
    );
  }

  /// 写真频道：顶栏分段 + 首页 / 全新上架 / 发现 / 排行榜四块
  Widget _photoChannel() {
    final searching = _submitted.trim().isNotEmpty;
    final topInset = MediaQuery.paddingOf(context).top;
    final barH = topInset + 64 + 56 + 48;
    final fixed = searching ? null : _photoFixedHeader();
    _measurePhotoFixed();
    final topPad = barH + (fixed == null ? 0 : _photoFixedHeight);

    final Widget body;
    if (searching) {
      body = _mediaList(topPad: topPad);
    } else {
      body = switch (_section) {
        _PhotoSection.home => _photoHome(topPad: topPad),
        _PhotoSection.newest => _photoPagedGrid(
            resetKey: 'photo-newest',
            topPad: topPad,
            load: (offset) =>
                context.read<Repository>().newestPosts(offset: offset),
          ),
        _PhotoSection.discover => _photoDiscoverBody(topPad: topPad),
        _PhotoSection.rank => _photoRankBody(topPad: topPad),
      };
    }

    // 「发现 / 排行榜」的筛选行与顶栏拼成整块玻璃
    final Widget header = fixed == null
        ? _brandBar()
        : BrandGlassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brandBar(glassBorder: false, glass: false),
                KeyedSubtree(key: _photoFixedKey, child: fixed),
              ],
            ),
          );

    return DefaultTabController(
      length: _PhotoSection.values.length,
      child: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(top: 0, left: 0, right: 0, child: header),
        ],
      ),
    );
  }

  /// 写真「发现 / 排行榜」的固定筛选区，其它分段返回 null
  Widget? _photoFixedHeader() {
    switch (_section) {
      case _PhotoSection.discover:
        return FutureBuilder<List<ThemeTag>>(
          future: _tagFuture,
          builder: (context, snap) {
            if (snap.hasData && snap.data!.isNotEmpty) _tags = snap.data!;
            final labels = ['全部', ..._tags.map((tag) => tag.name)];
            final index = _photoTagIndex.clamp(0, labels.length - 1);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: labels.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => Center(
                      child: ChoiceChip(
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(labels[i]),
                        selected: index == i,
                        onSelected: (_) => setState(() => _photoTagIndex = i),
                      ),
                    ),
                  ),
                ),
                SortBar(
                  field: _sortField,
                  desc: _sortDesc,
                  onChanged: _setSort,
                ),
              ],
            );
          },
        );
      case _PhotoSection.rank:
        return DefaultTabController(
          length: _PhotoRankTab.values.length,
          initialIndex: _rankTab.index,
          child: TabBar(
            onTap: (i) => setState(() => _rankTab = _PhotoRankTab.values[i]),
            tabs: [for (final l in _PhotoRankTab.labels) Tab(text: l)],
          ),
        );
      case _PhotoSection.home:
      case _PhotoSection.newest:
        return null;
    }
  }

  /// 写真首页：轮播 + 全新上架三列网格，整页一起滚动
  Widget _photoHome({double topPad = 0}) {
    final host = context.read<Repository>().imageHost;
    final index = _indexFuture ??= _loadIndex();
    return _photoPagedGrid(
      resetKey: 'photo-home',
      topPad: topPad,
      headerSlivers: [
        SliverToBoxAdapter(
          child: FutureBuilder<MediaIndex>(
            future: index,
            builder: (context, snap) {
              // 首屏轮播先给骨架，避免数据到达时页面跳动
              if (!snap.hasData) return const CarouselSkeleton();
              final banners = (snap.data?.banners ?? const <HomeBanner>[])
                  .where((b) => b.isContent)
                  .take(8)
                  .toList();
              // 轮播为空时不留空洞
              if (banners.isEmpty) return const SizedBox(height: 12);
              return CoverCarousel(
                slides: banners
                    .map((b) => CarouselSlide(
                          title: b.title.isEmpty ? b.subtitle : b.title,
                          subtitle: b.subtitle.isEmpty ? null : b.subtitle,
                          imageUrl: resolveImageUrl(b.cover, host: host),
                          onTap: () =>
                              openContentDetail(context, _kind, b.routeId()),
                        ))
                    .toList(),
              );
            },
          ),
        ),
        const SliverToBoxAdapter(child: SectionHeader(title: '全新上架')),
      ],
      load: (offset) => context.read<Repository>().newestPosts(offset: offset),
    );
  }

  /// 写真网格：三列卡片 + 下拉刷新 + 滚到底自动加载
  Widget _photoPagedGrid({
    required String resetKey,
    required Future<MediaPage> Function(int offset) load,
    List<Widget> headerSlivers = const [],
    bool singleColumn = false,
    Widget Function(BuildContext context, Comic comic, int index)?
        indexedItemBuilder,
    double topPad = 0,
  }) {
    final t = AppLocalizations.of(context);
    final host = context.read<Repository>().imageHost;
    return PagedMediaList(
      resetKey: resetKey,
      refreshEdgeOffset: topPad,
      onRefresh: _reloadTags,
      load: load,
      headerSlivers: [
        if (topPad > 0) SliverToBoxAdapter(child: SizedBox(height: topPad)),
        ...headerSlivers,
      ],
      emptyTitle: t.emptyPhotoTitle,
      emptyMessage: t.emptyPhotoMessage,
      singleColumn: singleColumn,
      indexedItemBuilder: indexedItemBuilder,
      skeleton: singleColumn ? const RankListSkeleton(count: 8) : null,
      itemBuilder: (context, comic) => MediaEntryCard(
        comic: comic,
        host: host,
        // 写真没有「连载中」概念，卡片不带状态角标
        onTap: () => openContentDetail(context, _kind, comic.pathWord),
      ),
    );
  }

  /// 排行榜单列行，与精选页 RankRow 同版式
  Widget _photoRankRow(BuildContext context, Comic comic, int index) {
    final host = context.read<Repository>().imageHost;
    return RankRow(
      rank: index + 1,
      title: comic.name,
      author: comic.authorLabel,
      popular: comic.popularLabel,
      coverUrl: resolveImageUrl(comic.cover ?? '', host: host),
      onTap: () => openContentDetail(context, _kind, comic.pathWord),
    );
  }

  /// 写真「发现」：题材标签 + 排序 + 三列网格
  Widget _photoDiscoverBody({double topPad = 0}) {
    return FutureBuilder<List<ThemeTag>>(
      future: _tagFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: EdgeInsets.only(top: topPad),
            child: RequestErrorState(error: snap.error!, onRetry: _reloadTags),
          );
        }
        if (snap.hasData && snap.data!.isNotEmpty) _tags = snap.data!;
        final labels = ['全部', ..._tags.map((tag) => tag.name)];
        final index = _photoTagIndex.clamp(0, labels.length - 1);
        final tagWord =
            index == 0 || _tags.isEmpty ? '' : _tags[index - 1].pathWord;
        return _photoPagedGrid(
          topPad: topPad,
          resetKey: 'photo-discover|$tagWord|$_ordering',
          load: (offset) => context.read<Repository>().photoPage(
                tag: tagWord,
                ordering: _ordering,
                offset: offset,
              ),
        );
      },
    );
  }

  /// 写真「排行榜」：周榜 / 月榜 / 总榜单，单列榜单行
  Widget _photoRankBody({double topPad = 0}) {
    return _photoRankList(topPad: topPad);
  }

  Widget _photoRankList({double topPad = 0}) {
    switch (_rankTab) {
      case _PhotoRankTab.week:
        return _photoIndexRank('rankWeekPosts', 'photo-rank-week',
            topPad: topPad);
      case _PhotoRankTab.month:
        return _photoIndexRank('rankMonthPosts', 'photo-rank-month',
            topPad: topPad);
      case _PhotoRankTab.total:
        return _photoPagedGrid(
          resetKey: 'photo-rank-total',
          topPad: topPad,
          singleColumn: true,
          indexedItemBuilder: _photoRankRow,
          load: (offset) => context
              .read<Repository>()
              .photoPage(ordering: '-popular', offset: offset),
        );
    }
  }

  Widget _photoIndexRank(String key, String resetKey, {double topPad = 0}) {
    return _photoPagedGrid(
      resetKey: resetKey,
      topPad: topPad,
      singleColumn: true,
      indexedItemBuilder: _photoRankRow,
      load: (offset) async {
        final repo = context.read<Repository>();
        final seed = await _rankSeed(key);
        if (offset == 0) {
          _rankPostOffset[resetKey] = 0;
          return MediaPage(
            kind: MediaKind.photo,
            items: seed,
            // 服务端这两个榜只给6 条预览，total 给个大值让它一直 hasMore
            total: seed.isEmpty ? 4000 : 4000 + seed.length,
            offset: 0,
            limit: seed.isEmpty ? Repository.photoPageSize : seed.length,
          );
        }
        final postsOffset = _rankPostOffset[resetKey] ?? 0;
        final page = await repo.photoPage(
          ordering: '-popular',
          offset: postsOffset,
          limit: Repository.photoPageSize,
        );
        _rankPostOffset[resetKey] = postsOffset + Repository.photoPageSize;
        return page;
      },
    );
  }

  /// 周榜 / 月榜的6 条预览（来自 postIndex），只取一次
  Future<List<Comic>> _rankSeed(String key) async {
    final future = _indexFuture ??= _loadIndex();
    try {
      final index = await future;
      return index.groups.where((g) => g.key == key).firstOrNull?.items ??
          const <Comic>[];
    } catch (_) {
      return const <Comic>[];
    }
  }

  /// 动画列表上方的聚合区块，[barH] 是顶栏实际高度
  List<Widget> _animationHeaders(String keyword, {double barH = 0}) {
    return [
      if (barH > 0)
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedGapDelegate(barH),
        ),
      if (keyword.isEmpty)
        SliverToBoxAdapter(
          child: FutureBuilder<MediaIndex>(
            future: _indexFuture,
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Center(
                    child: ActionChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      avatar: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('推荐内容加载失败，点击重试'),
                      onPressed: () =>
                          setState(() => _indexFuture = _loadIndex()),
                    ),
                  ),
                );
              }
              if (!snap.hasData) return const _AnimationHeaderSkeleton();
              return _animationSections(snap.data!);
            },
          ),
        ),
      _stickyFilterSliver(),
    ];
  }

  /// 题材胶囊 + 排序，滚到顶后钉在顶栏下沿
  Widget _stickyFilterSliver() {
    final scrolled = BrandBarScrollScope.scrolledOf(context);
    final panel = BrandGlassPanel(
      border: scrolled,
      // 缺这层 Align 量到的是头高，而非内容真实高度
      child: Align(
        alignment: Alignment.topCenter,
        child: Column(
          key: _stickyFilterKey,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _themeBar(),
            SortBar(
              field: _sortField,
              desc: _sortDesc,
              onChanged: _setSort,
            ),
          ],
        ),
      ),
    );
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedFilterDelegate(
        // 量到真值前用92 兜底（chip 行52 + 排序行40）
        height: _stickyFilterHeight > 0 ? _stickyFilterHeight : 92,
        child: panel,
      ),
    );
  }

  /// 动画首页版式：轮播 → 推荐三卡 → 专题横滑
  Widget _animationSections(MediaIndex index) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    final banners = index.banners.where((b) => b.isContent).take(8).toList();
    final group =
        index.groups.where((g) => g.key == 'recCartoons').firstOrNull ??
            (index.groups.isEmpty ? null : index.groups.first);
    // 首屏用聚合接口的三条，换一批后改用 recs 返回的一屏
    if (group != null && group.total > 0) _recTotal = group.total;
    final recItems = _recItems ?? group?.items ?? const <Comic>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (banners.isNotEmpty)
          CoverCarousel(
            slides: banners
                .map((b) => CarouselSlide(
                      title: b.title.isEmpty ? b.subtitle : b.title,
                      subtitle: b.subtitle.isEmpty ? null : b.subtitle,
                      imageUrl: resolveImageUrl(b.cover, host: host),
                      onTap: () => _openBanner(b),
                    ))
                .toList(),
          ),
        if (group != null && recItems.isNotEmpty) ...[
          SectionHeader(title: group.title),
          RecommendRow(
            pool: recItems,
            batch: 0,
            host: host,
            showAuthor: false,
            showDate: true,
            onTap: (c) => openContentDetail(context, _kind, c.pathWord),
          ),
          MoreActions(
            moreLabel: t.homeMore,
            onMore: () => CatalogMoreScreen.openLoader(
              context,
              title: '${group.title} · 全部',
              kind: _kind,
              load: (offset) => repo.filteredPage(
                _kind,
                ordering: 'popular',
                offset: offset,
              ),
            ),
            shuffleLabel: t.homeRefreshBatch,
            onShuffle: _shuffleRecommend,
            shuffling: _recShuffling,
          ),
        ],
        if (index.topics.isNotEmpty) ...[
          SectionHeader(
            title: t.sectionTopics,
            actionLabel: t.viewAll,
            padding: const EdgeInsets.fromLTRB(16, 20, 8, 16),
            onAction: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TopicListScreen(kind: _kind),
              ),
            ),
          ),
          TopicStrip(
            slides: index.topics
                .map((topic) => TopicSlide(
                      title: topic.period.isEmpty
                          ? topic.title
                          : '${topic.title} · ${topic.period}',
                      imageUrl: resolveImageUrl(topic.cover, host: host),
                    ))
                .toList(),
            onSlideTap: (i) => CatalogMoreScreen.openTopicContents(
              context,
              pathWord: index.topics[i].pathWord,
              title: index.topics[i].title,
              kind: _kind,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// 轮播按服务端 type 打开对应详情（5 动画 / 130 写真 / 1 漫画）
  void _openBanner(HomeBanner banner) {
    final id = banner.routeId();
    if (id.isEmpty) return;
    switch (banner.target) {
      case BannerTarget.comic:
        openComicDetail(context, id);
      case BannerTarget.animation:
        openContentDetail(context, MediaKind.animation, id);
      case BannerTarget.photo:
        openContentDetail(context, MediaKind.photo, id);
      case BannerTarget.external:
      case BannerTarget.unknown:
        break;
    }
  }

  /// 题材标签横滑行，选中后以 path_word 作为服务端筛选值
  Widget _themeBar() {
    return FutureBuilder<List<ThemeTag>>(
      future: _tagFuture,
      builder: (context, snap) {
        if (snap.hasData && snap.data!.isNotEmpty) _tags = snap.data!;
        if (snap.hasError || (!snap.hasData && _tags.isEmpty)) {
          if (!snap.hasData && !snap.hasError) {
            return const _ThemeBarSkeleton();
          }
          return SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.base, vertical: 2),
              children: [
                ActionChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  avatar: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('标签加载失败，点击重试'),
                  onPressed: _reloadTags,
                ),
              ],
            ),
          );
        }
        return SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.base, vertical: 2),
            itemCount: 1 + _tags.take(24).length + (_tags.length > 24 ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, i) {
              if (i == 0) {
                return ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text('全部'),
                  selected: _themeLabel == '全部',
                  onSelected: (_) => setState(() {
                    _themeLabel = '全部';
                    _themePath = '';
                  }),
                );
              }
              final tagIndex = i - 1;
              if (tagIndex < _tags.take(24).length) {
                final tag = _tags[tagIndex];
                return ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(tag.name),
                  selected: _themeLabel == tag.name,
                  onSelected: (_) => setState(() {
                    _themeLabel = tag.name;
                    _themePath = tag.pathWord;
                  }),
                );
              }
              return ActionChip(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: const Icon(Icons.more_horiz_rounded, size: 16),
                label: const Text('全部题材'),
                onPressed: _showAllTags,
              );
            },
          ),
        );
      },
    );
  }

  void _showAllTags() {
    final scheme = Theme.of(context).colorScheme;
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
              child: Text('${widget.kind.label}题材（${_tags.length}）',
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _tags
                  .map((tag) => ActionChip(
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text('${tag.name} · ${tag.count}',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
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

  Widget _brandBar({bool glassBorder = true, bool glass = true}) {
    final t = AppLocalizations.of(context);
    final hint = switch (_kind) {
      MediaKind.novel => t.searchHintNovel,
      MediaKind.animation => t.searchHintAnimation,
      _ => widget.kind.searchHint,
    };
    return BrandBar(
      title: BrandTitle(name: widget.kind.label),
      glassBorder: glassBorder,
      glass: glass,
      search: BrandSearchField(
        hint: hint,
        controller: _controller,
        onChanged: (v) => setState(() => _keyword = v),
        onSubmitted: (v) => setState(() => _submitted = v),
      ),
      actions: [
        // 有搜索词时显示清除键
        if (_keyword.isNotEmpty || _submitted.isNotEmpty)
          BrandIconButton(
            icon: Icons.close_rounded,
            tooltip: t.clearSearch,
            onPressed: _clearSearch,
          ),
      ],
      bottom: _kind == MediaKind.photo
          ? BrandTabBar(
              labels: const ['首页', '全新上架', '发现', '排行榜'],
              onTap: (i) => setState(() => _section = _PhotoSection.values[i]),
            )
          : null,
    );
  }
}

/// _AnimationHeaderSkeleton — 动画聚合区首屏骨架
class _AnimationHeaderSkeleton extends StatelessWidget {
  const _AnimationHeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与真实 CoverCarousel 同版式，避免数据到达时横幅内缩
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SkeletonBox(
              width: double.infinity,
              height: 152,
              radius: 12,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (i) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: SkeletonBox(
                  width: i == 0 ? 15 : 6,
                  height: 6,
                  radius: 6,
                ),
              );
            }),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: SkeletonBox(
              width: 96,
              height: 22,
              radius: 6,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const AspectRatio(
                          aspectRatio: 3 / 4,
                          child: SkeletonBox(
                            width: double.infinity,
                            radius: 12,
                          ),
                        ),
                        const SizedBox(height: 7),
                        const SkeletonBox(
                          width: double.infinity,
                          height: 14,
                          radius: 4,
                        ),
                        const SizedBox(height: 6),
                        SkeletonBox(
                          width: 60,
                          height: 12,
                          radius: 4,
                        ),
                        const SizedBox(height: 6),
                        SkeletonBox(
                          width: 80,
                          height: 10,
                          radius: 4,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: SkeletonBox(
                    height: 46,
                    radius: 12,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SkeletonBox(
                    height: 46,
                    radius: 12,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: SkeletonBox(
              width: 80,
              height: 22,
              radius: 6,
            ),
          ),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 2,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) => const SkeletonBox(
                width: 220,
                height: 120,
                radius: 12,
              ),
            ),
          ),
          // 与真实版式同高，数据到达时不跳
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// _ThemeBarSkeleton — 题材标签行首屏骨架
class _ThemeBarSkeleton extends StatelessWidget {
  const _ThemeBarSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Shimmer(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.base, vertical: 2),
          itemCount: 5,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, i) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SkeletonBox(
              width: 64,
              height: 32,
              radius: BorderRadius.all(Radius.circular(AppShape.sm)),
            ),
          ),
        ),
      ),
    );
  }
}

/// _PinnedGapDelegate — 顶栏位置上的透明 pinned 占位，占住 height 高度
class _PinnedGapDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedGapDelegate(this.height);

  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(height: height);

  @override
  bool shouldRebuild(_PinnedGapDelegate oldDelegate) =>
      oldDelegate.height != height;
}

/// _PinnedFilterDelegate — 钉在顶栏下沿的筛选头，高度固定不折叠
class _PinnedFilterDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedFilterDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(height: height, child: child);

  @override
  bool shouldRebuild(_PinnedFilterDelegate oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}
