import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chapter.dart';
import '../models/comic.dart';
import '../services/api_client.dart';
import '../services/download_manager.dart';
import '../services/image_store.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/paged_image_reader.dart';
import '../utils/frame_kick.dart';
import 'comments_screen.dart';
void openReader(
  BuildContext context, {
  required String pathWord,
  required String chapterUuid,
  String? groupPathWord,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
        pathWord: pathWord,
        chapterUuid: chapterUuid,
        groupPathWord: groupPathWord,
      ),
    ),
  );
}

/// _ReaderData — 阅读器一次拉取的数据包
class _ReaderData {
  final Comic comic;
  final List<Chapter> chapters;
  final ChapterContent content;

  /// 这一份数据到底属于哪一话
  final String chapterUuid;

  const _ReaderData(this.comic, this.chapters, this.content, this.chapterUuid);
}

/// ReaderScreen — 漫画阅读器页
class ReaderScreen extends StatefulWidget {
  final String pathWord;
  final String chapterUuid;

  /// 详情页当前选中的章节栏目（分组）的 path_word
  final String? groupPathWord;

  const ReaderScreen({
    super.key,
    required this.pathWord,
    required this.chapterUuid,
    this.groupPathWord,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late String _chapterUuid;
  late Future<_ReaderData> _future;

  /// 当前作品的真实信息，阅读进度写回时一并记进历史
  Comic? _comic;

  /// 当前页（0 开始）
  int _pageIndex = 0;

  /// 已经预热过的图片 URL，避免同一页反复触发下载
  final Set<String> _preloaded = {};
  bool _warmStarted = false;

  /// 已经记过进度的那一话
  String? _progressRecordedFor;

  /// 预读页数：当前页之后3 页
  static const int _preloadAhead = 3;

  @override
  void initState() {
    super.initState();
    _chapterUuid = widget.chapterUuid;
    _future = kickOnDone(_load(_chapterUuid));
  }

  /// 预热 [index] 之后的若干页
  void _preloadFrom(int index, List<ComicImage> images) {
    for (var step = 1; step <= _preloadAhead; step++) {
      final i = index + step;
      if (i < 0 || i >= images.length) break;
      final url = images[i].url;
      if (url == null || url.isEmpty) continue;
      if (!_preloaded.add(url)) continue;
      if (kDebugMode) debugPrint('[reader] 预读第 ${i + 1} 页');
      unawaited(ImageStore.instance.warm(url));
    }
  }

  Future<_ReaderData> _load(String uuid) async {
    final repo = context.read<Repository>();
    final detail = await repo.detail(widget.pathWord);
    final group = widget.groupPathWord ??
        (detail.groups.isEmpty ? 'default' : detail.groups.first.pathWord);
    final chapters = await repo.chapters(widget.pathWord, group: group);
    // 兜底：续读目标可能是空的（作品级浏览记录）或已失效
    var target = uuid;
    if (target.isEmpty) {
      target = chapters.isEmpty ? '' : chapters.first.uuid;
    } else if (widget.groupPathWord != null &&
        chapters.isNotEmpty &&
        !chapters.any((c) => c.uuid == target)) {
      // 栏目已知，但这一话已经不在目录里：回退第一话，不去打一个注定404 的旧章节
      target = chapters.first.uuid;
    }
    if (target.isEmpty) {
      throw const ApiException('缺少章节 id，无法打开阅读器');
    }
    // 进度写回要用真正打开的那一话，不能沿用传进来的空 / 失效 id
    if (_chapterUuid == uuid) {
      _chapterUuid = target;
    }
    final content = await _loadContent(repo, target, chapters);
    return _ReaderData(detail.comic, chapters, content, target);
  }

  /// 已下载的话直接读本地
  Future<ChapterContent> _loadContent(
    Repository repo,
    String uuid,
    List<Chapter> chapters,
  ) async {
    final downloads = context.read<DownloadManager>();
    final entry = downloads.chapterOf(uuid);
    if (entry != null) {
      return ChapterContent(
        chapterUuid: uuid,
        name: entry.chapterName,
        images: List<ComicImage>.generate(
          entry.files.length,
          (i) => ComicImage(index: i),
        ),
        next: entry.next.isEmpty ? null : entry.next,
        prev: entry.prev.isEmpty ? null : entry.prev,
      );
    }
    return repo.chapterContent(widget.pathWord, uuid, chapters);
  }

  void _record(String chapterName) {
    context.read<AppState>().recordRead(
          pathWord: widget.pathWord,
          chapterUuid: _chapterUuid,
          chapterName: chapterName,
          page: _pageIndex,
          name: _comic?.name ?? '',
          cover: _comic?.cover,
          groupPathWord: widget.groupPathWord,
        );
  }

  void _goChapter(String uuid) {
    if (uuid.isEmpty || uuid == _chapterUuid) return;
    final future = kickOnDone(_load(uuid));
    setState(() {
      _chapterUuid = uuid;
      _pageIndex = 0;
      _warmStarted = false;
      _preloaded.clear();
      _future = future;
    });
  }

  void _showChapters(List<Chapter> chapters) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('章节目录', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Text('${chapters.length} 话 · 全部可读',
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.3),
                itemCount: chapters.length,
                itemBuilder: (context, i) => OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: chapters[i].uuid == _chapterUuid
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _goChapter(chapters[i].uuid);
                  },
                  child: Text('${chapters[i].index + 1}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一话的整页图：已下载的页给本地文件，其余给图床 URL
  List<ReaderPageImage> _pages(List<ComicImage> images) {
    if (images.isEmpty) return const <ReaderPageImage>[];
    final downloads = context.read<DownloadManager>();
    return List<ReaderPageImage>.generate(images.length, (i) {
      final local = downloads.localFile(_chapterUuid, i);
      if (local != null) return ReaderPageImage.local(local);
      return ReaderPageImage.url(images[i].url ?? '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final direction =
        context.select<AppState, ReadDirection>((app) => app.readDirection);
    final showIndicator =
        context.select<AppState, bool>((app) => app.showPageIndicator);

    return FutureBuilder<_ReaderData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: const Color(0xFF101014),
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: ReaderErrorView(
              error: snapshot.error!,
              onRetry: () =>
                  setState(() => _future = kickOnDone(_load(_chapterUuid))),
            ),
          );
        }
        if (!snapshot.hasData) {
          // 漫画阅读器首屏：整屏一整块骨架色（原版就是一整屏占位），不再用一页一张圆角灰卡的分块骨架
          return const Scaffold(
            backgroundColor: Color(0xFF101014),
            body: ReaderLoadingView(),
          );
        }
        final data = snapshot.data!;
        // 切话时这一份数据还属于上一话：继续拿它建阅读器
        if (data.chapterUuid != _chapterUuid) {
          return const Scaffold(
            backgroundColor: Color(0xFF101014),
            body: ReaderLoadingView(),
          );
        }
        _comic = data.comic;
        final images = data.content.images;
        final pages = _pages(images);

        // 真正加载成功就算读到这一话：只打开、不翻页也要写进度，否则详情页的续读会一直停在上一话
        if (_progressRecordedFor != _chapterUuid) {
          _progressRecordedFor = _chapterUuid;
          final openedUuid = _chapterUuid;
          final openedName = data.content.name;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _chapterUuid != openedUuid) return;
            _record(openedName);
          });
        }

        // 首屏先预热前几页：进来就能直接翻，不用等第一张图下载完
        if (!_warmStarted) {
          _warmStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _preloadFrom(_pageIndex, images);
          });
        }

