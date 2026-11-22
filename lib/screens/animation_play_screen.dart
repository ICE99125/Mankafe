import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../models/content.dart';
import '../models/media_page.dart';
import '../services/api_client.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/request_error.dart';
import '../widgets/skeleton.dart';
import '../widgets/ui.dart';
import '../widgets/video_stage.dart';
import '../utils/frame_kick.dart';
import 'login_screen.dart';

/// 打开动画播放页
void openAnimationPlay(
  BuildContext context, {
  required String pathWord,
  required String chapterUuid,
  required String chapterName,
  List<AnimationLine> initialLines = const [],
  String name = '',
  String? cover,
}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AnimationPlayScreen(
      pathWord: pathWord,
      chapterUuid: chapterUuid,
      chapterName: chapterName,
      initialLines: initialLines,
      name: name,
      cover: cover,
    ),
  ));
}

/// AnimationPlayScreen — 动画播放页
class AnimationPlayScreen extends StatefulWidget {
  final String pathWord;
  final String chapterUuid;
  final String chapterName;
  final List<AnimationLine> initialLines;
  final String name;
  final String? cover;

  const AnimationPlayScreen({
    super.key,
    required this.pathWord,
    required this.chapterUuid,
    required this.chapterName,
    this.initialLines = const [],
    this.name = '',
    this.cover,
  });

  @override
  State<AnimationPlayScreen> createState() => _AnimationPlayScreenState();
}

class _AnimationPlayScreenState extends State<AnimationPlayScreen> {
  /// 空串表示不传 `line`，由服务端给默认线路
  String _line = '';

  bool _loading = true;
  Object? _error;
  AnimationPlay? _play;

  VideoPlayerController? _controller;
  String? _playerError;

