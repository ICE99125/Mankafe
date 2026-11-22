import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/image_store.dart';
import '../state/app_state.dart';
import 'net_image.dart';
import 'request_error.dart';
import 'save_to_album.dart';
import 'skeleton.dart';

/// ReaderPageImage — 一页整页图，网络 URL 或已下载的本地文件
@immutable
class ReaderPageImage {
  final String url;

  /// 已下载的漫画页，直接读文件
  final File? file;

  const ReaderPageImage.url(this.url) : file = null;
  const ReaderPageImage.local(File this.file) : url = '';

  bool get isEmpty => url.isEmpty && file == null;
}

/// PagedImageReader — 整页图片阅读器，左右翻页 + 缩放
class PagedImageReader extends StatefulWidget {
  const PagedImageReader({
    super.key,
    required this.pages,
    required this.title,
    required this.subtitle,
    required this.albumTitle,
    required this.onBack,
    this.initialPage = 0,
    this.actions = const <Widget>[],
    this.prevLabel = '上一话',
    this.nextLabel = '下一话',
    this.onPrev,
    this.onNext,
    this.showIndicator = true,
    this.direction = ReadDirection.horizontal,
    this.onPageChanged,
  });

  final List<ReaderPageImage> pages;

  /// 顶栏第一行：作品名
  final String title;

  /// 顶栏第二行：当前话 / 卷 / 章名
  final String subtitle;

  /// 保存到相册的文件名前缀
  final String albumTitle;

  final VoidCallback onBack;

  /// 右侧操作按钮
  final List<Widget> actions;

  final String prevLabel;
  final String nextLabel;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// 是否显示页码进度条
  final bool showIndicator;

  final ReadDirection direction;

  final int initialPage;

  /// 翻页回调
  final ValueChanged<int>? onPageChanged;

  @override
  State<PagedImageReader> createState() => _PagedImageReaderState();
}

class _PagedImageReaderState extends State<PagedImageReader> {
  late final PageController _pageController;
  late int _index;
  bool _chromeVisible = true;

  /// 当前页是否放大，放大时关掉翻页滚动
  bool _zoomed = false;

  /// 竖向滚动的累计 overscroll，松手时判是否翻页
  double _overscrollAccum = 0;

  int get _total => widget.pages.isEmpty ? 1 : widget.pages.length;

