import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content.dart';
import '../models/media_page.dart';
import '../services/api_client.dart';
import '../services/image_store.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/paged_image_reader.dart';
import '../widgets/request_error.dart';
import '../utils/frame_kick.dart';

/// 轻小说 / 写真阅读器（动画剧集在详情页展示线路，不进入此页）
void openContentReader(
  BuildContext context, {
  required MediaKind kind,
  required String pathWord,
  required List<ContentChapter> chapters,
  required int index,
  String name = '',
  String? cover,
}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ContentReaderScreen(
      kind: kind,
      pathWord: pathWord,
      chapters: chapters,
      index: index,
      name: name,
      cover: cover,
    ),
  ));
}

/// ContentReaderScreen — 轻小说 / 写真集的文字阅读页
class ContentReaderScreen extends StatefulWidget {
  final MediaKind kind;
  final String pathWord;
  final List<ContentChapter> chapters;
  final int index;
  final String name;
  final String? cover;

  const ContentReaderScreen({
    super.key,
    required this.kind,
    required this.pathWord,
    required this.chapters,
    required this.index,
    this.name = '',
    this.cover,
  });

  @override
  State<ContentReaderScreen> createState() => _ContentReaderScreenState();
}

/// _PhotoChapter — 写真一章的正文，外加这份正文属于哪一章
class _PhotoChapter {
  final String id;
  final List<ContentPage> pages;
  const _PhotoChapter(this.id, this.pages);
}

class _ContentReaderScreenState extends State<ContentReaderScreen> {
  late int _index;
  late Future<Object> _future;

  /// 已经预热过的图片 URL：翻回去 / 同一页重复 build 都不再重复下载
  final Set<String> _warmed = {};

  /// 写真当前看到第几页（0 开始），写进浏览记录
  int _page = 0;

  /// 把当前页往后几页提前下载进 ImageStore 的字节缓存
  void _warmAhead(List<ContentPage> pages, int from) {
    for (var i = from; i < pages.length && i <= from + 4; i++) {
      final page = pages[i];
      if (page.url.isEmpty) continue;
      if (!_warmed.add(page.url)) continue;
      unawaited(ImageStore.instance.warm(page.url));
    }
  }

