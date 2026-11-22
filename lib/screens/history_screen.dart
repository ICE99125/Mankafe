import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../models/media_page.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';

/// HistoryScreen — 浏览记录：对应原版瀏覽記錄页
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

/// _Cell — 网格里的一格：云端与本地记录统一成同一种形态再进网格
class _Cell {
  final String pathWord;
  final String title;
  final String? cover;
  final String popular;
  final String date;
  final bool fromCloud;

  const _Cell({
    required this.pathWord,
    required this.title,
    required this.cover,
    required this.popular,
    required this.date,
    required this.fromCloud,
  });
}

/// _KindPage — 一段（漫画 / 轻小说 / 写真集 / 动画）的分页状态
class _KindPage {
  /// 已合并好的网格数据：本机记录在前，云端按页追加
  final List<_Cell> cells = [];

  /// 已经吃进多少条云端条目，服务端 `offset` 就是它，本机兜底条目不计数
  int cloudOffset = 0;

  bool loading = false;
  bool loadingMore = false;
  bool hasMore = true;

  /// 是否已经起过一次请求
  bool requested = false;

  /// 首屏错误 / 续页错误，分开记：首屏失败退回本机记录，续页失败只影响页脚
  Object? error;
  Object? moreError;

  /// 丢弃过期响应（快速换段 / 下拉刷新时会有两个请求同时在飞）
  int requestId = 0;
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _kinds = <MediaKind>[
    MediaKind.comic,
    MediaKind.novel,
    MediaKind.photo,
    MediaKind.animation,
  ];
  static const _labels = <String>['漫画', '小说', '写真', '动画'];

  int _tab = 0;

  /// 每段各自的分页状态：换段回来不重拉，清空 / 登录态变化时整段失效
  final Map<MediaKind, _KindPage> _pages = {};
  final ScrollController _scroll = ScrollController();
  bool _loggedIn = false;

  /// 登录态是否已经和 [AppState] 对齐过
  bool _sessionSynced = false;

  /// 本次进页面后被长按删掉的条目：云端列表是拉取快照，删完要让这一格立刻消失，续页里再出现也要挡掉
  final Set<String> _deleted = {};

  bool _isDeleted(MediaKind kind, String pathWord) =>
      _deleted.contains('${kind.name}:$pathWord');

  MediaKind get _kind => _kinds[_tab];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(_kind, reset: true);
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  _KindPage _pageOf(MediaKind kind) => _pages.putIfAbsent(kind, _KindPage.new);