  @override
  void initState() {
    super.initState();
    _index = widget.initialPage.clamp(0, _total - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= _total || index == _index) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// 页内竖向滚动到头继续拖，松手时翻页
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is OverscrollNotification) {
      _overscrollAccum += notification.overscroll;
    } else if (notification is ScrollEndNotification) {
      final accum = _overscrollAccum;
      _overscrollAccum = 0;
      final scrollable = notification.metrics.maxScrollExtent > 0;
      if (!scrollable && widget.direction != ReadDirection.vertical) {
        return false;
      }
      if (accum > 60) {
        _goTo(_index + 1);
      } else if (accum < -60) {
        _goTo(_index - 1);
      }
    }
    return false;
  }

  void _handleTap(int page, TapUpDetails details) {
    // 放大时点击只收放工具栏，避免被当成拖过头翻页
    if (_zoomed) {
      setState(() => _chromeVisible = !_chromeVisible);
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (widget.direction == ReadDirection.vertical ||
        (x > width * 0.32 && x < width * 0.68)) {
      setState(() => _chromeVisible = !_chromeVisible);
    } else if (x <= width * 0.32) {
      _goTo(page - 1);
    } else {
      _goTo(page + 1);
    }
  }

  /// 长按第 [page] 页保存到相册，字节优先读本地文件
  Future<void> _savePage(int page) async {
    if (!mounted || page < 0 || page >= widget.pages.length) return;
    final image = widget.pages[page];
    if (image.isEmpty) return;
    await showSaveToAlbumSheet(
      context,
      albumTitle: widget.albumTitle,
      page: page + 1,
      readBytes: () async {
        final local = image.file;
        if (local != null) return local.readAsBytes();
        return ImageStore.instance.get(image.url);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 点击 / 长按挂在内层页面：挂外层会抢走 PageView 的拖动手势
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: PageView.builder(
              controller: _pageController,
              scrollDirection: widget.direction == ReadDirection.horizontal
                  ? Axis.horizontal
                  : Axis.vertical,
              // 放大 / 双指操作期间关掉翻页滚动：此时单指是平移，双指是缩放
              physics: (_zoomed || widget.direction == ReadDirection.vertical)
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _total,
              onPageChanged: (i) {
                setState(() {
                  _index = i;
                  _zoomed = false;
                  _overscrollAccum = 0;
                });
                widget.onPageChanged?.call(i);
              },
              itemBuilder: (context, i) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _handleTap(i, details),
                onLongPress: () => _savePage(i),
                child: _ZoomablePage(
                  active: i == _index,
                  onZoomChanged: (zoomed, _) {
                    if (i != _index) return;
                    if (zoomed == _zoomed) return;
                    setState(() => _zoomed = zoomed);
                  },
                  // 拖到（放大后的）图片边界还在推 → 翻页
                  onEdgeFlip: (delta) {
                    if (i != _index) return;
                    _goTo(i + delta);
                  },
                  child: _page(i),
                ),
              ),
            ),
          ),
        ),
        if (_chromeVisible) _topBar(context),
        if (_chromeVisible) _bottomBar(context),
      ],
    );
  }

  /// 单页内容：图片宽度等于屏幕宽度（`BoxFit.fitWidth`）
  Widget _page(int index) {
    if (index < 0 || index >= widget.pages.length) {
      return _placeholder(index < 0 ? 0 : index);
    }
    final page = widget.pages[index];
    final local = page.file;
    if (local != null) {
      return Image.file(
        local,
        fit: BoxFit.fitWidth,
        errorBuilder: (_, __, ___) => _placeholder(index),
      );
    }
    if (page.url.isNotEmpty) {
      return NetImage(
        url: page.url,
        fit: BoxFit.fitWidth,
        showProgress: true,
        errorBuilder: (_) => _placeholder(index),
      );
    }
    return _placeholder(index);
  }

  Widget _placeholder(int index) {
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Container(
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2A2A35), Color(0xFF15151C)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined, size: 40, color: Colors.white54),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context).pageLabel(index + 1),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 6,
          bottom: 14,
          left: 6,
          right: 6,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: widget.onBack,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            ...widget.actions,
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: 22,
          bottom: MediaQuery.paddingOf(context).bottom + 10,
          left: 12,
          right: 12,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showIndicator)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_index + 1) / _total,
                  minHeight: 3,
                  color: Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white24,
                  ),
                  onPressed: widget.onPrev == null
                      ? null
                      : () => widget.onPrev!.call(),
                  icon: const Icon(Icons.skip_previous_rounded, size: 18),
                  label: Text(widget.prevLabel),
                ),
                const Spacer(),
                Text(
                  widget.showIndicator
                      ? '${_index + 1} / $_total'
                      : widget.subtitle,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white24,
                  ),
                  onPressed: widget.onNext == null
                      ? null
                      : () => widget.onNext!.call(),
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: Text(widget.nextLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// _ZoomablePage — 单页容器：按宽度铺满的竖向可滚长图 + 双指缩放 + 拖到边界翻页
class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({
    required this.child,
    required this.active,
    required this.onZoomChanged,
    required this.onEdgeFlip,
  });

  final Widget child;
  final bool active;

  /// `zoomed`：是否处于放大状态（真时上层锁住翻页滚动）
  final void Function(bool zoomed, double scale) onZoomChanged;

  /// 贴边继续拖 → 翻页（`+1` 下一页 / `-1` 上一页）
  final ValueChanged<int> onEdgeFlip;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> {
  static const double _minScale = 1;
  static const double _maxScale = 4;

  /// 贴边后还要再推多少逻辑像素才算想翻页
  static const double _edgeFlipDistance = 56;

  final ScrollController _scroll = ScrollController();
  final Map<int, Offset> _pointers = {};

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;

  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  double _startSpan = 0;

  /// 本次手势里被边界夹掉的位移（正 = 往右下推，负 = 往左上推）
  Offset _edgeOverflow = Offset.zero;

  bool get _zoomed => _scale > _minScale + 0.001;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ZoomablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _reset();
  }

  void _reset() {
    _pointers.clear();
    _edgeOverflow = Offset.zero;
    if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
    final wasZoomed = _zoomed;
    if (_scale != 1 || _offset != Offset.zero) {
      setState(() {
        _scale = 1;
        _offset = Offset.zero;
      });
    }
    if (wasZoomed) widget.onZoomChanged(false, 1);
  }

  Offset get _centroid {
    if (_pointers.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final position in _pointers.values) {
      sum += position;
    }
    return sum / _pointers.length.toDouble();
  }

  double get _span {
    if (_pointers.length < 2) return 0;
    final points = _pointers.values.toList(growable: false);
    return (points[0] - points[1]).distance;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.active) return;
    if (_pointers.isEmpty) _edgeOverflow = Offset.zero;
    if (_pointers.length >= 2) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _startScale = _scale;
      _startOffset = _offset;
      _startFocal = _centroid;
      _startSpan = _span;
      // 两指一落下就把上层翻页关掉，否则第一下捏合会被 PageView 当成拖动
      widget.onZoomChanged(true, _scale);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length < 2) {
      // 1x 时单指上下拖动交给 `SingleChildScrollView`，这里不接管
      if (!_zoomed) return;
      _pan(event.delta);
      return;
    }
    if (_startSpan <= 0) {
      _startSpan = _span;
      return;
    }
    final scale = (_startScale * (_span / _startSpan))
        .clamp(_minScale, _maxScale)
        .toDouble();
    final pan = _centroid - _startFocal;
    setState(() {
      _scale = scale;
      _offset = _clamp(_startOffset + pan, scale);
    });
    widget.onZoomChanged(_zoomed, scale);
  }

  void _pan(Offset delta) {
    final raw = _offset + delta;
    final next = _clamp(raw, _scale);
    // 手指还在往外推、内容已经到边：这部分位移不生效，记下来判翻页
    _edgeOverflow += raw - next;
    setState(() => _offset = next);
  }

  Offset _clamp(Offset value, double scale) {
    final maxX = (scale - 1) * _viewport.width / 2;
    final maxY = (scale - 1) * _viewport.height / 2;
    return Offset(value.dx.clamp(-maxX, maxX), value.dy.clamp(-maxY, maxY));
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) return;
    _maybeFlip();
    if (!_zoomed && _offset != Offset.zero) {
      setState(() => _offset = Offset.zero);
    }
  }

  /// 贴边溢出足够远 → 翻页
  void _maybeFlip() {
    final overflow = _edgeOverflow;
    _edgeOverflow = Offset.zero;
    if (overflow.dy.abs() >= _edgeFlipDistance &&
        overflow.dy.abs() >= overflow.dx.abs()) {
      // 往上推（内容已到最底）→ 下一页
      _flip(overflow.dy < 0 ? 1 : -1);
    } else if (overflow.dx.abs() >= _edgeFlipDistance) {
      _flip(overflow.dx < 0 ? 1 : -1);
    }
  }

  void _flip(int delta) {
    if (_scale != 1) {
      setState(() {
        _scale = 1;
        _offset = Offset.zero;
      });
    }
    widget.onZoomChanged(false, 1);
    widget.onEdgeFlip(delta);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _viewport = size;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: ClipRect(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.translationValues(_offset.dx, _offset.dy, 0) *
                  Matrix4.diagonal3Values(_scale, _scale, 1),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: SingleChildScrollView(
                  controller: _scroll,
                  // 放大时关掉页内滚动：这时拖动是平移，两个一起响应会打架
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: size.height),
                    child: Center(
                      child: SizedBox(
                        width: size.width,
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// ReaderErrorView — 深色阅读器的错误态，不用 Material 主题色
class ReaderErrorView extends StatelessWidget {
  const ReaderErrorView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final info = describeRequestError(t, error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                size: 36, color: Colors.white70),
            const SizedBox(height: 12),
            Text(info.title,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 6),
            Text(info.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: Text(t.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// ReaderLoadingView — 深色阅读器的首屏加载：整屏一整块骨架色（原版就是一整屏占位）
class ReaderLoadingView extends StatelessWidget {
  const ReaderLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: skeletonColor(context),
      child: const ReaderSkeleton(),
    );
  }
}
