import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/chapter.dart';
import '../models/media_page.dart';
import '../services/download_manager.dart';
import '../services/repository.dart';
import '../services/shelf_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../utils/chapter_paging.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/comment_widgets.dart';
import '../widgets/detail_hero.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import '../utils/frame_kick.dart';
import 'catalog_more_screen.dart';
import 'comments_screen.dart';
import 'download_select_screen.dart';
import 'reader_screen.dart';
import '../services/http_cache.dart';

void openComicDetail(BuildContext context, String pathWord) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ComicDetailScreen(pathWord: pathWord)),
  );
}

/// _DetailData — 详情页一次拉取的数据包
class _DetailData {
  final ComicDetailData detail;
  final List<Chapter> chapters;

  /// 已登录时账号收藏里记的上次观看位置；本机记录优先
  final ReadingResume? cloudResume;

  const _DetailData(this.detail, this.chapters, {this.cloudResume});
}

/// ComicDetailScreen — 漫画详情页，封面、简介、目录与收藏
class ComicDetailScreen extends StatefulWidget {
  final String pathWord;
  const ComicDetailScreen({super.key, required this.pathWord});

  @override
  State<ComicDetailScreen> createState() => _ComicDetailScreenState();
}

class _ComicDetailScreenState extends State<ComicDetailScreen> {
  late Future<_DetailData> _future;
  bool _ascending = true;

  /// 章节目录当前页，每页 [kChapterPageSize] 话
  int _page = 0;

  /// 头图折叠进度，由 [DetailHeroBar.collapseOf] 换算成0→1
  final ValueNotifier<double> _heroOffset = ValueNotifier<double>(0);

  bool _trackHero(ScrollNotification notification) {
    if (notification.depth == 0) {
      _heroOffset.value = notification.metrics.pixels;
    }
    return false;
  }

  @override
  void dispose() {
    _heroOffset.dispose();
    super.dispose();
  }

  /// 目录区锚点，翻页后把视图带回章节目录
  final GlobalKey _chapterAnchorKey = GlobalKey();

  void _goPage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    final anchor = _chapterAnchorKey.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  /// 当前章节栏目，即官方 `results.groups` 的 path_word
  String _selectedGroup = 'default';

  /// 每个栏目拉过的章节表
  final Map<String, List<Chapter>> _chapterCache = {};
  bool _groupLoading = false;
  Object? _groupError;

  /// 防竞态：只有最后一次栏目请求能写回状态
  int _groupSeq = 0;

  /// 首次进入按阅读记录恢复栏目，之后的刷新 / 重试不动用户选择
  bool _groupRestored = false;

  /// 评论总数，只用于导航栏评论入口的角标
  int _commentTotal = 0;

  @override
  void initState() {
    super.initState();
    _future = _runLoad();
  }

  Future<_DetailData> _load() async {
    final repo = context.read<Repository>();
    final detail = await repo.detail(widget.pathWord);
    // 已登录时收藏里带上次看到哪一话，和章节表并行拉；本机有进度就不再请求
    final localProgress = context
        .read<AppState>()
        .lastReadOf(widget.pathWord, kind: MediaKind.comic)
        ?.chapterUuid;
    final hasLocalProgress = (localProgress ?? '').trim().isNotEmpty;
    final cloudResumeFuture = hasLocalProgress
        ? Future<ReadingResume?>.value(null)
        : () async {
            try {
              return await repo.collectResume(
                MediaKind.comic,
                uuid: detail.comic.uuid,
                pathWord: widget.pathWord,
              );
            } catch (_) {
              return null;
            }
          }();
    if (mounted) {
      // 旧版本地收藏只存了 path_word，顺手补上名称 / 封面 / 最新章节
      unawaited(context.read<AppState>().mergeFavorite(detail.comic));
      // 打开详情页就算看过，浏览记录按作品记一条
      unawaited(context.read<AppState>().markSeen(
            kind: MediaKind.comic,
            pathWord: widget.pathWord,
            name: detail.comic.name,
            cover: detail.comic.cover,
            // 顺手记下热度，浏览记录卡片要用
            popular: detail.comic.popular,
          ));
    }
    // 首次进入恢复上次阅读的栏目，刷新 / 重试不动用户选择
    if (!_groupRestored) {
      _groupRestored = true;
      final remembered = context
          .read<AppState>()
          .lastReadOf(widget.pathWord, kind: MediaKind.comic)
          ?.groupPathWord;
      if (remembered != null && remembered.isNotEmpty) {
        _selectedGroup = remembered;
      }
    }
    final groups = detail.groups;
    final valid = groups.any((g) => g.pathWord == _selectedGroup);
    final group = valid
        ? _selectedGroup
        : (groups.isEmpty ? 'default' : groups.first.pathWord);
    _selectedGroup = group;
    // 章节是附加信息，失败不该把整页打成加载失败
    List<Chapter> chapters;
    try {
      chapters = await repo.chapters(widget.pathWord, group: group);
      _chapterCache[group] = chapters;
    } catch (error) {
      debugPrint('[detail] 章节加载失败: $error');
      chapters = _chapterCache[group] ?? const [];
    }
    final cloudResume = await cloudResumeFuture;
    return _DetailData(detail, chapters, cloudResume: cloudResume);
  }

