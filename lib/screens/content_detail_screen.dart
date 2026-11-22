import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content.dart';
import '../models/media_page.dart';
import '../l10n/app_localizations.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../services/shelf_service.dart';
import '../state/app_state.dart';
import '../widgets/detail_hero.dart';
import '../widgets/comment_widgets.dart';
import '../widgets/net_image.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'animation_play_screen.dart';
import 'catalog_more_screen.dart';
import 'comments_screen.dart';
import 'content_reader_screen.dart';
import '../services/http_cache.dart';
import '../utils/app_route.dart';
import '../utils/frame_kick.dart';

/// 打开轻小说 / 动画 / 写真详情页
void openContentDetail(BuildContext context, MediaKind kind, String pathWord) {
  Navigator.of(context).push(NoTransitionPageRoute<void>(
    builder: (_) => ContentDetailScreen(kind: kind, pathWord: pathWord),
  ));
}

/// ContentDetailScreen — 轻小说 / 动画 / 写真集共用详情页，按类型取目录与续读位置
class ContentDetailScreen extends StatefulWidget {
  final MediaKind kind;
  final String pathWord;

  const ContentDetailScreen({
    super.key,
    required this.kind,
    required this.pathWord,
  });

  @override
  State<ContentDetailScreen> createState() => _ContentDetailScreenState();
}

class _ContentDetailScreenState extends State<ContentDetailScreen> {
  late Future<ContentDetail> _future;

  /// 轻小说评论总数：与漫画详情页同一个做法，导航栏放一个带角标的评论图标
  int _commentTotal = 0;

  /// 头图折叠进度（0 = 展开）：滚动时只重建头部 sliver
  final ValueNotifier<double> _heroOffset = ValueNotifier<double>(0);

  bool _trackHero(ScrollNotification notification) {
    if (notification.depth == 0) {
      _heroOffset.value = notification.metrics.pixels;
    }
    return false;
  }

  /// 收藏状态的本页覆盖值
  bool? _favOverride;
  bool _favBusy = false;

  Future<void> _toggleFavorite(ContentDetail data) async {
    if (_favBusy) return;
    final app = context.read<AppState>();
    final shelf = context.read<ShelfService>();
    final t = AppLocalizations.of(context);
    final before = _favOverride ?? data.isCollect;
    setState(() {
      _favBusy = true;
      _favOverride = !before;
    });
    try {
      await shelf.toggle(data.item,
          kind: widget.kind, currentIsFavorite: before);
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

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _heroOffset.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _future = kickOnDone(_load());
  }

  Future<ContentDetail> _load() async {
    final repo = context.read<Repository>();
    final app = context.read<AppState>();
    final data = await repo.contentDetail(widget.kind, widget.pathWord);
    // 打开详情页即算看过：轻小说 / 写真集 / 动画同样进浏览记录，按作品记一条
    unawaited(app.markSeen(
      kind: widget.kind,
      pathWord: widget.pathWord,
      name: data.item.name,
      cover: data.item.cover,
      popular: data.item.popular,
    ));
    // 轻小说也有整本评论：评论数是附加信息，独立请求、不阻塞详情主体，失败只是顶栏不挂角标
    if (widget.kind == MediaKind.novel && data.item.uuid.isNotEmpty) {
      unawaited(_loadCommentCount(data.item.uuid));
    }
    return data;
  }

  /// 拉轻小说评论总数，给导航栏评论图标的角标用
  Future<void> _loadCommentCount(String bookId) async {
    final repo = context.read<Repository>();
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final page = await repo.bookCommentsPage(bookId, limit: 1);
        if (!mounted) return;
        debugPrint('[content] 轻小说评论数 attempt=$attempt total=${page.total}');
        setState(() => _commentTotal = page.total);
        return;
      } catch (error) {
        debugPrint('[content] 轻小说评论数加载失败 attempt=$attempt: $error');
        if (attempt == 2 || !mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
      }
    }
  }