  void _warmAfterFrame(List<ContentPage> pages, int from) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _warmAhead(pages, from);
    });
  }

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, widget.chapters.length - 1);
    _future = kickOnDone(_load());
    _recordAfterLoad(_future, _index);
  }

  /// 只有真的读到了才记进度：请求失败不写浏览记录，否则详情页的续读会指向一个点开就报错的章节
  void _recordAfterLoad(Future<Object> future, int index) {
    unawaited(future.then((_) => _record(index), onError: (Object _) {}));
  }

  void _record(int index, {int? page}) {
    if (!mounted || index < 0 || index >= widget.chapters.length) return;
    final chapter = widget.chapters[index];
    unawaited(context.read<AppState>().recordRead(
          pathWord: widget.pathWord,
          chapterUuid: chapter.id,
          chapterName: chapter.name,
          page: page ?? 0,
          name: widget.name,
          cover: widget.cover,
          kind: widget.kind,
        ));
  }

  String get _chapterId =>
      widget.chapters.isEmpty ? '' : widget.chapters[_index].id;

  String get _chapterName => widget.chapters.isEmpty
      ? widget.kind.label
      : widget.chapters[_index].name;

  Future<Object> _load() {
    final repo = context.read<Repository>();
    // 卷 / 章 id 为空时请求路径会缺最后一段，服务端就是404
    if (_chapterId.isEmpty) {
      return Future<Object>.error(const ApiException('缺少卷 / 章 id，无法打开阅读器'));
    }
    if (widget.kind == MediaKind.novel) {
      return repo.novelVolume(widget.pathWord, _chapterId);
    }
    // 这一章 id 与请求绑在一起返回：切章后 builder 才能认出这是上一章的数据
    final id = _chapterId;
    return repo
        .contentPages(widget.kind, widget.pathWord, id)
        .then<Object>((pages) => _PhotoChapter(id, pages));
  }

  void _goto(int index) {
    if (index < 0 || index >= widget.chapters.length) return;
    setState(() {
      _index = index;
      _page = 0;
      _future = kickOnDone(_load());
    });
    _recordAfterLoad(_future, index);
  }

  void _retry() => setState(() => _future = kickOnDone(_load()));

  @override
  Widget build(BuildContext context) {
    // 写真：整页翻页看图（与漫画阅读器同一套版式，支持双指缩放）
    if (widget.kind != MediaKind.novel) return _photoReader(context);

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_chapterName, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<Object>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return RequestErrorState(error: snapshot.error!, onRetry: _retry);
          }
          if (!snapshot.hasData) {
            // 轻小说正文是纯文本，加载时给一个转圈就够，整屏色块反而像卡死
            return const ContentReaderLoading();
          }
          final data = snapshot.data!;
          if (data is NovelVolume) {
            return _novelView(data);
          }
          return Center(
            child: Text('正文格式无法识别',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: _index > 0 ? () => _goto(_index - 1) : null,
                child: const Text('上一卷 / 上一章'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                onPressed: _index < widget.chapters.length - 1
                    ? () => _goto(_index + 1)
                    : null,
                child: const Text('下一卷 / 下一章'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 写真阅读器：与漫画阅读器同一套整页版式
  Widget _photoReader(BuildContext context) {
    final direction =
        context.select<AppState, ReadDirection>((app) => app.readDirection);
    final showIndicator =
        context.select<AppState, bool>((app) => app.showPageIndicator);

    return FutureBuilder<Object>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            backgroundColor: const Color(0xFF101014),
            body: SafeArea(
              child: Stack(
                children: [
                  ReaderErrorView(error: snapshot.error!, onRetry: _retry),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            backgroundColor: Color(0xFF101014),
            body: ReaderLoadingView(),
          );
        }
        final data = snapshot.data;
        // 只认当前这一章的正文：切章途中拿到的还是上一章的列表时先停在加载态
        if (data is! _PhotoChapter || data.id != _chapterId) {
          return const Scaffold(
            backgroundColor: Color(0xFF101014),
            body: ReaderLoadingView(),
          );
        }
        final pages = <ReaderPageImage>[
          for (final page in data.pages)
            if (page.url.isEmpty)
              const ReaderPageImage.url('')
            else
              ReaderPageImage.url(page.url),
        ];
        final hasImage = data.pages.any((page) => page.url.isNotEmpty);

        if (!hasImage) {
          return Scaffold(
            backgroundColor: const Color(0xFF101014),
            body: SafeArea(
              child: Stack(
                children: [
                  const Center(
                    child: Text('这一章暂无图片',
                        style: TextStyle(color: Colors.white70, fontSize: 14)),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // 预读：进页面先把当前页往后几页塞进 ImageStore，翻页不再等下载
        _warmAfterFrame(data.pages, _page);

        final at = _index;
        final prev = at > 0 ? at - 1 : null;
        final next = at + 1 < widget.chapters.length ? at + 1 : null;
        final title = widget.name.isEmpty ? widget.kind.label : widget.name;

        return Scaffold(
          backgroundColor: const Color(0xFF101014),
          body: PagedImageReader(
            // 换章时整体重建：回到第1 页、重置缩放
            key: ValueKey(_chapterId),
            pages: pages,
            title: title,
            subtitle: _chapterName,
            albumTitle: '$title $_chapterName',
            onBack: () => Navigator.of(context).pop(),
            direction: direction,
            showIndicator: showIndicator,
            initialPage: _page,
            onPageChanged: (i) {
              _page = i;
              _record(_index, page: i);
              // 翻页后继续往后预热：整页图较大，提前4 页开始下载
              _warmAhead(data.pages, i);
            },
            prevLabel: '上一章',
            nextLabel: '下一章',
            onPrev: prev == null ? null : () => _goto(prev),
            onNext: next == null ? null : () => _goto(next),
            actions: [
              IconButton(
                tooltip: '章节目录',
                icon: const Icon(Icons.list_rounded, color: Colors.white),
                onPressed: _showChapters,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 章节目录：写真一章就是一个章，用带名字的列表而不是数字格子，因为章名本身有信息量
  void _showChapters() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('章节目录',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                  const Spacer(),
                  Text('${widget.chapters.length} 章',
                      style: Theme.of(sheetContext).textTheme.labelMedium),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.chapters.length,
                itemBuilder: (context, i) {
                  final chapter = widget.chapters[i];
                  final current = i == _index;
                  return ListTile(
                    selected: current,
                    title: Text(chapter.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      chapter.count > 0 ? '${chapter.count} 页' : '点击阅读',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: current
                        ? const Icon(Icons.check_rounded)
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _goto(i);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 轻小说：正文来自 CDN .txt（GBK），按空行切段
  Widget _novelView(NovelVolume volume) {
    final theme = Theme.of(context);
    final paragraphs = volume.paragraphs;
    if (paragraphs.isEmpty) {
      return Center(
        child: Text('这一卷暂无正文',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return NovelParagraphs(paragraphs: paragraphs);
  }
}

/// NovelParagraphs — 轻小说正文：进卷直接是段落，前面不放任何分节入口
class NovelParagraphs extends StatelessWidget {
  final List<String> paragraphs;

  const NovelParagraphs({super.key, required this.paragraphs});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.85);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: paragraphs.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SelectableText(paragraphs[i], style: style),
      ),
    );
  }
}

/// ContentReaderLoading — 轻小说正文首屏加载态
class ContentReaderLoading extends StatelessWidget {
  const ContentReaderLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(strokeWidth: 2));
  }
}