  /// 上拉续页：离底480 就开始拉下一页（与 [PagedMediaList] 同一档门槛）
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 480) _load(_kind, reset: false);
  }

  /// 拉一页
  Future<void> _load(MediaKind kind, {required bool reset}) async {
    final page = _pageOf(kind);
    if (reset) {
      // 已经在拉第一页：重入会把同一页拉两次（首屏一次 + 登录态对齐一次）
      if (page.loading) return;
    } else if (page.loading || page.loadingMore || !page.hasMore) {
      return;
    }
    final app = context.read<AppState>();
    final repo = context.read<Repository>();
    final id = ++page.requestId;
    setState(() {
      page.requested = true;
      if (reset) {
        page.loading = true;
        page.error = null;
        page.moreError = null;
      } else {
        page.loadingMore = true;
        page.moreError = null;
      }
    });
    try {
      if (!app.isLoggedIn) {
        // 未登录：只有本机记录，同步可得，没有下一页
        setState(() {
          if (reset) {
            page.cells
              ..clear()
              ..addAll(_localCells(kind, app));
          }
          page.hasMore = false;
          page.loading = false;
          page.loadingMore = false;
        });
        return;
      }
      final result =
          await repo.browsePage(kind, offset: reset ? 0 : page.cloudOffset);
      if (!mounted || id != page.requestId) return;
      // 云端条目自带热度：顺手回填本机记录，断网退回本机时卡片也不空着
      app.backfillHistoryPopular(kind, {
        for (final c in result.items)
          if (c.popular > 0) c.pathWord: c.popular,
      });
      setState(() {
        if (reset) {
          page.cells.clear();
          page.cloudOffset = 0;
          page.cells.addAll(_localCells(kind, app));
        }
        final seen = page.cells.map((c) => c.pathWord).toSet();
        for (final c in result.items) {
          // offset 只数云端条目，所以这个自增要放在过滤之前
          page.cloudOffset++;
          if (_isDeleted(kind, c.pathWord) || !seen.add(c.pathWord)) continue;
          page.cells.add(
            _Cell(
              pathWord: c.pathWord,
              title: c.name,
              cover: c.cover,
              popular: c.popularLabel,
              date: c.updatedAt.length >= 10
                  ? c.updatedAt.substring(0, 10)
                  : c.updatedAt,
              fromCloud: true,
            ),
          );
        }
        page.hasMore = result.hasMore;
        page.loading = false;
        page.loadingMore = false;
      });
    } catch (error) {
      if (!mounted || id != page.requestId) return;
      setState(() {
        if (reset) {
          page.error = error;
          page.cells
            ..clear()
            ..addAll(_localCells(kind, app));
          page.hasMore = false;
        } else {
          page.moreError = error;
        }
        page.loading = false;
        page.loadingMore = false;
      });
    }
  }

  List<_Cell> _localCells(MediaKind kind, AppState app) => [
        for (final e in app.history)
          if (e.kind == kind && !_isDeleted(kind, e.pathWord))
            _Cell(
              pathWord: e.pathWord,
              title: e.name.isEmpty ? e.pathWord : e.name,
              cover: e.cover,
              // 本机记录也有热度：打开详情页时记下来的，云端回填后再补一次
              popular: formatPopular(e.popular),
              date: _date(e.at),
              fromCloud: false,
            ),
      ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览记录'),
        actions: [
          TextButton(
            onPressed: () => _openEditor(),
            child: const Text('编辑'),
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, app, _) {
          if (!_sessionSynced) {
            _sessionSynced = true;
            _loggedIn = app.isLoggedIn;
          } else if (app.isLoggedIn != _loggedIn) {
            _loggedIn = app.isLoggedIn;
            _pages.clear();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _load(_kind, reset: true);
            });
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _tabs(scheme),
              if (!app.isLoggedIn) _note(scheme, '未登录 · 只显示本机记录，登录后显示账号里的记录'),
              Expanded(child: _body(context, app, scheme)),
            ],
          );
        },
      ),
    );
  }

  Widget _tabs(ColorScheme scheme) {
    Widget item(int i) {
      final on = i == _tab;
      return Expanded(
        child: InkWell(
          onTap: () {
            if (i == _tab) return;
            setState(() => _tab = i);
            // 换段回到顶部：各段数据长短不一，留着旧偏移会莫名停在半空
            if (_scroll.hasClients) _scroll.jumpTo(0);
            final page = _pageOf(_kinds[i]);
            if (page.cells.isEmpty && !page.loading) {
              _load(_kinds[i], reset: true);
            } else {
              // 已缓存：只可能缺内容撑不满一屏时的自动续页
              _fillViewportIfNeeded(_kinds[i]);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Text(
              _labels[i],
              textAlign: TextAlign.center,
              maxLines: 1,
              style: TextStyle(
                fontSize: 15,
                height: 1.15,
                fontWeight: on ? FontWeight.w500 : FontWeight.w500,
                color: on ? scheme.primary : scheme.onSurface,
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: [for (var i = 0; i < _labels.length; i++) item(i)]);
  }

  Widget _note(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );

  /// 内容区：懒加载 + 骨架屏
  Widget _body(BuildContext context, AppState app, ColorScheme scheme) {
    final kind = _kind;
    final page = _pageOf(kind);
    // 未登录：本机记录同步可得，不需要骨架，也没有下一页
    final cells = app.isLoggedIn ? page.cells : _localCells(kind, app);
    final view = CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (app.isLoggedIn && page.error != null && cells.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: RequestErrorState(
              error: page.error!,
              onRetry: () => _load(kind, reset: true),
            ),
          )
        else if (app.isLoggedIn &&
            cells.isEmpty &&
            (page.loading || !page.requested))
          // 骨架是 box 组件（内部是 GridView），塞进 slivers 必须包成 sliver
          const SliverToBoxAdapter(
            child: MediaGridSkeleton(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 28),
              textExtent:
                  kCardTextExtent - kCardTitleAuthorGap - kCardAuthorHeight,
            ),
          )
        else if (cells.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _empty(scheme, cloudFailed: page.error != null),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverGrid(
              // 浏览记录卡片不显示作者行，网格高度也扣掉这一行，卡片底部不会留下一条空白
              gridDelegate: const TripleGridDelegate(
                textExtent:
                    kCardTextExtent - kCardTitleAuthorGap - kCardAuthorHeight,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _cellCard(context, app, cells[i]),
                childCount: cells.length,
              ),
            ),
          ),
        // 空态 / 骨架 / 整页错误态不挂页脚：那时没有内容，页脚只会多出一行加载更多或已经到底了
        if (cells.isNotEmpty) _footer(context, app, page, kind),
      ],
    );
    // 未登录也保留下拉刷新：刷的是本机记录，和登录态无关
    _fillViewportIfNeeded(kind);
    return RefreshIndicator(
      onRefresh: () => _load(kind, reset: true),
      child: view,
    );
  }

  /// 内容撑不满一屏时主动续一页
  void _fillViewportIfNeeded(MediaKind kind) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final page = _pageOf(kind);
      if (page.loading || page.loadingMore || !page.hasMore) return;
      if (!_scroll.hasClients) return;
      if (!_scroll.position.hasContentDimensions) return;
      if (_scroll.position.maxScrollExtent <= 0) _load(kind, reset: false);
    });
  }

  /// 页脚：加载更多 / 点击重试 / 已经到底了
  Widget _footer(
      BuildContext context, AppState app, _KindPage page, MediaKind kind) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget child;
    if (!app.isLoggedIn) {
      return const SliverToBoxAdapter(child: SizedBox(height: 28));
    }
    if (page.error != null) {
      child = Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 14, color: scheme.onSurfaceVariant),
          Text(
            '账号记录拉取失败 · 只显示本机记录',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          TextButton(
            onPressed: () => _load(kind, reset: true),
            child: Text(t.retry),
          ),
        ],
      );
    } else if (page.loadingMore) {
      child = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (page.moreError != null) {
      child = TextButton.icon(
        onPressed: () => _load(kind, reset: false),
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text(t.loadMoreFailed),
      );
    } else if (!page.hasMore) {
      child = Text(
        t.noMore,
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
      );
    } else {
      // 还有下一页但当前没有请求在飞，给一个可点的入口，不要留一块看不见的空白
      child = TextButton(
        onPressed: () => _load(kind, reset: false),
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

  Widget _empty(ColorScheme scheme, {required bool cloudFailed}) {
    final label = _labels[_tab];
    return EmptyState(
      icon: Icons.history_toggle_off_rounded,
      title: '还没有$label浏览记录',
      message: cloudFailed
          ? '账号记录拉取失败（网络或登录状态异常），本机也没有这一类的记录'
          : (_loggedIn ? '在账号里打开过的$label会显示在这里' : '打开任意$label作品，看过就会记在这里'),
    );
  }

  Widget _cellCard(BuildContext context, AppState app, _Cell cell) {
    return GestureDetector(
      onLongPress: () => _confirmDelete(context, app, cell),
      child: RichGridCard(
        title: cell.title,
        author: '',
        popular: cell.popular.isEmpty ? null : cell.popular,
        date: cell.date.isEmpty ? null : cell.date,
        coverUrl: cell.cover,
        onTap: () => _open(cell.pathWord),
      ),
    );
  }

  static String _date(DateTime at) {
    if (at.millisecondsSinceEpoch == 0) return '';
    final d = at.toLocal();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  void _open(String pathWord) {
    if (pathWord.isEmpty) return;
    if (_kind == MediaKind.comic) {
      openComicDetail(context, pathWord);
    } else {
      openContentDetail(context, _kind, pathWord);
    }
  }

  /// 顶栏编辑：底部分类清空菜单
  Future<void> _openEditor() async {
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: scheme.surfaceContainerLow,
      barrierColor: scheme.scrim.withValues(alpha: 0.32),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheet) => EditorSheet(
        kinds: _kinds,
        labels: _labels,
        onClear: (kind) {
          Navigator.of(sheet).pop();
          _confirmClear(kind);
        },
      ),
    );
  }

  /// 清空某一类：本机 + 账号
  Future<void> _confirmClear(MediaKind kind) async {
    final app = context.read<AppState>();
    final repo = context.read<Repository>();
    final label = _labels[_kinds.indexOf(kind)];
    final loggedIn = app.isLoggedIn;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空$label浏览记录？'),
        content: Text(loggedIn
            ? '会同时清空本机和账号里这一类的浏览记录，其他三类不受影响。'
            : '会清空本机这一类的浏览记录，其他三类不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    String? cloudError;
    if (loggedIn) {
      try {
        await repo.clearBrowse(kind);
      } catch (e) {
        cloudError = _readable(e);
      }
    }
    await app.clearHistory(kind: kind);
    if (!mounted) return;
    setState(() => _pages.remove(kind));
    if (kind == _kind) {
      _load(kind, reset: true);
    }
    _toast(cloudError == null
        ? (loggedIn ? '已清空$label的浏览记录' : '已清空$label的浏览记录')
        : '本机已清空；账号里这一类没清掉：$cloudError');
  }

  /// 长按一格：只删这一条
  Future<void> _confirmDelete(
      BuildContext pageCtx, AppState app, _Cell cell) async {
    final localOnly = !cell.fromCloud ||
        app.history.any((e) => e.kind == _kind && e.pathWord == cell.pathWord);
    final ok = await showDialog<bool>(
      context: pageCtx,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: Text(localOnly
            ? '只会删掉这条浏览记录，书架收藏和阅读进度不受影响。'
            : '这条只在账号里有。删掉后这一格立即消失，但重新进页面还会从账号读回来——'
                '要彻底清掉请用「编辑 → 清空浏览记录」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await app.removeHistory(_kind, cell.pathWord);
    if (!mounted) return;
    // 云端列表是拉取出来的快照，删完要让这一格也从页面上消失（续页再出现也挡住）
    setState(() {
      _deleted.add('${_kind.name}:${cell.pathWord}');
      _pageOf(_kind).cells.removeWhere((c) => c.pathWord == cell.pathWord);
    });
    _toast(localOnly ? '已删除这条记录' : '已从列表移除；账号里这条要用整类清空才会彻底清掉');
  }

  String _readable(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

/// EditorSheet — 编辑底部菜单本体，MD3 modal bottom sheet 版式
class EditorSheet extends StatelessWidget {
  const EditorSheet({
    super.key,
    required this.kinds,
    required this.labels,
    required this.onClear,
  });

  final List<MediaKind> kinds;
  final List<String> labels;
  final ValueChanged<MediaKind> onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拖拽把手下面留一点呼吸，让第一行不像贴着把手
          const SizedBox(height: 4),
          for (var i = 0; i < kinds.length; i++)
            _row(
              context,
              icon: Icons.delete_outline_rounded,
              title: '清空${labels[i]}',
              background: scheme.errorContainer,
              foreground: scheme.onErrorContainer,
              onTap: () => onClear(kinds[i]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: scheme.onSurfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }

  /// 图标底：MD3 里用来把动作类型一眼分开，比裸图标更有层次
  Widget _leading({
    required IconData icon,
    required Color background,
    required Color foreground,
    double size = 40,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size <= 32 ? size / 2 : 14),
      ),
      child: Icon(icon, size: size / 2, color: foreground),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        // MD3 列表行高56dp 起：40dp 图标底 + 上下4dp，比默认更紧凑
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 20, 4),
        minVerticalPadding: 4,
        leading: _leading(
          icon: icon,
          background: background,
          foreground: foreground,
        ),
        title: Text(
          title,
          style: theme.textTheme.bodyLarge
              ?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
        horizontalTitleGap: 14,
      ),
    );
  }
}
