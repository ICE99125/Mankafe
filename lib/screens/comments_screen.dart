import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/chapter.dart';
import '../models/media_page.dart';
import '../services/http_cache.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/comment_widgets.dart';
import '../widgets/page_pager.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';

/// ComicCommentsScreen — 评论页，漫画/轻小说整本评论与章节吐槽
class ComicCommentsScreen extends StatefulWidget {
  final String pathWord;

  /// 漫画 uuid，为空时由 [pathWord] 取详情补全
  final String comicId;

  /// 轻小说 uuid，非空时走轻小说评论接口
  final String bookId;

  /// 章节 uuid，非空时走章节吐槽接口
  final String chapterUuid;

  /// 三者互斥，按传入的那一个决定接口
  const ComicCommentsScreen({
    super.key,
    required this.pathWord,
    this.comicId = '',
    this.bookId = '',
    this.chapterUuid = '',
  });

  @override
  State<ComicCommentsScreen> createState() => _ComicCommentsScreenState();
}

class _ComicCommentsScreenState extends State<ComicCommentsScreen> {
  /// 每页条数，同时是分页器的分母
  static const int _pageSize = 20;

  final List<ComicComment> _items = [];
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 当前评论对象 id，漫画/轻小说为作品 uuid
  String _targetId = '';
  int _total = 0;

  /// 当前页，0 起始
  int _page = 0;

  bool _closeComment = false;
  bool _loading = true;
  bool _sending = false;
  bool _noticeExpanded = false;
  Object? _error;

  /// 回复目标，非空时发表带 reply_id
  ComicComment? _replyTarget;
  String _replyRootId = '';

  /// 已拉过的回复树，key 为顶层评论 id
  final Map<String, List<ComicComment>> _threads = {};
  final Set<String> _expanded = {};
  final Set<String> _threadLoading = {};
  final Map<String, Object> _threadErrors = {};

  /// 章节吐槽模式
  bool get _isRoast => widget.chapterUuid.isNotEmpty;

  /// 轻小说评论模式
  bool get _isBook => widget.bookId.isNotEmpty;

  /// 整本评论，有回复树
  bool get _isWholeBook => !_isRoast;

  int get _pageCount =>
      _total <= 0 ? 1 : ((_total + _pageSize - 1) ~/ _pageSize);

  /// 只有一页时不显示分页器
  bool get _showPager => _total > _pageSize;

  @override
  void initState() {
    super.initState();
    _targetId = _isBook ? widget.bookId : widget.comicId;
    _loadPage(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 补全评论对象 id，漫画走 /comic/{path_word}
  Future<String> _ensureTargetId() async {
    if (_targetId.isNotEmpty) return _targetId;
    final repo = context.read<Repository>();
    _targetId = _isBook
        ? (await repo.contentDetail(MediaKind.novel, widget.pathWord)).item.uuid
        : (await repo.detail(widget.pathWord)).comic.uuid;
    return _targetId;
  }

  /// 拉某一页，offset = 页码 × _pageSize
  Future<CommentPage> _fetchPage(int page) async {
    final repo = context.read<Repository>();
    final offset = page * _pageSize;
    if (_isRoast) {
      return repo.roastsPage(widget.chapterUuid,
          offset: offset, limit: _pageSize);
    }
    final id = await _ensureTargetId();
    return _isBook
        ? repo.bookCommentsPage(id, offset: offset, limit: _pageSize)
        : repo.commentsPage(id, offset: offset, limit: _pageSize);
  }

  /// 整页换：清掉上一页条目后拉目标页
  Future<void> _loadPage(int page) async {
    var target = page < 0 ? 0 : page;
    setState(() {
      _loading = true;
      _error = null;
      _page = target;
      // 换页后旧的回复树和回复态失效
      _threads.clear();
      _expanded.clear();
      _threadErrors.clear();
      _threadLoading.clear();
      _replyTarget = null;
      _replyRootId = '';
    });
    var clamped = false;
    while (true) {
      try {
        final result = await _fetchPage(target);
        if (!mounted) return;
        if (result.items.isEmpty && target > 0 && !clamped) {
          clamped = true;
          _total = target * _pageSize;
          target -= 1;
          continue;
        }
        setState(() {
          _items
            ..clear()
            ..addAll(result.items);
          _total = result.total < result.items.length
              ? result.items.length
              : result.total;
          _closeComment = result.closeComment;
          _loading = false;
          _error = null;
          _page = target;
        });
        _jumpToTop();
        return;
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _error = error;
          _loading = false;
        });
        return;
      }
    }
  }

