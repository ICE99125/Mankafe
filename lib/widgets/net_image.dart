import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/image_store.dart';
import '../utils/frame_kick.dart';
import 'skeleton.dart';

export '../services/net_image_headers.dart' show imageHeaders;

/// NetImage — 网络图片，加载中骨架、失败重试一次、最终淡色占位
class NetImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final Alignment alignment;

  /// 布局尺寸（逻辑像素）。为 null 时由父级约束决定
  final double? width;
  final double? height;

  /// 显示宽度（逻辑像素），用于换算解码尺寸；不传时退回 [width]
  final double? decodeWidth;

  /// 圆角：内部自己裁剪，调用方不需要再套 ClipRRect
  final BorderRadius? radius;

  /// 最终失败时的自定义占位（例如首字渐变卡）。不传则用淡色图标占位
  final Widget Function(BuildContext context)? errorBuilder;

  /// 是否在底部显示细进度条（阅读器整页图用，封面不需要）
  final bool showProgress;

  const NetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.decodeWidth,
    this.radius,
    this.errorBuilder,
    this.showProgress = false,
  });

  @override
  State<NetImage> createState() => _NetImageState();
}

/// 已解码的图 + 物理像素 / 逻辑像素的换算比例
class _Decoded {
  final ui.Image image;
  final double scale;
  const _Decoded(this.image, this.scale);
}

class _NetImageState extends State<NetImage> {
  /// 0 = 首次加载；1 = 已自动重试过一次
  int _attempt = 0;
  bool _failed = false;
  Timer? _retryTimer;

  /// 当前这张图的加载 future。换 URL 或重试时替换
  Future<_Decoded>? _future;

  /// 最近一次 build 算出的解码参数，重试时复用
  double? _logicalWidth;
  int? _targetWidth;

  /// 下载进度0..1，长度未知时为 null
  double? _progress;

  /// 本 State 持有的解码图，dispose / 换 URL 时统一释放
  final Set<ui.Image> _owned = {};
  bool _disposed = false;

  @override
  void didUpdateWidget(NetImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryTimer?.cancel();
      _attempt = 0;
      _failed = false;
      _progress = null;
      _future = null;
      // 旧图可能还挂在上一帧的 RawImage 上，等这一帧画完再 dispose
      _releaseOwned();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _releaseOwned();
    super.dispose();
  }

