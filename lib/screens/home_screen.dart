import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/home_index.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/paged_media.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'comic_detail_screen.dart';
import 'catalog_more_screen.dart';
import 'content_detail_screen.dart';
import 'discover_screen.dart';
import 'media_list_screen.dart';
import 'recommendations_screen.dart';
import 'topic_list_screen.dart';
import '../services/http_cache.dart';
import '../utils/frame_kick.dart';

/// HomeScreen — 首页，推荐位 + 分类入口 + 分页列表
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final ValueNotifier<String> _query = ValueNotifier<String>('');
  final TextEditingController _searchController = TextEditingController();
  late Future<HomeIndex> _future;
  late Future<MediaPage> _newest;
  int _refreshTick = 0;

  /// 内容区当前页；不要用 `_tabs.index` 判断，TabBar 回调前它已是新值
  int _tabIndex = 0;

  /// 已访问过的 tab，IndexedStack 只挂载这些
  final Set<int> _visited = {0};

  /// 专题 / 已完结 / 为你推荐「换一批」的分页 offset 与覆盖数据
  int _topicOffset = 0;
  int _finishOffset = 0;
  List<HomeTopic>? _topicOverride;
  List<Comic>? _finishOverride;
  bool _shufflingTopics = false;
  bool _shufflingFinish = false;

  /// 为你推荐的推荐位槽位码，服务端据此决定返回哪一组内容
  static const String _recommendPos = '3200102';
  static const int _recommendLimit = 3;
  int _recommendOffset = 0;
  List<Comic>? _recommendOverride;
  bool _shufflingRecommend = false;

  /// 顶栏实际高度（含状态栏），用于给列表首屏垫高
  final GlobalKey _barKey = GlobalKey();
  double _barHeight = 0;

  void _measureBar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _barKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _barHeight).abs() < 0.5) return;
      final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
      debugPrint('[homebar] h=${size.height} '
          'top=${box?.localToGlobal(Offset.zero).dy}');
      setState(() => _barHeight = size.height);
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // TabBar 只画指示器，内容切页用 IndexedStack，不需要滚动动画
    _tabs = TabController(
      length: 4,
      vsync: this,
      animationDuration: Duration.zero,
    );
    _future = _track(_load());
    _newest = _track(context.read<Repository>().newestComics(offset: 0))
      ..ignore();
  }

  /// 切换内容区页面，并把 TabBar 指示器对齐到新 index
  void _onTabTap(int index) {
    if (_tabIndex == index && _visited.contains(index)) return;
    setState(() {
      _visited.add(index);
      _tabIndex = index;
      if (_tabs.index != index) _tabs.index = index;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _query.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<HomeIndex> _load() => context.read<Repository>().homeIndex();

  /// 包一层：future 完成后强制出一帧，规避虚拟屏 vsync 不稳的白屏
  Future<T> _track<T>(Future<T> future) => kickOnDone(future);

  Future<void> _refresh() async {
    // 主动刷新：抬高缓存水位线，这次一定走网络
    HttpCache.instance.markAllStale();
    final future = _track(_load());
    final newest = _track(context.read<Repository>().newestComics(offset: 0))
      ..ignore();
    setState(() {
      _future = future;
      _newest = newest;
      _topicOffset = 0;
      _finishOffset = 0;
      _recommendOffset = 0;
      _topicOverride = null;
      _finishOverride = null;
      _recommendOverride = null;
      _refreshTick++;
    });
    await future;
  }

  void _retry() {
    setState(() {
      _future = _track(_load());
      _newest = _track(context.read<Repository>().newestComics(offset: 0))
        ..ignore();
      _refreshTick++;
    });
  }

  /// 专题换一批，到底后回到第一页
  Future<void> _shuffleTopics() async {
    if (_shufflingTopics) return;
    setState(() => _shufflingTopics = true);
    final repo = context.read<Repository>();
    try {
      var next = _topicOffset + 4;
      var list = await repo.topics(offset: next);
      if (list.length < 4) {
        next = 0;
        final first = await repo.topics(offset: 0);
        if (first.isNotEmpty) list = first;
      }
      if (!mounted) return;
      setState(() {
        _topicOffset = next;
        if (list.isNotEmpty) _topicOverride = list;
      });
    } catch (error) {
      if (mounted) _showShuffleError(error);
    } finally {
      if (mounted) setState(() => _shufflingTopics = false);
    }
  }

  /// 为你推荐换一批，按 offset 真请求，到底后回到第一页
  Future<void> _shuffleRecommend() async {
    if (_shufflingRecommend) return;
    setState(() => _shufflingRecommend = true);
    final repo = context.read<Repository>();
    try {
      var next = _recommendOffset + _recommendLimit;
      var batch = await repo.recommendBatch(
        pos: _recommendPos,
        limit: _recommendLimit,
        offset: next,
      );
      if (batch.items.length < _recommendLimit) {
        next = 0;
        final first = await repo.recommendBatch(
          pos: _recommendPos,
          limit: _recommendLimit,
          offset: 0,
        );
        if (first.items.isNotEmpty) batch = first;
      }
      if (!mounted) return;
      setState(() {
        _recommendOffset = next;
        if (batch.items.isNotEmpty) _recommendOverride = batch.items;
      });
    } catch (error) {
      if (mounted) _showShuffleError(error);
    } finally {
      if (mounted) setState(() => _shufflingRecommend = false);
    }
  }

  /// 已完结换一批，到底后回到第一页
  Future<void> _shuffleFinish() async {
    if (_shufflingFinish) return;
    setState(() => _shufflingFinish = true);
    final repo = context.read<Repository>();
    try {
      var next = _finishOffset + 6;
      var page = await repo.finishedComics(offset: next);
      if (page.items.length < 6) {
        next = 0;
        final first = await repo.finishedComics(offset: 0);
        if (first.items.isNotEmpty) page = first;
      }
      if (!mounted) return;
      setState(() {
        _finishOffset = next;
        if (page.items.isNotEmpty) _finishOverride = page.items;
      });
    } catch (error) {
      if (mounted) _showShuffleError(error);
    } finally {
      if (mounted) setState(() => _shufflingFinish = false);
    }
  }

  void _showShuffleError(Object error) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    final info = describeRequestError(t, error);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(info.message)));
  }

  void _openMoreUpdates() {
    final repo = context.read<Repository>();
    final t = AppLocalizations.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaListScreen(
          title: t.sectionUpdates,
          emptyTitle: t.emptyUpdatesTitle,
          emptyMessage: t.emptyUpdatesMessage,
          load: (offset) => repo.newestComics(offset: offset),
        ),
      ),
    );
  }

  void _openMoreFinish() {
    final repo = context.read<Repository>();
    final t = AppLocalizations.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaListScreen(
          title: t.sectionFinish,
          emptyTitle: t.emptyUpdatesTitle,
          emptyMessage: t.emptyUpdatesMessage,
          load: (offset) => repo.finishedComics(offset: offset, limit: 21),
        ),
      ),
    );
  }

  void _openTopics() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TopicListScreen()),
    );
  }

  void _openRecommendations() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RecommendationsScreen()),
    );
  }

  void _openComic(BuildContext context, Comic comic) =>
      openComicDetail(context, comic.pathWord);

  /// 轮播按服务端 `type` 打开详情：1 漫画 / 5 动画 / 130 写真
  void _openBanner(BuildContext context, HomeBanner banner) {
    final id = banner.routeId();
    if (!banner.isContent) {
      _showBannerInfo(context, banner);
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
        _showBannerInfo(context, banner);
    }
  }

  /// 无有效路由标识时只展示标题 / 简介，不跳转
  void _showBannerInfo(BuildContext context, HomeBanner banner) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(banner.title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
              if (banner.subtitle.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(banner.subtitle,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    // 顶栏叠在内容上方，列表首屏先垫一段顶栏高度
    _measureBar();
    final topPad = _barHeight > 0
        ? _barHeight
        : MediaQuery.paddingOf(context).top + 64 + 56 + 48;
    return FutureBuilder<HomeIndex>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final Widget bar = BrandBar(
          key: _barKey,
          title: BrandTitle(name: t.appName, version: AppInfo.versionLabel),
          // 发现 / 排行榜的筛选区在下方接着铺同一层玻璃，这里不画底边
          glassBorder: _tabIndex != 2 && _tabIndex != 3,
          search: BrandSearchField(
            hint: t.searchHintHome,
            controller: _searchController,
            onChanged: (v) => _query.value = v,
            onSubmitted: (v) {
              _query.value = v;
              _onTabTap(2);
            },
          ),
          actions: const [],
          bottom: BrandTabBar(
            controller: _tabs,
            labels: const ['首页', '全新上架', '发现', '排行榜'],
            onTap: _onTabTap,
          ),
        );
        // 发现 / 排行榜：顶栏与筛选区共用一套玻璃底，拼起来看不到接缝
        final Widget header = (_tabIndex == 2 || _tabIndex == 3)
            ? BrandGlassPanel(
                border: false,
                child: BrandBar(
                  key: _barKey,
                  title: BrandTitle(name: t.appName, version: AppInfo.versionLabel),
                  glass: false,
                  glassBorder: false,
                  search: BrandSearchField(
                    hint: t.searchHintHome,
                    controller: _searchController,
                    onChanged: (v) => _query.value = v,
                    onSubmitted: (v) {
                      _query.value = v;
                      _onTabTap(2);
                    },
                  ),
                  actions: const [],
                  bottom: BrandTabBar(
                    controller: _tabs,
                    labels: const ['首页', '全新上架', '发现', '排行榜'],
                    onTap: _onTabTap,
                  ),
                ),
              )
            : bar;
        return Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _tabIndex,
                sizing: StackFit.expand,
                children: List<Widget>.generate(4, (i) {
                  if (!_visited.contains(i)) return const SizedBox.shrink();
                  switch (i) {
                    case 0:
                      if (snapshot.hasError && data == null) {
                        return Padding(
                          padding: EdgeInsets.only(top: topPad),
                          child: _errorView(context, snapshot.error!),
                        );
                      }
                      // 首屏走骨架闸门，最快350ms 才切内容，避免骨架闪一下
                      return SkeletonGate(
                        loading: data == null,
                        skeleton: Padding(
                          padding: EdgeInsets.only(top: topPad),
                          child: const HomeSkeleton(),
                        ),
                        child: data == null
                            ? const SizedBox.shrink()
                            : _homeTab(context, data, topPad),
                      );
                    case 1:
                      return _newTab(context, topPad);
                    case 2:
                      return DiscoverView(query: _query, topPad: topPad);
                    default:
                      // 排行榜自己请求 `/api/v3/ranks`，不依赖首屏接口
                      return _RankView(topPad: topPad);
                  }
                }),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: header,
            ),
          ],
        );
      },
    );
  }

  Widget _errorView(BuildContext context, Object error) {
    if (kDebugMode) debugPrint('[home] 首页加载失败: $error');
    return RequestErrorState(error: error, onRetry: _retry);
  }

  Widget _homeTab(BuildContext context, HomeIndex data, [double topPad = 0]) {
    final repo = context.read<Repository>();
    final t = AppLocalizations.of(context);
    final host = repo.imageHost;
    // 过滤服务端的「下载 / 更新」营销轮播（type=3/6），只留能跳详情的条目
    final banners = data.banners
        .where((b) => b.cover.isNotEmpty && b.isContent)
        .take(6)
        .toList();
    final slides = banners.isNotEmpty
        ? banners
            .map((b) => CarouselSlide(
                  title: b.title.isEmpty ? b.subtitle : b.title,
                  subtitle: b.subtitle.isEmpty ? null : b.subtitle,
                  imageUrl: resolveImageUrl(b.cover, host: host),
                  onTap: () => _openBanner(context, b),
                ))
            .toList()
        : data.pool
            .take(5)
            .map((c) => CarouselSlide(
                  title: c.name,
                  subtitle: c.authorLabel,
                  imageUrl: resolveImageUrl(c.cover ?? '', host: host),
                  onTap: () => _openComic(context, c),
                ))
            .toList();

    // 合并推荐 / 热门 / 池子并去重，作为换一批的候选
    final recommendPool = <Comic>[];
    final seen = <String>{};
    for (final comic in [
      ...data.recommend,
      ...data.hot,
      ...data.pool,
    ]) {
      if (comic.pathWord.isEmpty || !seen.add(comic.pathWord)) continue;
      recommendPool.add(comic);
    }

    final topics = _topicOverride ?? data.topics;
    final finish = _finishOverride ?? data.finish;
    final ranks = data.rankWeek.isNotEmpty ? data.rankWeek : data.hot;

    return RefreshIndicator(
      edgeOffset: topPad,
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (topPad > 0) SliverToBoxAdapter(child: SizedBox(height: topPad)),
          if (slides.isNotEmpty)
            // 轮播紧贴顶栏，不再留上边距
            SliverToBoxAdapter(child: CoverCarousel(slides: slides)),
          if (recommendPool.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SectionHeader(title: t.sectionRecommend),
            ),
            SliverToBoxAdapter(
              child: RecommendRow(
                pool: _recommendOverride ?? recommendPool,
                batch: 0,
                host: host,
                onTap: (c) => _openComic(context, c),
              ),
            ),
            SliverToBoxAdapter(
              child: MoreActions(
                moreLabel: t.homeMore,
                onMore: _openRecommendations,
                shuffleLabel: t.homeRefreshBatch,
                onShuffle: _shuffleRecommend,
                shuffling: _shufflingRecommend,
              ),
            ),
          ],
          if (topics.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SectionHeader(title: t.sectionTopics),
            ),
            SliverToBoxAdapter(
              child: TopicStrip(
                slides: topics
                    .map((topic) => TopicSlide(
                          title: topic.period.isEmpty
                              ? topic.title
                              : '${topic.title} · ${topic.period}',
                          imageUrl: resolveImageUrl(topic.cover, host: host),
                        ))
                    .toList(),
                // 每张专题卡都能直接点进该专题的内容列表
                onSlideTap: (i) => CatalogMoreScreen.openTopicContents(
                  context,
                  pathWord: topics[i].pathWord,
                  title: topics[i].title,
                  kind: MediaKind.comic,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: MoreActions(
                moreLabel: t.homeMore,
                onMore: _openTopics,
                shuffleLabel: t.homeRefreshBatch,
                onShuffle: _shuffleTopics,
                shuffling: _shufflingTopics,
              ),
            ),
          ],
          // 热门更新：数据为空时整块（含标题）不渲染
          SliverToBoxAdapter(child: _latestSection(context, host, t)),
          if (finish.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SectionHeader(title: t.sectionFinish),
            ),
            SliverToBoxAdapter(
              child:
                  _sectionGrid(context, finish, host, badge: t.sectionFinish),
            ),
            SliverToBoxAdapter(
              child: MoreActions(
                moreLabel: t.homeMore,
                onMore: _openMoreFinish,
                shuffleLabel: t.homeRefreshBatch,
                onShuffle: _shuffleFinish,
                shuffling: _shufflingFinish,
              ),
            ),
          ],
          if (ranks.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SectionHeader(
                title: t.sectionRank,
                actionLabel: t.homeFullRank,
                onAction: () => _onTabTap(3),
              ),
            ),
            SliverToBoxAdapter(
              child: _HomeRankStrip(
                day: data.rankDay,
                week: ranks,
                month: data.rankMonth,
                host: host,
                onTap: (c) => _openComic(context, c),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// 热门更新：取6 条，更多进入完整列表
  Widget _latestSection(
      BuildContext context, String? host, AppLocalizations t) {
    return FutureBuilder<MediaPage>(
      future: _newest,
      builder: (context, snapshot) {
        final page = snapshot.data;
        final items = page?.items ?? const <Comic>[];
        if (!snapshot.hasError && page != null && items.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title: t.sectionUpdates),
            if (snapshot.hasError)
              _InlineRetry(
                message: describeRequestError(t, snapshot.error!).message,
                onRetry: () => setState(() {
                  _newest =
                      _track(context.read<Repository>().newestComics(offset: 0))
                        ..ignore();
                }),
              )
            else if (page == null)
              // Column 里必须用 RenderBox 版骨架，sliver 版会触发断言白屏
              const MediaGridBoxSkeleton(count: 6)
            else
              _sectionGrid(context, items, host),
            MoreActions(
              moreLabel: t.homeMore,
              onMore: _openMoreUpdates,
            ),
          ],
        );
      },
    );
  }

  Widget _sectionGrid(
    BuildContext context,
    List<Comic> items,
    String? host, {
    int max = 6,
    String? badge,
  }) {
    final list = items.take(max).toList();
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: kTripleGridDelegate,
      itemCount: list.length,
      itemBuilder: (context, i) => MediaEntryCard(
        comic: list[i],
        host: host,
        badge: badge ?? list[i].statusLabel,
        onTap: () => _openComic(context, list[i]),
      ),
    );
  }

  Widget _newTab(BuildContext context, [double topPad = 0]) {
    final repo = context.read<Repository>();
    final t = AppLocalizations.of(context);
    return PagedMediaList(
      load: (offset) => repo.mediaPage(MediaKind.comic, offset: offset),
      resetKey: _refreshTick,
      refreshEdgeOffset: topPad,
      headerSlivers: [
        if (topPad > 0) SliverToBoxAdapter(child: SizedBox(height: topPad)),
        SliverToBoxAdapter(
          child: SectionHeader(
            title: t.newReleases,
            subtitle: t.latestFromComics,
          ),
        ),
      ],
      emptyTitle: t.emptyUpdatesTitle,
      emptyMessage: t.emptyUpdatesMessage,
      itemBuilder: (context, comic) => MediaEntryCard(
        comic: comic,
        host: repo.imageHost,
        badge: comic.statusLabel,
        onTap: () => _openComic(context, comic),
      ),
    );
  }
}