  /// 翻页后回到列表顶部
  void _jumpToTop() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  Future<void> _refresh() async {
    HttpCache.instance.markAllStale();
    await _loadPage(_page);
  }

  /// 点回复：把输入栏切成回复态，并把这条评论的回复树展开
  void _replyTo(ComicComment comment, {String? rootId}) {
    if (comment.id.isEmpty) return;
    final root = rootId ?? comment.id;
    setState(() {
      _replyTarget = comment;
      _replyRootId = root;
    });
    _inputFocus.requestFocus();
    _expandThread(root);
  }

  void _cancelReply() {
    setState(() {
      _replyTarget = null;
      _replyRootId = '';
    });
  }

  /// 当前登录账号 id：只有自己发的评论 / 回复才显示删除
  String get _myUserId => context.read<AppState>().authUser?.userId ?? '';

  bool _isMine(ComicComment comment) {
    final me = _myUserId;
    return me.isNotEmpty && comment.userId == me;
  }

  /// 删除一条评论 / 回复
  Future<void> _deleteComment(ComicComment comment,
      {String rootId = ''}) async {
    final t = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(t.commentDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.commentDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final repo = context.read<Repository>();
      // 吐槽 / 评论 / 轻小说评论是三套接口
      if (_isRoast) {
        await repo.deleteRoast(widget.chapterUuid, comment.id);
      } else {
        final id = await _ensureTargetId();
        if (_isBook) {
          await repo.deleteBookComment(id, comment.id);
        } else {
          await repo.deleteComment(id, comment.id);
        }
      }
      HttpCache.instance.markAllStale();
      if (!mounted) return;
      setState(() {
        if (rootId.isEmpty) {
          _items.removeWhere((c) => c.id == comment.id);
          if (_total > 0) _total -= 1;
          _threads.remove(comment.id);
          _expanded.remove(comment.id);
          _threadErrors.remove(comment.id);
        } else {
          final list = _threads[rootId];
          if (list != null) {
            _threads[rootId] =
                list.where((c) => c.id != comment.id).toList(growable: false);
          }
          final index = _items.indexWhere((c) => c.id == rootId);
          if (index >= 0 && _items[index].replyCount > 0) {
            _items[index] = _items[index]
                .copyWith(replyCount: _items[index].replyCount - 1);
          }
        }
        // 删掉的正好是回复目标时，退出回复态，免得把下一条发到已删除评论下
        if (_replyTarget?.id == comment.id) {
          _replyTarget = null;
          _replyRootId = '';
        }
      });
      if (rootId.isNotEmpty) await _loadThread(rootId);
      if (mounted) _toast(t.commentDeleted);
    } catch (error) {
      if (!mounted) return;
      _toast(describeRequestError(t, error).message);
    }
  }

  /// 展开一棵回复树
  void _expandThread(String rootId) {
    if (rootId.isEmpty || !_isWholeBook) return;
    final first = !_expanded.contains(rootId);
    setState(() => _expanded.add(rootId));
    if (first ||
        _threads[rootId] == null ||
        _threadErrors.containsKey(rootId)) {
      _loadThread(rootId);
    }
  }

  /// 再点一次收起，已加载过的直接复用
  void _toggleThread(String rootId) {
    if (_expanded.contains(rootId) && _threads.containsKey(rootId)) {
      setState(() => _expanded.remove(rootId));
      return;
    }
    setState(() => _expanded.add(rootId));
    if (_threads[rootId] == null || _threadErrors.containsKey(rootId)) {
      _loadThread(rootId);
    }
  }

