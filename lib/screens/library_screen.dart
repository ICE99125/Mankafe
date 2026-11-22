import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/favorite_entry.dart';
import '../models/media_page.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../services/shelf_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_header.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/net_image.dart';
import '../widgets/paged_media.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';
import 'login_screen.dart';

/// LibraryScreen — 书架
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _filter = 0;

  /// 内容区当前页
  int _tabIndex = 0;

  final Set<int> _visited = {0};

  /// 书架顶部的筛选 chips / 分段 tab / 续读条：固定在顶栏下面不随列表滚动
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 0;

  static const List<MediaKind> _kinds = [
    MediaKind.comic,
    MediaKind.novel,
    MediaKind.photo,
    MediaKind.animation,
  ];

  @override
  bool get wantKeepAlive => true;

  /// 顶部固定区高度一变（例如续读条出现 / 消失）就重新垫列表首屏
  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _headerKey.currentContext?.size;
      if (size == null) return;
      if ((size.height - _headerHeight).abs() < 0.5) return;
      setState(() => _headerHeight = size.height);
    });
  }

  /// 本机收藏 → 云端只补一次（失败也置位，等下次进书架再试，避免死循环）
  bool _syncStarted = false;

  /// 旧版本地收藏只存了 path_word，书架会显示成一串拼音
  bool _metaFillStarted = false;

  /// 未登录书架首次打开时自动落到有收藏的那一类页签（只跑一次）
  bool _autoTabDone = false;

  /// 只收藏了一本轻小说时，默认停在漫画页签会看到这里还没有收藏，像是收藏丢了
  void _autoSelectLocalTab(AppState app) {
    if (_autoTabDone || app.isLoggedIn) return;
    if (app.localFavorites.isEmpty) return;
    _autoTabDone = true;
    if (app.localFavoritesOf(MediaKind.comic).isNotEmpty) return;
    final index = _kinds.indexWhere((k) => app.localFavoritesOf(k).isNotEmpty);
    if (index <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onTabTap(index);
    });
  }

  void _scheduleMetaFill(AppState app) {
    if (_metaFillStarted || app.isLoggedIn) return;
    final missing = app.localFavorites
        .where((e) => e.name.isEmpty || e.name == e.pathWord)
        .take(5)
        .toList();
    if (missing.isEmpty) return;
    _metaFillStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repo = context.read<Repository>();
      for (final entry in missing) {
        if (!mounted) return;
        try {
          if (entry.kind == MediaKind.comic) {
            final detail = await repo.detail(entry.pathWord);
            await app.mergeFavorite(detail.comic);
          } else {
            final detail = await repo.contentDetail(
              entry.kind,
              entry.pathWord,
              withChapters: false,
            );
            await app.mergeFavorite(detail.item, kind: entry.kind);
          }
        } catch (_) {
          // 补全失败不影响书架展示，下次进页面再试
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 4,
      vsync: this,
      animationDuration: Duration.zero,
    );
  }

  /// 登录后把本机收藏补到云端
  void _scheduleSyncIfNeeded(AppState app) {
    if (_syncStarted) return;
    if (!app.isLoggedIn || app.localFavorites.isEmpty) return;
    _syncStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final moved = await context.read<ShelfService>().syncLocalToCloud();
      if (!mounted || moved == 0) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.shelfSynced(moved))));
    });
  }

  /// 与首页一致：TabBar 只画指示器，内容用 IndexedStack 切
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Consumer<AppState>(
      builder: (context, app, _) {
        _scheduleSyncIfNeeded(app);
        _scheduleMetaFill(app);
        if (!app.isLoggedIn) _autoSelectLocalTab(app);
        if (!app.isLoggedIn) {
          return Column(
            children: [
              const BrandBar(title: BrandTitle(name: '书架')),
              Expanded(child: _localShelf(context, app)),
            ],
          );
        }

        _measureHeader();
        final barH = MediaQuery.paddingOf(context).top + 64;
        final topPad = barH + _headerHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _tabIndex,
                sizing: StackFit.expand,
                children: List<Widget>.generate(_kinds.length, (i) {
                  if (!_visited.contains(i)) return const SizedBox.shrink();
                  return _collectTab(context, _kinds[i], topPad);
                }),
              ),
            ),
            // 顶部整块固定毛玻璃，模糊与底部发丝线由 BrandGlassPanel 负责
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: BrandGlassPanel(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const BrandBar(
                      title: BrandTitle(name: '书架'),
                      glassBorder: false,
                      glass: false,
                    ),
                    KeyedSubtree(
                      key: _headerKey,
                      child: _libraryHeader(context, app, t, scheme),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 当前页签对应的上次停驻：历史按时间倒序，取该类型的第一条
  HistoryEntry? _latestHistory(AppState app, MediaKind kind) {
    for (final entry in app.history) {
      if (entry.kind == kind) return entry;
    }
    return null;
  }

  Widget _libraryHeader(
    BuildContext context,
    AppState app,
    AppLocalizations t,
    ColorScheme scheme,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Center(
                  child: ChoiceChip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text('${t.shelfAll} (${app.favoriteCount})'),
                    selected: _filter == 0,
                    onSelected: (_) => setState(() => _filter = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Center(
                  child: ChoiceChip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(t.shelfUpdates),
                    selected: _filter == 1,
                    onSelected: (_) => setState(() => _filter = 1),
                  ),
                ),
              ],
            ),
          ),
        ),
        SurfaceTabBar(
          controller: _tabs,
          labels: [
            t.shelfTabComic,
            t.shelfTabNovel,
            t.shelfTabPhoto,
            t.shelfTabAnimation,
          ],
          onTap: _onTabTap,
        ),
        if (_latestHistory(app, _kinds[_tabIndex]) case final entry?)
          _ContinueReading(
            entry: entry,
            host: context.read<Repository>().imageHost,
            onTap: () => _openItem(entry.kind, entry.pathWord),
          ),
      ],
    );
  }

  /// 未登录时的书架：本机收藏同样按四个页签分流
  Widget _localShelf(BuildContext context, AppState app) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final items = app.localFavorites;

    void goLogin() => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );

    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.favorite_border_rounded,
        title: t.emptyShelfTitle,
        message: t.shelfLocalEmptyHint,
        action: FilledButton.tonalIcon(
          onPressed: goLogin,
          icon: const Icon(Icons.login_rounded, size: 18),
          label: Text(t.goLogin),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.shelfLocalBanner(items.length),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              TextButton(onPressed: goLogin, child: Text(t.goLogin)),
            ],
          ),
        ),
        Material(
          color: scheme.surface,
          child: SurfaceTabBar(
            controller: _tabs,
            labels: [
              t.shelfTabComic,
              t.shelfTabNovel,
              t.shelfTabPhoto,
              t.shelfTabAnimation,
            ],
            onTap: _onTabTap,
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tabIndex,
            sizing: StackFit.expand,
            children: List<Widget>.generate(_kinds.length, (i) {
              if (!_visited.contains(i)) return const SizedBox.shrink();
              return _localKindTab(
                context,
                _kinds[i],
                app.localFavoritesOf(_kinds[i]),
              );
            }),
          ),
        ),
      ],
    );
  }

  /// 本机收藏的单个页签：直接渲染条目，不需要分页
  Widget _localKindTab(
    BuildContext context,
    MediaKind kind,
    List<FavoriteEntry> items,
  ) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.favorite_border_rounded,
        title: t.emptyShelfTitle,
        message: '${kind.label} · ${t.emptyShelfMessage}',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      gridDelegate: kTripleGridDelegate,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        return MediaEntryCard(
          comic: entry.toComic(),
          host: repo.imageHost,
          onTap: () => _openItem(kind, entry.pathWord),
        );
      },
    );
  }

  Widget _collectTab(BuildContext context, MediaKind kind, double topPad) {
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final shelf = context.read<ShelfService>();
    final updatesOnly = _filter == 1;
    return PagedMediaList(
      resetKey: kind,
      refreshEdgeOffset: topPad,
      skeleton: const MediaGridSkeleton(shelfStyle: true),
      filter: updatesOnly ? (comic) => comic.hasUpdate : null,
      headerSlivers: [
        if (topPad > 0) SliverToBoxAdapter(child: SizedBox(height: topPad)),
      ],
      load: (offset) async {
        final page = await repo.collectPage(kind, offset: offset);
        // 个人页的收藏统计在已登录时以云端总数为准
        if (offset == 0 && kind == MediaKind.comic) {
          shelf.reportCloudCount(page.total);
        }
        return page;
      },
      emptyTitle: updatesOnly ? t.emptyShelfUpdatesTitle : t.emptyShelfTitle,
      emptyMessage:
          updatesOnly ? t.emptyShelfUpdatesMessage : t.emptyShelfMessage,
      filteredEmptyTitle: t.emptyShelfUpdatesTitle,
      filteredEmptyMessage: t.emptyShelfUpdatesMessage,
      itemBuilder: (context, comic) => MediaEntryCard(
        comic: comic,
        host: repo.imageHost,
        badge: comic.hasUpdate ? t.shelfUpdateBadge : null,
        onTap: () => _openItem(kind, comic.pathWord),
      ),
    );
  }

  /// 按类型落到真实详情页：漫画用 `/comic2/{path_word}`
  void _openItem(MediaKind kind, String pathWord) {
    if (kind == MediaKind.comic) {
      openComicDetail(context, pathWord);
    } else {
      openContentDetail(context, kind, pathWord);
    }
  }
}

/// _ContinueReading — 书架顶部上次停驻续读条：封面 + 作品名 + 已读章节 + 继续按钮
class _ContinueReading extends StatelessWidget {
  final HistoryEntry entry;
  final String? host;
  final VoidCallback onTap;

  const _ContinueReading({
    required this.entry,
    required this.host,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final name = entry.name.isEmpty ? entry.pathWord : entry.name;
    final url = resolveImageUrl(entry.cover ?? '', host: host);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        color: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppShape.lg)),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 64,
                    child: url == null || url.isEmpty
                        ? ColoredBox(color: scheme.surfaceContainerHighest)
                        : NetImage(
                            url: url,
                            width: 48,
                            height: 64,
                            errorBuilder: (_) => ColoredBox(
                                color: scheme.surfaceContainerHighest),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.shelfLastRead,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.shelfReadTo(entry.chapterName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: onTap,
                  child: Text(t.shelfContinue),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