/// _RankView — 排行榜，受众 + 周期两行筛选，上拉分页
class _RankView extends StatefulWidget {
  /// 顶栏高度，筛选区跟着顶栏固定
  final double topPad;

  const _RankView({this.topPad = 0});

  @override
  State<_RankView> createState() => _RankViewState();
}

class _RankViewState extends State<_RankView>
    with AutomaticKeepAliveClientMixin {
  static const List<String> _dateTypes = ['day', 'week', 'month', 'total'];

  /// 受众行对应的 `(type, audience_type)`：漫画榜 type=1，轻小说 type=5
  static const List<({String type, String audience})> _rankTabs = [
    (type: '1', audience: 'male'),
    (type: '1', audience: 'female'),
    (type: '5', audience: 'male'),
  ];

  /// 当前受众与周期，默认男频 · 上升最快
  int _audience = 0;
  int _period = 0;
  final Map<int, List<Comic>> _cache = <int, List<Comic>>{};
  final Map<int, bool> _hasMore = <int, bool>{};
  final Map<int, Object> _errors = <int, Object>{};
  final Map<int, Object> _moreErrors = <int, Object>{};
  final Set<int> _loading = <int>{};
  final Set<int> _loadingMore = <int>{};
  final ScrollController _controller = ScrollController();
  bool _fillScheduled = false;

  /// 榜单筛选区高度，量到后垫给列表首屏
  final GlobalKey _rankHeaderKey = GlobalKey();
  double _rankHeaderHeight = 0;

  int get _key => _audience * _dateTypes.length + _period;

  Future<MediaPage> _fetch(int key, int offset) {
    final repo = context.read<Repository>();
    final tab = _rankTabs[key ~/ _dateTypes.length];
    return repo.rankPage(
      dateType: _dateTypes[key % _dateTypes.length],
      type: tab.type,
      audience: tab.audience,
      limit: 18,
      offset: offset,
    );
  }

  @override
  bool get wantKeepAlive => true;

  void _measureRankHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _rankHeaderKey.currentContext?.size;
      if (size == null) return;
      final box =
          _rankHeaderKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        debugPrint('[rankpanel] top=${box.localToGlobal(Offset.zero).dy} '
            'h=${box.size.height} pad=${widget.topPad}');
      }
      if ((size.height - _rankHeaderHeight).abs() < 0.5) return;
      setState(() => _rankHeaderHeight = size.height);
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _load(_key);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() => _maybeLoadMore(_key);

  /// 接近列表末尾或内容不足一屏时补下一页，可重复调用
  void _maybeLoadMore(int key) {
    if (!mounted) return;
    final list = _cache[key];
    if (list == null) return;
    if (_loading.contains(key) || _loadingMore.contains(key)) return;
    // 上次补页失败后不自动重试，等用户点 footer 的重试按钮
    if (_moreErrors[key] != null) return;
    if (!(_hasMore[key] ?? false)) return;
    if (!_controller.hasClients) {
      // 列表还没挂上滚动位置，下一帧再试
      _scheduleFillCheck(key);
      return;
    }
    if (_controller.position.extentAfter < 480) _loadMore(key);
  }

  /// 每帧后补一次检查，保证内容不足一屏也会续页
  void _scheduleFillCheck(int key) {
    if (_fillScheduled) return;
    _fillScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fillScheduled = false;
      _maybeLoadMore(key);
    });
  }

  Future<void> _load(int key, {bool force = false}) async {
    if (!force && (_cache.containsKey(key) || _loading.contains(key))) return;
    setState(() {
      _loading.add(key);
      _errors.remove(key);
      _moreErrors.remove(key);
    });
    try {
      final page = await _fetch(key, 0);
      if (!mounted) return;
      setState(() {
        _cache[key] = page.items;
        _hasMore[key] = page.hasMore;
        _loading.remove(key);
      });
      _scheduleFillCheck(key);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errors[key] = error;
        _loading.remove(key);
      });
    }
  }

  Future<void> _loadMore(int key) async {
    final list = _cache[key];
    if (list == null ||
        _loading.contains(key) ||
        _loadingMore.contains(key) ||
        !(_hasMore[key] ?? false)) {
      return;
    }
    setState(() {
      _loadingMore.add(key);
      _moreErrors.remove(key);
    });
    try {
      final page = await _fetch(key, list.length);
      if (!mounted) return;
      setState(() {
        final seen = list.map((c) => c.pathWord).toSet();
        var added = 0;
        for (final c in page.items) {
          if (seen.add(c.pathWord)) {
            list.add(c);
            added++;
          }
        }
        // added == 0：服务端忽略 offset 或整页重复，继续翻会死循环
        final reachedEnd = added == 0 || page.items.isEmpty;
        _hasMore[key] = page.hasMore && !reachedEnd;
        _loadingMore.remove(key);
      });
      _scheduleFillCheck(key);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _moreErrors[key] = error;
        _loadingMore.remove(key);
      });
    }
  }

  Future<void> _refresh() async {
    // 下拉刷新：抬高缓存水位线，这次一定走网络
    HttpCache.instance.markAllStale();
    await _load(_key, force: true);
  }

  void _switch({int? audience, int? period}) {
    setState(() {
      _audience = audience ?? _audience;
      _period = period ?? _period;
    });
    // 换榜单回到顶部，避免停在上一榜的末尾
    if (_controller.hasClients) _controller.jumpTo(0);
    _load(_key);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final audienceLabels = [t.rankMale, t.rankFemale, t.navNovel];
    final periodLabels = [t.rankDay, t.rankWeek, t.rankMonth, t.rankTotal];
    final key = _key;
    final list = _cache[key];
    final error = _errors[key];

    // 不足一屏 / 停在末尾时主动补下一页
    if (list != null) _scheduleFillCheck(key);

    _measureRankHeader();
    final topPad = widget.topPad + _rankHeaderHeight;

    final Widget body;
    if (list == null && error == null) {
      body = Padding(
        padding: EdgeInsets.only(top: topPad),
        child: const RankListSkeleton(),
      );
    } else if (error != null) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topPad),
        children: [
          const SizedBox(height: 72),
          RequestErrorState(
            error: error,
            onRetry: () => _load(key, force: true),
          ),
        ],
      );
    } else if (list!.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topPad),
        children: [
          const SizedBox(height: 72),
          EmptyState(
            icon: Icons.leaderboard_outlined,
            title: t.emptyRankTitle,
            message: t.emptyRankMessage,
          ),
        ],
      );
    } else {
      body = ListView.separated(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topPad, bottom: 20),
        itemCount: list.length + 1,
        separatorBuilder: (_, i) => i < list.length - 1
            ? const Divider(height: 1, indent: 16, endIndent: 16)
            : const SizedBox.shrink(),
        itemBuilder: (context, i) {
          if (i == list.length) return _footer(context, key);
          final c = list[i];
          return RankRow(
            rank: i + 1,
            title: c.name,
            author: c.authorLabel,
            popular: c.popularLabel,
            coverUrl: resolveImageUrl(c.cover ?? '', host: repo.imageHost),
            // 轻小说榜（type=5）走小说详情，男频 / 女频仍走漫画详情
            onTap: () => _rankTabs[_audience].type == '5'
                ? openContentDetail(context, MediaKind.novel, c.pathWord)
                : openComicDetail(context, c.pathWord),
          );
        },
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: RefreshIndicator(
            edgeOffset: topPad,
            onRefresh: _refresh,
            child: body,
          ),
        ),
        // 两行榜单页签固定，和上面的顶栏拼成整块毛玻璃
        Positioned(
          top: widget.topPad,
          left: 0,
          right: 0,
          child: BrandGlassPanel(
            child: KeyedSubtree(
              key: _rankHeaderKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DefaultTabController(
                    length: audienceLabels.length,
                    initialIndex: _audience,
                    child: TabBar(
                      onTap: (index) {
                        if (index == _audience) return;
                        _switch(audience: index);
                      },
                      tabs: [for (final l in audienceLabels) Tab(text: l)],
                      dividerHeight: 0,
                    ),
                  ),
                  DefaultTabController(
                    length: periodLabels.length,
                    initialIndex: _period,
                    child: TabBar(
                      onTap: (index) {
                        if (index == _period) return;
                        _switch(period: index);
                      },
                      tabs: [for (final l in periodLabels) Tab(text: l)],
                      dividerHeight: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 列表末尾：加载转圈 / 失败重试 / 到底提示
  Widget _footer(BuildContext context, int key) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget child;
    if (_loadingMore.contains(key)) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_moreErrors[key] != null) {
      child = TextButton.icon(
        onPressed: () => _loadMore(key),
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text(t.loadMoreFailed),
      );
    } else if (!(_hasMore[key] ?? true)) {
      child = Text(
        t.noMore,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.outline),
      );
    } else {
      // 还有下一页但没有请求在飞时，给一个可点的入口
      child = TextButton(
        onPressed: () => _loadMore(key),
        child: Text(t.loadMore),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Center(child: child),
    );
  }
}

/// _HomeRankStrip — 首页排行榜区块，日 / 周 / 月三个 tab
class _HomeRankStrip extends StatefulWidget {
  final List<Comic> day;
  final List<Comic> week;
  final List<Comic> month;
  final String? host;
  final ValueChanged<Comic> onTap;

  const _HomeRankStrip({
    required this.day,
    required this.week,
    required this.month,
    required this.host,
    required this.onTap,
  });

  @override
  State<_HomeRankStrip> createState() => _HomeRankStripState();
}

class _HomeRankStripState extends State<_HomeRankStrip> {
  // 默认停在上升最快（day 榜）
  int _period = 0;

  List<Comic> get _list => switch (_period) {
        0 => widget.day,
        2 => widget.month,
        _ => widget.week,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final labels = [t.rankDay, t.rankWeek, t.rankMonth];
    final list = _list;
    return DefaultTabController(
      length: labels.length,
      initialIndex: _period,
      child: Column(
        children: [
          TabBar(
            onTap: (i) => setState(() => _period = i),
            tabs: [for (final l in labels) Tab(text: l)],
          ),
          for (var i = 0; i < list.length && i < 5; i++)
            RankRow(
              rank: i + 1,
              title: list[i].name,
              author: list[i].authorLabel,
              popular: list[i].popularLabel,
              coverUrl: resolveImageUrl(list[i].cover ?? '', host: widget.host),
              onTap: () => widget.onTap(list[i]),
            ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(t.emptyRankTitle,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// _InlineRetry — 区块内的紧凑错误提示，只让这一块重试
class _InlineRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(t.retry)),
        ],
      ),
    );
  }
}