  /// 拉一条评论下面的整棵回复树（服务端一次给出所有层级）
  Future<void> _loadThread(String rootId) async {
    if (!_isWholeBook) return;
    setState(() {
      _threadLoading.add(rootId);
      _threadErrors.remove(rootId);
    });
    try {
      final repo = context.read<Repository>();
      final id = await _ensureTargetId();
      final page = _isBook
          ? await repo.bookCommentThread(id, rootId, limit: 100)
          : await repo.commentThread(id, rootId, limit: 100);
      if (!mounted) return;
      setState(() {
        _threads[rootId] = page.items;
        // 父评论回复数以服务端树 total 为准，count 在老数据里可能偏大
        final index = _items.indexWhere((c) => c.id == rootId);
        if (index >= 0 && _items[index].replyCount != page.total) {
          _items[index] = _items[index].copyWith(replyCount: page.total);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _threadErrors[rootId] = error);
    } finally {
      if (mounted) setState(() => _threadLoading.remove(rootId));
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    if (_sending) return;
    final t = AppLocalizations.of(context);
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (!context.read<AppState>().isLoggedIn) {
      _toast(t.commentSignInFirst);
      return;
    }
    final target = _replyTarget;
    final rootId = _replyRootId;
    setState(() => _sending = true);
    try {
      final repo = context.read<Repository>();
      if (_isRoast) {
        // 章节吐槽接口没有回复能力，所以吐槽只有顶层一条，这里不会带 `reply_id`
        await repo.postRoast(widget.chapterUuid, text);
      } else {
        final id = await _ensureTargetId();
        if (_isBook) {
          await repo.postBookComment(id, text, replyId: target?.id ?? '');
        } else {
          await repo.postComment(id, text, replyId: target?.id ?? '');
        }
      }
      if (!mounted) return;
      _controller.clear();
      _inputFocus.unfocus();
      _cancelReply();
      if (target == null) {
        // 顶层评论落在第一页：先把评论缓存全部打旧，再回第1 页重新拉
        HttpCache.instance.markAllStale();
        await _loadPage(0);
        if (mounted) _toast(t.commentPosted);
        return;
      }
      // 回复不进顶层列表：强制走网络，把这条回复所在的树重新拉一遍并展开
      HttpCache.instance.markAllStale();
      setState(() => _expanded.add(rootId));
      await _loadThread(rootId);
      if (mounted) _toast(t.commentReplyPosted);
    } catch (error) {
      if (!mounted) return;
      _toast(describeRequestError(t, error).message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final host = context.read<Repository>().imageHost;
    final title = _isRoast
        ? (_total > 0
            ? t.chapterRoastTitleWithCount(_total)
            : t.chapterRoastTitle)
        : _isBook
            ? (_total > 0
                ? t.novelCommentTitleWithCount(_total)
                : t.novelCommentsTitle)
            : (_total > 0 ? t.commentTitleWithCount(_total) : t.commentsTitle);
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: Text(title)),
      body: Column(
        // 同上：stretch 让提示条 / 列表 / 分页器 / 输入栏都按屏宽铺满，不被居中
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_isRoast) _noticeBar(theme, t),
          // 翻页时旧的一页先留在屏上，顶上一条细进度条说明正在换页，比整页塌成骨架屏再长回来更稳
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(theme, t, host)),
          if (_showPager && _error == null) _pager(theme),
          _inputArea(theme, t),
        ],
      ),
    );
  }