  /// 打开轻小说评论页：详情页已经拿到书 uuid，直接带过去省一次详情请求
  void _openComments(String bookId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicCommentsScreen(
          pathWord: widget.pathWord,
          bookId: bookId,
        ),
      ),
    );
  }

  void _retry() => setState(() {
        _future = kickOnDone(_load());
      });

  void _openChapter(
    ContentChapter chapter,
    int index,
    List<ContentChapter> all, {
    String name = '',
    String? cover,
  }) {
    if (widget.kind == MediaKind.animation) {
      // 播放页会真的请求 /cartoon/{p}/chapter/{uuid}?line=
      openAnimationPlay(
        context,
        pathWord: widget.pathWord,
        chapterUuid: chapter.id,
        chapterName: chapter.name,
        initialLines: chapter.lines,
        name: name,
        cover: cover,
      );
      return;
    }
    openContentReader(
      context,
      kind: widget.kind,
      pathWord: widget.pathWord,
      chapters: all,
      index: index,
      name: name,
      cover: cover,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ContentDetail>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.kind.label)),
            body: RequestErrorState(error: snapshot.error!, onRetry: _retry),
          );
        }
        if (!snapshot.hasData) {
          // 小说进入页= 轻小说 / 动画 / 写真共用的内容详情页
          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
            body: ContentDetailSkeleton(
              hasChapterCover: widget.kind != MediaKind.novel,
            ),
          );
        }
        // 拿到数据后与漫画详情页同构：头图就是 SliverAppBar 的背景大图
        return Scaffold(body: _body(context, snapshot.data!));
      },
    );
  }

  /// 头图与书名之间的元信息行：与漫画详情页的 pill 位置一致
  Widget _meta(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, ContentDetail data) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    final chapters = data.chapters;
    final loggedIn = context.select<AppState, bool>((app) => app.isLoggedIn);
    final isFav = _favOverride ?? data.isCollect;
    final label = widget.kind == MediaKind.novel
        ? '卷'
        : widget.kind == MediaKind.animation
            ? '集'
            : '章节';

    // 续读/续看：与漫画详情页同一条思路，从浏览记录里取这一部读到哪，但这里必须按类型取
    final lastRead = context.select<AppState, HistoryEntry?>(
        (app) => app.lastReadOf(widget.pathWord, kind: widget.kind));
    final resumeIndex = lastRead == null
        ? -1
        : chapters.indexWhere((c) => c.id == lastRead.chapterUuid);
    // 目录一次只拉100 条：历史里的那一卷/集不在这一页里就无法定位，这时从第一卷开始
    final resumed = resumeIndex >= 0;
    final startIndex = resumed ? resumeIndex : 0;
    final startChapter = chapters.isEmpty ? null : chapters[startIndex];
    final resumeVerb = widget.kind == MediaKind.animation ? '续看' : '续读';
    final startVerb = widget.kind == MediaKind.animation ? '开始观看' : '开始阅读';

    return RefreshIndicator(
      onRefresh: () async {
        HttpCache.instance.markAllStale();
        final next = _load();
        setState(() {
          _future = next;
        });
        await next;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _trackHero,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ValueListenableBuilder<double>(
              valueListenable: _heroOffset,
              builder: (context, offset, _) => DetailHeroBar(
                comic: data.item,
                title: data.item.name,
                collapse: DetailHeroBar.collapseOf(offset, kDetailHeroHeight,
                    MediaQuery.paddingOf(context).top),
                // 轻小说与漫画同构：顶栏评论图标挂总数角标，点进去是独立评论页
                actions: [
                  if (widget.kind == MediaKind.novel &&
                      data.item.uuid.isNotEmpty)
                    CommentCountButton(
                      count: _commentTotal,
                      tooltip: t.novelCommentsTitle,
                      onPressed: () => _openComments(data.item.uuid),
                    ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                // 书名在 DetailHeroBar 的沉浸标题里，这里直接从元信息开始
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (data.item.authorLabel.isNotEmpty &&
                        data.item.authorLabel != '佚名')
                      _meta(
                          Icons.person_outline_rounded, data.item.authorLabel),
                    if (data.item.popularLabel.isNotEmpty)
                      _meta(Icons.local_fire_department_outlined,
                          '${data.item.popularLabel} 人气'),
                    if (data.item.updatedAt.isNotEmpty)
                      _meta(Icons.schedule_rounded,
                          data.item.updatedAt.split(' ').first),
                    _meta(
                        Icons.menu_book_rounded, '${data.chapterTotal} $label'),
                  ],
                ),
              ),
            ),
            if (data.summary.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  // 简介默认3 行，超出部分折叠，点开看全文：长简介会把目录整块推到屏幕外
                  child: ExpandableText(
                    text: data.summary,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                  ),
                ),
              ),
            ..._tagSlivers(data),
            // 主操作 + 收藏：与漫画详情页同一行布局
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: startChapter == null
                                ? null
                                : () => _openChapter(
                                      startChapter,
                                      startIndex,
                                      chapters,
                                      name: data.item.name,
                                      cover: data.item.cover,
                                    ),
                            icon:
                                const Icon(Icons.play_arrow_rounded, size: 20),
                            label: Text(
                              resumed
                                  ? '$resumeVerb ${startChapter!.name}'
                                  : startVerb,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(
                          onPressed:
                              _favBusy ? null : () => _toggleFavorite(data),
                          icon: Icon(isFav
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded),
                          label: Text(isFav ? '已收藏' : '收藏'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 两套真相写在按钮下面：这次收藏进本机还是进账号
                    Text(
                      loggedIn ? t.favoriteCloudHint : t.favoriteLocalHint,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHeader(title: '目录 · $label'),
            ),
            if (chapters.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text('暂无目录数据',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final c = chapters[i];
                    // 目录行：有封面显示缩略图，没有则不留占位
                    final cover = c.cover.isEmpty
                        ? null
                        : resolveImageUrl(c.cover, host: host);
                    return ListTile(
                      leading: cover == null
                          ? null
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: NetImage(
                                url: cover,
                                width: 62,
                                height: 62,
                                fit: BoxFit.cover,
                                errorBuilder: (_) => _coverFallback(scheme),
                              ),
                            ),
                      title: Text(c.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${c.count > 0 ? '${c.count} 页 · ' : ''}'
                        '${c.lines.isNotEmpty ? '${c.lines.length} 条线路' : '点击阅读'}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openChapter(c, i, chapters,
                          name: data.item.name, cover: data.item.cover),
                    );
                  },
                  childCount: chapters.length,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }

  /// 封面加载失败时的纯色占位：尺寸和位置与真实缩略图一致，行高不跳，但不再显示序号
  Widget _coverFallback(ColorScheme scheme) => Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
      );

  /// 作者 / 题材 / 改编 / 标签：点击后进入真实筛选结果页，值一律用 path_word
  List<Widget> _tagSlivers(ContentDetail data) {
    final groups = <(String, String, List<ThemeTag>)>[
      ('theme', '题材', data.tags('theme')),
      ('author', '作者', data.tags('author')),
      ('parody', '改编', data.tags('parodies')),
      ('tag', '标签', data.tags('tags')),
      // 动画详情 company 是单个对象，写真详情 mannequins 是数组
      ('company', '社团', data.tags('company')),
      ('mannequin', '模特', data.tags('mannequins')),
    ];
    final out = <Widget>[];
    for (final (key, title, tags) in groups) {
      if (tags.isEmpty) continue;
      out.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: tags
                    .map((tag) => ActionChip(
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(tag.name),
                          onPressed: tag.pathWord.isEmpty
                              ? null
                              : () => CatalogMoreScreen.openFilter(
                                    context,
                                    kind: widget.kind,
                                    title: '${widget.kind.label} · ${tag.name}',
                                    theme: key == 'theme' ? tag.pathWord : '',
                                    author: key == 'author' ? tag.pathWord : '',
                                    parody: key == 'parody' ? tag.pathWord : '',
                                    tag: key == 'tag' ? tag.pathWord : '',
                                    company:
                                        key == 'company' ? tag.pathWord : '',
                                    mannequin:
                                        key == 'mannequin' ? tag.pathWord : '',
                                  ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ));
    }
    return out;
  }
}