        final at = data.chapters.indexWhere((c) => c.uuid == _chapterUuid);
        final prev = at > 0 ? data.chapters[at - 1].uuid : null;
        final next = at >= 0 && at + 1 < data.chapters.length
            ? data.chapters[at + 1].uuid
            : null;

        return Scaffold(
          backgroundColor: const Color(0xFF101014),
          body: PagedImageReader(
            // 换话时整体重建：回到第1 页、重置缩放，不复用上一话的页状态
            key: ValueKey(_chapterUuid),
            pages: pages,
            title: data.comic.name,
            subtitle: data.content.name,
            albumTitle: '${data.comic.name} ${data.content.name}',
            onBack: () => Navigator.of(context).pop(),
            direction: direction,
            showIndicator: showIndicator,
            initialPage: _pageIndex,
            onPageChanged: (i) {
              _pageIndex = i;
              _record(data.content.name);
              _preloadFrom(i, images);
            },
            prevLabel: '上一话',
            nextLabel: '下一话',
            onPrev: prev == null ? null : () => _goChapter(prev),
            onNext: next == null ? null : () => _goChapter(next),
            actions: [
              IconButton(
                tooltip: '章节目录',
                icon: const Icon(Icons.list_rounded, color: Colors.white),
                onPressed: () => _showChapters(data.chapters),
              ),
              IconButton(
                tooltip: '章节吐槽',
                icon: const Icon(Icons.comment_outlined, color: Colors.white),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ComicCommentsScreen(
                        pathWord: widget.pathWord,
                        chapterUuid: _chapterUuid,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