  /// 全屏层是否在显示：画面与控件移到独立层里铺满整屏，页面内的播放器换成黑底占位
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_fullscreen) _restoreSystemChrome();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_fullscreen) await _exitFullscreen();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final play = await context
          .read<Repository>()
          .animationPlay(widget.pathWord, widget.chapterUuid, line: _line);
      if (!mounted) return;
      setState(() {
        _play = play;
        _loading = false;
      });
      // 记录看到第几集，供详情页续看
      unawaited(_record());
      kickFrame();
      await _bindVideo(play);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
      kickFrame();
    }
  }

  /// 写浏览记录：作品名/封面来自详情页，播放页自己不知道
  Future<void> _record() {
    return context.read<AppState>().recordRead(
          pathWord: widget.pathWord,
          chapterUuid: widget.chapterUuid,
          chapterName: widget.chapterName,
          page: 0,
          name: widget.name,
          cover: widget.cover,
          kind: MediaKind.animation,
        );
  }

  Future<void> _bindVideo(AnimationPlay play) async {
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
    if (!mounted) return;
    setState(() => _playerError = null);
    if (!play.hasVideo) return;

    final controller = VideoPlayerController.networkUrl(Uri.parse(play.video));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.play();
      setState(() => _controller = controller);
      kickFrame();
    } catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() => _playerError = '$error');
      kickFrame();
    }
  }

  Future<void> _switchLine(AnimationLine line) async {
    if (line.pathWord == _line) return;
    setState(() => _line = line.pathWord);
    await _load();
  }

  /// 进全屏：铺满 + 横屏 + 隐藏系统栏
  Future<void> _enterFullscreen() async {
    final controller = _controller;
    if (_fullscreen || controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() => _fullscreen = true);
    kickFrame();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
  }

  /// 退全屏：恢复竖屏与系统栏
  Future<void> _exitFullscreen() async {
    if (!_fullscreen) return;
    setState(() => _fullscreen = false);
    kickFrame();
    await _restoreSystemChrome();
  }

  Future<void> _restoreSystemChrome() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('播放地址已复制')));
  }

  Future<void> _openLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const LoginScreen()),
    );
    if (ok == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final title = _play?.chapterName.isNotEmpty == true
        ? _play!.chapterName
        : widget.chapterName;
    final controller = _controller;
    final showFullscreenLayer =
        _fullscreen && controller != null && controller.value.isInitialized;
    return PopScope(
      canPop: !showFullscreenLayer,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exitFullscreen();
      },
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: Text(title.isEmpty ? '播放' : title),
            ),
            body: _body(context),
          ),
          if (showFullscreenLayer)
            Positioned.fill(
              child: Material(
                color: Colors.black,
                child: SafeArea(
                  child: VideoStage(
                    controller: controller,
                    fullscreen: true,
                    title: title,
                    onClose: _exitFullscreen,
                    onToggleFullscreen: _exitFullscreen,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const _PlaySkeleton();
    }
    if (_error != null) {
      return _errorBody(context, _error!);
    }
    final play = _play!;
    final lines = play.lines.isNotEmpty ? play.lines : widget.initialLines;
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        _player(context, play, lines),
        if (lines.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('播放线路',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: lines.map((l) => _lineChip(play, l)).toList(),
                ),
              ],
            ),
          ),
        if (play.hasVideo)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: SurfaceCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.link_rounded, size: 17, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text('播放地址',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.w500)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => _copyUrl(play.video),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('复制'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    play.video,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 线路标签：服务端明确标注 `config: false` 的直接禁用（不可点、灰显）
  Widget _lineChip(AnimationPlay play, AnimationLine line) {
    final chip = ChoiceChip(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: Text(line.name),
      selected: _isCurrentLine(play, line),
      onSelected: line.usable ? (_) => _switchLine(line) : null,
    );
    if (line.usable) return chip;
    return Tooltip(
      message: '${line.name}：服务端未配置播放地址，暂不可用',
      child: chip,
    );
  }

  /// 哪条是当前线路：显式请求过就是那条
  bool _isCurrentLine(AnimationPlay play, AnimationLine line) {
    if (_line.isNotEmpty) return line.pathWord == _line;
    if (!play.hasVideo) return false;
    return play.activeLine?.pathWord == line.pathWord;
  }

  /// 当前线路没地址时，第一条服务端已配置、且不是当前线路的备选
  AnimationLine? _usableAlternative(
      AnimationPlay play, List<AnimationLine> lines) {
    final current = _line.isNotEmpty
        ? _line
        : (play.hasVideo ? (play.activeLine?.pathWord ?? '') : '');
    for (final line in lines) {
      if (!line.usable || line.pathWord.isEmpty) continue;
      if (line.pathWord == current) continue;
      return line;
    }
    return null;
  }

  Widget _player(
      BuildContext context, AnimationPlay play, List<AnimationLine> lines) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      final ratio = controller.value.aspectRatio > 0
          ? controller.value.aspectRatio
          : 16 / 9;
      // 全屏时画面已经移到全屏层，这里只留同尺寸黑底，避免重复挂载
      if (_fullscreen) {
        return AspectRatio(
          aspectRatio: ratio,
          child: const ColoredBox(color: Colors.black),
        );
      }
      return AspectRatio(
        aspectRatio: ratio,
        child: VideoStage(
          controller: controller,
          onToggleFullscreen: _enterFullscreen,
        ),
      );
    }
    final alternative = play.hasVideo ? null : _usableAlternative(play, lines);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _playerError != null
                      ? Icons.error_outline_rounded
                      : Icons.movie_filter_outlined,
                  size: 40,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 10),
                Text(
                  _playerError != null
                      ? '播放器无法解码该地址'
                      : (play.hasVideo
                          ? '播放器准备中…'
                          : (_line.isEmpty ? '默认线路未返回播放地址' : '该线路未返回播放地址')),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (alternative != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => _switchLine(alternative),
                    icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text('换到${alternative.name}'),
                  ),
                ],
                if (_playerError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _playerError!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBody(BuildContext context, Object error) {
    final t = AppLocalizations.of(context);
    if (error is AuthExpiredException) {
      return EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '需要登录才能播放',
        message:
            '播放接口 /api/v3/cartoon/{path_word}/chapter/{uuid} 在未登录时由服务端返回 401',
        action: FilledButton.icon(
          onPressed: _openLogin,
          icon: const Icon(Icons.login_rounded),
          label: const Text('去登录'),
        ),
      );
    }
    final info = describeRequestError(t, error);
    return EmptyState(
      icon: Icons.cloud_off_rounded,
      title: info.title,
      message: info.message,
      action: FilledButton.tonalIcon(
        onPressed: _load,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('重试'),
      ),
    );
  }
}

/// _PlaySkeleton — 播放页首屏骨架：16:9 播放器块 + 线路区 + 地址卡
class _PlaySkeleton extends StatelessWidget {
  const _PlaySkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 28),
        children: const [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: SkeletonBox(
              width: double.infinity,
              height: double.infinity,
              radius: BorderRadius.zero,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(
                  width: 58,
                  height: 14,
                  radius: BorderRadius.all(Radius.circular(4)),
                ),
                SizedBox(height: 10),
                // ChoiceChip 行（MD3 chip 高32，圆角8）
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SkeletonBox(
                      width: 64,
                      height: 32,
                      radius: BorderRadius.all(Radius.circular(8)),
                    ),
                    SkeletonBox(
                      width: 64,
                      height: 32,
                      radius: BorderRadius.all(Radius.circular(8)),
                    ),
                    SkeletonBox(
                      width: 64,
                      height: 32,
                      radius: BorderRadius.all(Radius.circular(8)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 地址卡：SurfaceCard(padding 14) + 标题行 + 地址两行
          Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: SkeletonBox(
              height: 112,
              radius: BorderRadius.all(Radius.circular(16)),
            ),
          ),
        ],
      ),
    );
  }
}