  /// 分页器：固定在输入栏上方，翻到第几页、还有没有下一页一眼可见
  Widget _pager(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: PagePager(
        page: _page,
        pageCount: _pageCount,
        total: _total,
        pageSize: _pageSize,
        onPage: (page) {
          // 上一页还在路上时忽略第二次点击，避免两个请求交叉写回页码
          if (_loading) return;
          _loadPage(page);
        },
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      ),
    );
  }

  Widget _body(ThemeData theme, AppLocalizations t, String? host) {
    // 换页失败时整页给错误态：留着上一页的条目会让人以为翻过去内容没变
    if (_error != null) {
      return RequestErrorState(error: _error!, onRetry: () => _loadPage(_page));
    }
    if (_loading && _items.isEmpty) return const TileListSkeleton(count: 6);
    return RefreshIndicator(
      onRefresh: _refresh,
      child:
          _items.isEmpty ? _emptyList(theme, t) : _commentList(theme, t, host),
    );
  }

  /// 空态也包一层可滚动的 ListView：否则 RefreshIndicator 拉不动
  Widget _emptyList(ThemeData theme, AppLocalizations t) {
    return ListView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.16),
        EmptyState(
          icon: Icons.forum_outlined,
          title: t.commentEmpty,
          message: t.commentEmptyHint,
          action: _closeComment
              ? null
              : FilledButton.tonalIcon(
                  onPressed: () => _inputFocus.requestFocus(),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t.commentFirstOne),
                ),
        ),
      ],
    );
  }

  Widget _commentList(ThemeData theme, AppLocalizations t, String? host) {
    // 用 builder + 手工分隔线
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final comment = _items[i];
        final canReply = _isWholeBook && !_closeComment;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CommentTile(
              comment: comment,
              host: host,
              onReply: canReply ? () => _replyTo(comment) : null,
              onToggleReplies: comment.replyCount > 0
                  ? () => _toggleThread(comment.id)
                  : null,
              onDelete: _isMine(comment)
                  ? () {
                      _deleteComment(comment);
                    }
                  : null,
              expanded: _expanded.contains(comment.id),
              loadingReplies: _threadLoading.contains(comment.id),
            ),
            if (_expanded.contains(comment.id))
              _threadSection(theme, t, host, comment, canReply),
            if (i != _items.length - 1) const Divider(height: 22, indent: 52),
          ],
        );
      },
    );
  }

  /// 展开在这条评论下面的回复树：加载中 / 失败可重试 / 空回复 / 正文
  Widget _threadSection(
    ThemeData theme,
    AppLocalizations t,
    String? host,
    ComicComment root,
    bool canReply,
  ) {
    final scheme = theme.colorScheme;
    final error = _threadErrors[root.id];
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(left: 52, top: 2, bottom: 8),
        child: InkWell(
          onTap: () => _loadThread(root.id),
          child: Row(
            children: [
              Icon(Icons.refresh_rounded, size: 14, color: scheme.primary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  t.commentReplyLoadFailed,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.primary),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_threadLoading.contains(root.id) && _threads[root.id] == null) {
      return Padding(
        padding: const EdgeInsets.only(left: 64, top: 6, bottom: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 6),
            Text(
              t.commentLoadingMore,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final replies = _threads[root.id] ?? const <ComicComment>[];
    if (replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 64, top: 4, bottom: 8),
        child: Text(
          t.commentNoReplies,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 52),
      child: CommentThreadList(
        replies: replies,
        rootId: root.id,
        host: host,
        onReply: canReply ? (reply) => _replyTo(reply, rootId: root.id) : null,
        onDelete: (reply) {
          _deleteComment(reply, rootId: root.id);
        },
        canDelete: _isMine,
      ),
    );
  }

  Widget _noticeBar(ThemeData theme, AppLocalizations t) {
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.tertiaryContainer.withValues(alpha: 0.35),
      child: Column(
        // 默认 center 会让短句正文收缩成文本宽 + padding再被居中
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _noticeExpanded = !_noticeExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    t.commentNotice,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Icon(
                    _noticeExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_noticeExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                t.commentNoticeBody,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputArea(ThemeData theme, AppLocalizations t) {
    final scheme = theme.colorScheme;
    if (_closeComment) {
      return SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            border: Border(
              top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                _isRoast
                    ? t.chapterRoastClosed
                    : _isBook
                        ? t.novelCommentClosed
                        : t.commentClosed,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top:
                BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTarget != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 0, 6),
                child: Row(
                  children: [
                    Icon(Icons.reply_rounded, size: 15, color: scheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        t.commentReplyTo(_replyTarget!.userName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelReply,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(t.commentCancelReply,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _inputFocus,
                    maxLength: 200,
                    minLines: 1,
                    maxLines: 3,
                    buildCounter: (context,
                            {required currentLength,
                            required isFocused,
                            maxLength}) =>
                        null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _replyTarget != null
                          ? t.commentReplyTo(_replyTarget!.userName)
                          : (_isRoast ? t.chapterRoastHint : t.commentHint),
                      isDense: true,
                      filled: true,
                      fillColor:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                  tooltip: _replyTarget != null
                      ? t.sendReplyTooltip
                      : t.sendCommentTooltip,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