  /// 延后到本帧 paint 之后再释放，避免把仍被渲染树引用的 ui.Image 干掉
  void _releaseOwned() {
    if (_owned.isEmpty) return;
    final stale = _owned.toList();
    _owned.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in stale) {
        image.dispose();
      }
    });
  }

  /// 失败后延迟重试一次，避免在构建期间改状态
  void _scheduleRetry() {
    if (_attempt >= 1 || _retryTimer != null) return;
    _retryTimer = Timer(const Duration(milliseconds: 600), () {
      _retryTimer = null;
      if (!mounted) return;
      setState(() {
        _attempt++;
        _failed = false;
        _progress = null;
        _future = _retryLoad();
      });
    });
  }

  /// 先清缓存再重新加载，避免读回同一份坏字节
  Future<_Decoded> _retryLoad() async {
    await ImageStore.instance.evict(widget.url);
    return _load();
  }

  /// 读缓存 / 下载 → 解码，返回可直接 paint 的图
  Future<_Decoded> _load() async {
    final bytes = await ImageStore.instance.get(
      widget.url,
      onProgress: (received, total) {
        if (!mounted || !widget.showProgress) return;
        if (total <= 0) return;
        final value = (received / total).clamp(0.0, 1.0);
        // 只在跨过5% 时重建，避免每收一个 chunk 都 setState
        final last = _progress;
        if (last != null && (value - last).abs() < 0.05 && value < 1) return;
        if (!mounted) return;
        setState(() => _progress = value);
      },
    );

    final decoded = await _decode(bytes);
    if (_disposed) {
      // 页面已经退出才解码完：没进过渲染树，直接释放
      decoded.image.dispose();
    } else {
      _owned.add(decoded.image);
    }

    // 虚拟屏 vsync 可能不来，补一帧保证图到了会被 paint
    kickFrame();
    return decoded;
  }

  Future<_Decoded> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _targetWidth,
      // 只给宽度，SDK 会自动等比算高度；不放大，省内存也不糊
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final logical = _logicalWidth;
      final scale = (logical != null && logical > 0 && image.width > 0)
          ? image.width / logical
          : 1.0;
      return _Decoded(image, scale);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[net-image] 解码失败 ${widget.url}: $error');
      }
      rethrow;
    } finally {
      codec.dispose();
    }
  }

  /// 期望的逻辑显示宽度：优先显式尺寸，整页图退回屏幕宽度
  double? _computeLogicalWidth(BuildContext context) =>
      widget.decodeWidth ??
      widget.width ??
      MediaQuery.maybeSizeOf(context)?.width;

  @override
  Widget build(BuildContext context) {
    final child = _image(context);
    final radius = widget.radius;
    if (radius == null) return child;
    return ClipRRect(borderRadius: radius, child: child);
  }

  Widget _image(BuildContext context) {
    if (widget.url.isEmpty || _failed) return _fallback(context);

    final logical = _computeLogicalWidth(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    int? target;
    if (logical != null && logical > 0) {
      final px = (logical * dpr).round();
      target = px < 1 ? 1 : (px > 8192 ? 8192 : px);
    }
    _logicalWidth = logical;
    _targetWidth = target;

    final future = _future ??= _load();
    return FutureBuilder<_Decoded>(
      future: future,
      builder: (context, snapshot) {
        // 数据到达后收起进度条
        final loading = !snapshot.hasData && !snapshot.hasError;

        final Widget content;
        if (snapshot.hasError) {
          _scheduleRetry();
          // 还有重试机会时保持骨架（视觉上仍在加载），重试用尽才显示失败占位
          content = _attempt >= 1 ? _fallback(context) : const _ImageSkeleton();
        } else {
          final decoded = snapshot.data;
          // 只画本 State 仍持有的图：旧图已 dispose，传给 RawImage 会抛
          // Cannot clone a disposed image
          if (decoded == null || !_owned.contains(decoded.image)) {
            content = const _ImageSkeleton();
          } else {
            content = RawImage(
              image: decoded.image,
              scale: decoded.scale,
              fit: widget.fit,
              alignment: widget.alignment,
              width: widget.width,
              height: widget.height,
              isAntiAlias: true,
              filterQuality: FilterQuality.medium,
            );
          }
        }
        // 占位要和真实图一样受 width/height 约束，否则无界约束下会抛无限尺寸错误
        return _withProgress(context, _sized(content), visible: loading);
      },
    );
  }

  /// 已知显示尺寸时给占位套上同样的框，避免它在无界约束下撑成无限大
  Widget _sized(Widget child) {
    if (widget.width == null && widget.height == null) return child;
    return SizedBox(width: widget.width, height: widget.height, child: child);
  }

  Widget _withProgress(
    BuildContext context,
    Widget child, {
    required bool visible,
  }) {
    if (!widget.showProgress || !visible || _progress == null) return child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: scheme.primary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _fallback(BuildContext context) {
    final custom = widget.errorBuilder;
    final Widget child =
        custom != null ? custom(context) : _defaultFallback(context);
    if (widget.width == null && widget.height == null) return child;
    return SizedBox(width: widget.width, height: widget.height, child: child);
  }

  Widget _defaultFallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 22,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// 图片骨架：一块铺满的静态色块，不套 Shimmer
class _ImageSkeleton extends StatelessWidget {
  const _ImageSkeleton();

  @override
  Widget build(BuildContext context) {
    // 不能写 width: double.infinity：无界约束下会抛无限尺寸错误，打断整行布局
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
        final height =
            constraints.hasBoundedHeight ? constraints.maxHeight : 0.0;
        if (width <= 0 || height <= 0) return const SizedBox.shrink();
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: skeletonColor(context),
            borderRadius: BorderRadius.zero,
          ),
        );
      },
    );
  }
}