  /// 包装 [_load]：详情到达后再拉评论总数
  Future<_DetailData> _runLoad() => kickOnDone(_load()).then((data) {
        final id = data.detail.comic.uuid;
        if (id.isNotEmpty) unawaited(_loadCommentCount(id));
        return data;
      });

  /// 拉评论总数给角标用，只取1 条拿 total，失败重试一次
  Future<void> _loadCommentCount(String comicId) async {
    final repo = context.read<Repository>();
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final page = await repo.commentsPage(comicId, limit: 1);
        if (!mounted) return;
        debugPrint('[detail] 评论数 attempt=$attempt total=${page.total}');
        setState(() => _commentTotal = page.total);
        return;
      } catch (error) {
        debugPrint('[detail] 评论数加载失败 attempt=$attempt: $error');
        if (attempt == 2 || !mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
      }
    }
  }

  /// 切栏目：命中缓存直接换数据，否则只重绘目录区
  Future<void> _selectGroup(String group) async {
    if (group == _selectedGroup && _chapterCache.containsKey(group)) return;
    final repo = context.read<Repository>();
    final seq = ++_groupSeq;
    final cached = _chapterCache[group];
    setState(() {
      _selectedGroup = group;
      _page = 0;
      _groupError = null;
      _groupLoading = cached == null;
    });
    if (cached != null) return;
    try {
      final chapters = await repo.chapters(widget.pathWord, group: group);
      if (!mounted || seq != _groupSeq) return;
      setState(() {
        _chapterCache[group] = chapters;
        _groupLoading = false;
      });
      kickFrame();
    } catch (error) {
      if (!mounted || seq != _groupSeq) return;
      setState(() {
        _groupLoading = false;
        _groupError = error;
      });
      kickFrame();
    }
  }

  /// 顶栏「下载」：进章节多选页，带当前栏目的完整章节表
  void _openDownloadSelect(_DetailData data) {
    final comic = data.detail.comic;
    openDownloadSelect(
      context,
      comicId: comic.uuid,
      comicPathWord: widget.pathWord,
      comicName: comic.name,
      chapters: _chapterCache[_selectedGroup] ?? data.chapters,
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 收藏状态的本页覆盖值，失败回滚成 null 退回服务端值
  bool? _favOverride;
  bool _favBusy = false;

  Future<void> _toggleFavorite(_DetailData data) async {
    if (_favBusy) return;
    final app = context.read<AppState>();
    final shelf = context.read<ShelfService>();
    final t = AppLocalizations.of(context);
    final before = _favOverride ??
        (app.isLoggedIn
            ? data.detail.isCollect
            : app.isFavorite(widget.pathWord));
    setState(() {
      _favBusy = true;
      _favOverride = !before;
    });
    try {
      await shelf.toggle(data.detail.comic, currentIsFavorite: before);
      if (!mounted) return;
      setState(() => _favBusy = false);
      _toast(!before
          ? (app.isLoggedIn ? t.favoriteAddedCloud : t.favoriteAddedLocal)
          : t.favoriteRemoved);
    } on NotSignedInException {
      if (!mounted) return;
      setState(() {
        _favBusy = false;
        _favOverride = before;
      });
      _toast(t.commentSignInFirst);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _favBusy = false;
        _favOverride = before;
      });
      _toast(t.favoriteFailed);
    }
  }

  /// 打开独立评论页，带上已拿到的 comic uuid
  void _openComments(String comicUuid) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComicCommentsScreen(
          pathWord: widget.pathWord,
          comicId: comicUuid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 章节角标要跟下载队列实时变，watch 放在整页
    final downloads = context.watch<DownloadManager>();
    return FutureBuilder<_DetailData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: RequestErrorState(
              error: snapshot.error!,
              onRetry: () => setState(() => _future = _runLoad()),
            ),
          );
        }
        if (!snapshot.hasData) {
          // 骨架按真实详情页逐块复刻
          return const Scaffold(body: ComicDetailSkeleton());
        }
        final data = snapshot.data!;
        final comic = data.detail.comic;
        final groups = data.detail.groups;
        // 目录永远展示当前栏目的章节表
        final groupChapters = _chapterCache[_selectedGroup] ?? data.chapters;
        final chapters =
            _ascending ? groupChapters : groupChapters.reversed.toList();
        // 数据刷新后章节数可能变少，页码越界时夹回
        final pageRange = chapterPageRange(chapters.length, _page);
        _page =
            pageRange.pages == 0 ? 0 : (pageRange.start ~/ kChapterPageSize);
        final lastRead = context.select<AppState, HistoryEntry?>(
            (app) => app.lastReadOf(widget.pathWord, kind: MediaKind.comic));
        // 续读目标：先认本机记录，再认账号收藏；作品级记录（chapterUuid 为空）不算进度
        final localUuid = (lastRead?.chapterUuid ?? '').trim();
        final localGroup = lastRead?.groupPathWord;
        final localName = (lastRead?.chapterName ?? '').trim();
        String? resumeUuid;
        String resumeName = '';
        String? resumeGroup;
        if (localUuid.isNotEmpty) {
          final hit = groupChapters.indexWhere((c) => c.uuid == localUuid);
          if (hit >= 0) {
            resumeUuid = localUuid;
            resumeName = groupChapters[hit].name;
            resumeGroup = _selectedGroup;
          } else if (localName.isNotEmpty &&
              (groupChapters.isEmpty ||
                  localGroup == null ||
                  localGroup != _selectedGroup)) {
            // 当前栏目里没这一话，但章节表未拉到 / 记录不带栏目 / 记录属别的栏目时仍可信
            resumeUuid = localUuid;
            resumeName = localName;
            // 记录本来没有栏目时保持 null，阅读器会用第一个栏目拉目录
            resumeGroup = localGroup;
          }
        }
        final cloudResume = data.cloudResume;
        if (resumeUuid == null && cloudResume != null && cloudResume.isUsable) {
          final hit = groupChapters
              .indexWhere((c) => c.uuid == cloudResume.chapterUuid);
          resumeUuid = cloudResume.chapterUuid;
          resumeName =
              hit >= 0 ? groupChapters[hit].name : cloudResume.chapterName;
          // 收藏接口只记哪一话、不带栏目，找不到就交给阅读器回退到第一个栏目
          resumeGroup = hit >= 0 ? _selectedGroup : null;
        }
        final resumeLabel = resumeName.trim();
        final hasResume = resumeUuid != null;
        // 没有进度时退回第一话，目录未拉到时按钮禁用
        final canOpenReader = hasResume || groupChapters.isNotEmpty;
        // 收藏状态：已登录以服务端 is_collect 为准，未登录看本地
        final loggedIn =
            context.select<AppState, bool>((app) => app.isLoggedIn);
        final localFav = context
            .select<AppState, bool>((app) => app.isFavorite(widget.pathWord));
        final isFav =
            _favOverride ?? (loggedIn ? data.detail.isCollect : localFav);

        return Scaffold(
          body: NotificationListener<ScrollNotification>(
            onNotification: _trackHero,
            child: RefreshIndicator(
              onRefresh: () async {
                HttpCache.instance.markAllStale();
                final next = _runLoad();
                setState(() => _future = next);
                await next;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  ValueListenableBuilder<double>(
                    valueListenable: _heroOffset,
                    builder: (context, offset, _) => DetailHeroBar(
                      comic: comic,
                      title: comic.name,
                      collapse: DetailHeroBar.collapseOf(offset,
                          kDetailHeroHeight, MediaQuery.paddingOf(context).top),
                      actions: [
                        // 评论入口：图标右上角挂总数角标
                        CommentCountButton(
                          count: _commentTotal,
                          tooltip: AppLocalizations.of(context).commentsTitle,
                          onPressed: () => _openComments(comic.uuid),
                        ),
                        IconButton(
                          tooltip: AppLocalizations.of(context).download,
                          icon: const Icon(Icons.download_outlined),
                          onPressed: () => _openDownloadSelect(data),
                        ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 书名已压在头图上，这里从作者开始；作者可能很长，用 Wrap 防溢出
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _MetaPill(
                                  icon: Icons.person_outline_rounded,
                                  text: comic.authorLabel),
                              _MetaPill(
                                  icon: Icons.public_rounded,
                                  text: comic.regionLabel),
                              _MetaPill(
                                  icon: Icons.local_fire_department_outlined,
                                  text: '${comic.popularLabel} 人气'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              // 题材 / 作者 chip 落到筛选页，参数必须是 path_word
                              ...comic.themes.asMap().entries.map((e) {
                                final word = e.key < comic.themeWords.length
                                    ? comic.themeWords[e.key]
                                    : '';
                                return ActionChip(
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  label: Text(e.value),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: word.isEmpty
                                      ? null
                                      : () => CatalogMoreScreen.openFilter(
                                            context,
                                            kind: MediaKind.comic,
                                            title: '漫画 · ${e.value}',
                                            theme: word,
                                          ),
                                );
                              }),
                              ...comic.authors.asMap().entries.map((e) {
                                final word = e.key < comic.authorWords.length
                                    ? comic.authorWords[e.key]
                                    : '';
                                return ActionChip(
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  label: Text(e.value),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: word.isEmpty
                                      ? null
                                      : () => CatalogMoreScreen.openFilter(
                                            context,
                                            kind: MediaKind.comic,
                                            title: '漫画 · ${e.value}',
                                            author: word,
                                          ),
                                );
                              }),
                              Chip(
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                label: Text(comic.statusLabel),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          ExpandableText(
                            text: comic.brief,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant, height: 1.5),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: !canOpenReader
                                      ? null
                                      : () => openReader(
                                            context,
                                            pathWord: widget.pathWord,
                                            chapterUuid: resumeUuid ??
                                                groupChapters.first.uuid,
                                            groupPathWord: hasResume
                                                ? resumeGroup
                                                : _selectedGroup,
                                          ),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: Text(!hasResume
                                      ? '开始阅读'
                                      : (resumeLabel.isEmpty
                                          ? '续读'
                                          : '续读 $resumeLabel')),
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.tonalIcon(
                                onPressed: _favBusy
                                    ? null
                                    : () => _toggleFavorite(data),
                                icon: Icon(isFav
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded),
                                label: Text(isFav ? '已收藏' : '收藏'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SectionHeader(
                      key: _chapterAnchorKey,
                      title: '章节目录',
                      subtitle:
                          '${groupChapters.length} 话 · ${comic.lastChapter}',
                      actionLabel: _ascending ? '倒序' : '正序',
                      onAction: () => setState(() {
                        _ascending = !_ascending;
                        // 换序后回到第一页
                        _page = 0;
                      }),
                    ),
                  ),
                  // 只有1 个分组时不显示栏目行
                  if (groups.length > 1)
                    SliverToBoxAdapter(
                      child: _ChapterGroupTabs(
                        groups: groups,
                        selected: _selectedGroup,
                        onSelected: _selectGroup,
                      ),
                    ),
                  if (_groupLoading)
                    const SliverToBoxAdapter(
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_groupError != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('该栏目章节加载失败',
                                  style: TextStyle(color: scheme.error)),
                            ),
                            TextButton(
                              onPressed: () =>
                                  unawaited(_selectGroup(_selectedGroup)),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  SliverPadding(
                    // 有栏目 tab 时网格与 tab 下划线留12，否则只留4
                    padding: EdgeInsets.fromLTRB(
                      16,
                      groups.length > 1 ? 12 : 4,
                      16,
                      // 没有分页条时别贴着屏幕底边
                      pageRange.showPager ? 8 : AppSpacing.base,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: kChapterGridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          // 尚未缓存的栏目用同尺寸格子骨架占住网格
                          if (_groupLoading && groupChapters.isEmpty) {
                            return const SkeletonBox(
                              width: double.infinity,
                              height: double.infinity,
                              radius: 12,
                            );
                          }
                          final index = pageRange.start + i;
                          final c = chapters[index];
                          return _ChapterCell(
                            label: c.name,
                            current: resumeUuid == c.uuid,
                            downloaded: downloads.isDownloaded(c.uuid),
                            downloading:
                                downloads.taskOf(c.uuid)?.isActive ?? false,
                            onTap: () => openReader(
                              context,
                              pathWord: widget.pathWord,
                              chapterUuid: c.uuid,
                              groupPathWord: _selectedGroup,
                            ),
                          );
                        },
                        childCount: _groupLoading && groupChapters.isEmpty
                            ? 24
                            : pageRange.count,
                      ),
                    ),
                  ),
                  if (pageRange.showPager)
                    SliverToBoxAdapter(
                      child: _ChapterPager(
                        page: _page,
                        pageCount: pageRange.pages,
                        total: chapters.length,
                        onPage: _goPage,
                      ),
                    ),
                  // 分页条是页面最后一块，底部只让出系统手势条的安全区
                  SliverToBoxAdapter(
                    child:
                        SizedBox(height: MediaQuery.paddingOf(context).bottom),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// _ChapterCell — 章节格子，右上角角标表示下载中 / 已下载
class _ChapterCell extends StatelessWidget {
  final String label;
  final bool current;
  final bool downloaded;
  final bool downloading;
  final VoidCallback onTap;

  const _ChapterCell({
    required this.label,
    required this.current,
    required this.onTap,
    this.downloaded = false,
    this.downloading = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color:
          current ? scheme.secondaryContainer : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: current ? scheme.primary : scheme.outlineVariant,
          width: current ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: current ? FontWeight.w500 : FontWeight.w500,
                    color: current
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                  ),
                ),
              ),
            ),
            if (downloading)
              Positioned(
                top: 3,
                right: 3,
                child: SizedBox(
                  width: 9,
                  height: 9,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: scheme.primary,
                  ),
                ),
              )
            else if (downloaded)
              Positioned(
                top: 2,
                right: 2,
                child: Icon(Icons.download_done_rounded,
                    size: 11, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}

/// _ChapterGroupTabs — 章节栏目切换，选中项底部2.5dp 主色下划线
class _ChapterGroupTabs extends StatelessWidget {
  final List<ChapterGroup> groups;
  final String selected;
  final ValueChanged<String> onSelected;

  const _ChapterGroupTabs({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 不留外层 padding，每个 tab 自带18 水平内边距，相邻 tab 补6 间距
        child: Row(
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              InkWell(
                onTap: () => onSelected(groups[i].pathWord),
                child: _GroupTab(
                  label: groups[i].name,
                  active: groups[i].pathWord == selected,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// _GroupTab — 详情页顶部的章节分组标签
class _GroupTab extends StatelessWidget {
  final String label;
  final bool active;

  const _GroupTab({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? scheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontWeight: active ? FontWeight.w500 : FontWeight.w500,
          color: active ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// _ChapterPager — 章节分页条，上一页 / 下一页
class _ChapterPager extends StatelessWidget {
  final int page;
  final int pageCount;
  final int total;
  final ValueChanged<int> onPage;

  const _ChapterPager({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.onPage,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final start = page * kChapterPageSize + 1;
    final end = ((page + 1) * kChapterPageSize).clamp(0, total);
    final hasPrev = page > 0;
    final hasNext = page < pageCount - 1;
    return Padding(
      // 下内边距6，让分页条贴着屏幕底边
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          _PagerButton(
            icon: Icons.chevron_left_rounded,
            label: t.prevPage,
            onPressed: hasPrev ? () => onPage(page - 1) : null,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.chapterPageRange(start, end, total),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.chapterPageOf(page + 1, pageCount),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _PagerButton(
            icon: Icons.chevron_right_rounded,
            label: t.nextPage,
            iconAfter: true,
            onPressed: hasNext ? () => onPage(page + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// _PagerButton — 分页按钮，不可点时置灰，左右等宽
class _PagerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool iconAfter;
  final VoidCallback? onPressed;

  const _PagerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconAfter = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = enabled ? scheme.primary : scheme.outline;
    final parts = <Widget>[
      Icon(icon, size: 20, color: fg),
      const SizedBox(width: 2),
      Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    ];
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: iconAfter ? parts.reversed.toList() : parts,
      ),
    );
  }
}

/// _MetaPill — 图标 + 一行文字的元信息标签
class _MetaPill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
