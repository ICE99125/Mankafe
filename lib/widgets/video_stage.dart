import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// VideoStage — 播放器画面 + 自绘控制层（不引入 Chewie 等额外依赖）
class VideoStage extends StatefulWidget {
  final VideoPlayerController controller;

  /// 是否全屏层：顶部显示返回 + 集名，底部留更多安全间距
  final bool fullscreen;

  /// 全屏 / 退出全屏
  final VoidCallback? onToggleFullscreen;

  /// 全屏层的返回按钮
  final VoidCallback? onClose;

  /// 全屏层顶部标题（集名）
  final String? title;

  const VideoStage({
    super.key,
    required this.controller,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.onClose,
    this.title,
  });

  @override
  State<VideoStage> createState() => _VideoStageState();
}

class _VideoStageState extends State<VideoStage> {
  static const Duration _autoHideAfter = Duration(seconds: 3);
  static const Duration _skipStep = Duration(seconds: 10);
  static const Duration _nearEnd = Duration(milliseconds: 600);
  static const List<double> _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  static const SliderThemeData _progressTheme = SliderThemeData(
    trackHeight: 3,
    activeTrackColor: Colors.white,
    inactiveTrackColor: Color(0x4DFFFFFF),
    thumbColor: Colors.white,
    overlayColor: Color(0x33FFFFFF),
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    trackShape: RoundedRectSliderTrackShape(),
    showValueIndicator: ShowValueIndicator.never,
  );

  static const SliderThemeData _volumeTheme = SliderThemeData(
    trackHeight: 2.5,
    activeTrackColor: Colors.white70,
    inactiveTrackColor: Color(0x3DFFFFFF),
    thumbColor: Colors.white,
    overlayColor: Color(0x33FFFFFF),
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
    trackShape: RoundedRectSliderTrackShape(),
    showValueIndicator: ShowValueIndicator.never,
  );

  bool _visible = true;
  Timer? _hideTimer;

  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;

  bool _volumeOpen = false;
  Timer? _volumeTimer;
  double _lastVolume = 1;

  String? _hint;
  bool _hintForward = true;
  Timer? _hintTimer;

  double _doubleTapX = 0;

  VideoPlayerController get _video => widget.controller;

  @override
  void initState() {
    super.initState();
    final volume = _video.value.volume;
    if (volume > 0) _lastVolume = volume;
    _video.addListener(_onValueChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onValueChanged);
      widget.controller.addListener(_onValueChanged);
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    _video.removeListener(_onValueChanged);
    _hideTimer?.cancel();
    _volumeTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _onValueChanged() {
    final value = _video.value;
    if (value.volume > 0) _lastVolume = value.volume;
    if (!mounted) return;
    if (!value.isPlaying) {
      // 暂停时常显控件，别让用户找不到播放按钮
      _hideTimer?.cancel();
      _hideTimer = null;
      if (!_visible && !_scrubbing) setState(() => _visible = true);
    } else if (_hideTimer == null && _visible) {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_video.value.isPlaying || !_visible) return;
    _hideTimer = Timer(_autoHideAfter, () {
      _hideTimer = null;
      if (!mounted || _scrubbing) return;
      setState(() {
        _visible = false;
        _volumeOpen = false;
      });
    });
  }

  void _toggleVisible() {
    if (_visible) {
      _hideTimer?.cancel();
      _hideTimer = null;
      setState(() {
        _visible = false;
        _volumeOpen = false;
      });
    } else {
      setState(() => _visible = true);
      _scheduleHide();
    }
  }

  void _togglePlay() {
    final value = _video.value;
    if (!value.isInitialized) return;
    final atEnd = value.duration > Duration.zero &&
        value.position >= value.duration - _nearEnd;
    if (value.isPlaying) {
      _video.pause();
      _hideTimer?.cancel();
      _hideTimer = null;
    } else {
      if (atEnd) _video.seekTo(Duration.zero);
      _video.play();
    }
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _skip(Duration delta) {
    final value = _video.value;
    if (!value.isInitialized || value.duration <= Duration.zero) return;
    var target = value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > value.duration) target = value.duration;
    _video.seekTo(target);
    _flashHint(
      delta > Duration.zero
          ? '前进 ${delta.inSeconds} 秒'
          : '后退 ${-delta.inSeconds} 秒',
      forward: delta > Duration.zero,
    );
  }

  void _flashHint(String text, {required bool forward}) {
    _hintTimer?.cancel();
    setState(() {
      _hint = text;
      _hintForward = forward;
    });
    _hintTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  void _onDoubleTap() {
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 0;
    _skip(_doubleTapX >= width / 2 ? _skipStep : -_skipStep);
  }

  void _toggleVolumePanel() {
    setState(() => _volumeOpen = !_volumeOpen);
    _volumeTimer?.cancel();
    if (_volumeOpen) _startVolumeTimer();
    _scheduleHide();
  }

  void _startVolumeTimer() {
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _volumeOpen = false);
    });
  }

  void _setVolume(double value) {
    final v = value.clamp(0.0, 1.0);
    _video.setVolume(v);
    if (v > 0) _lastVolume = v;
    setState(() => _volumeOpen = true);
    _startVolumeTimer();
  }

  void _toggleMute() {
    final volume = _video.value.volume;
    if (volume > 0) {
      _lastVolume = volume;
      _video.setVolume(0);
    } else {
      _video.setVolume(_lastVolume > 0 ? _lastVolume : 1);
    }
    setState(() {});
  }

  void _onScrubStart(double value) {
    _hideTimer?.cancel();
    _hideTimer = null;
    setState(() {
      _scrubbing = true;
      _scrubTarget = Duration(milliseconds: value.round());
    });
  }

  void _onScrub(double value) {
    setState(() => _scrubTarget = Duration(milliseconds: value.round()));
  }

  void _onScrubEnd(double value) {
    _video.seekTo(Duration(milliseconds: value.round()));
    setState(() {
      _scrubbing = false;
      _scrubTarget = Duration(milliseconds: value.round());
    });
    _scheduleHide();
  }

  IconData _volumeIcon(double volume) {
    if (volume <= 0) return Icons.volume_off_rounded;
    if (volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  String _fmt(Duration d) {
    final total = d.inMilliseconds ~/ 1000;
    if (total <= 0) return '00:00';
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final tail = '${m.toString().padLeft(2, '0')}'
        ':${s.toString().padLeft(2, '0')}';
    return h > 0 ? '$h:$tail' : tail;
  }

  String _speedLabel(double speed) => '${speed}x';

  Widget _iconButton(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    double size = 22,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: size, color: Colors.white),
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _video,
      builder: (context, value, _) {
        final ratio = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
        final duration = value.duration;
        final maxMs = duration.inMilliseconds > 0
            ? duration.inMilliseconds.toDouble()
            : 1.0;
        final shownPosition = _scrubbing ? _scrubTarget : value.position;
        final positionMs =
            shownPosition.inMilliseconds.toDouble().clamp(0.0, maxMs);
        final playable = duration > Duration.zero;
        final ended = playable &&
            value.position >= duration - _nearEnd &&
            !value.isPlaying;
        final volume = value.volume.clamp(0.0, 1.0);

        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            Center(
              child: AspectRatio(
                aspectRatio: ratio,
                child: VideoPlayer(_video),
              ),
            ),
            // 空白处单击切换控件、双击左右两侧快进/快退
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleVisible,
                onDoubleTapDown: (d) => _doubleTapX = d.localPosition.dx,
                onDoubleTap: _onDoubleTap,
              ),
            ),
            if (value.isBuffering)
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white70,
                  ),
                ),
              ),
            if (!value.isPlaying)
              Center(
                child: GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      ended ? Icons.replay_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              ),
            if (_hint != null)
              Align(
                alignment:
                    _hintForward ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Text(
                      _hint!,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            if (widget.fullscreen && widget.title != null)
              Align(
                alignment: Alignment.topCenter,
                child: IgnorePointer(
                  ignoring: !_visible,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: _visible ? 1 : 0,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.55),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(4, 4, 12, 20),
                      child: Row(
                        children: [
                          _iconButton(
                            Icons.arrow_back_rounded,
                            '退出全屏',
                            widget.onClose ??
                                widget.onToggleFullscreen ??
                                () {},
                          ),
                          Expanded(
                            child: Text(
                              widget.title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: IgnorePointer(
                ignoring: !_visible,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _visible ? 1 : 0,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.86),
                        ],
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      10,
                      24,
                      10,
                      widget.fullscreen ? 8 : 2,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_volumeOpen)
                          Align(
                            alignment: Alignment.centerRight,
                            child: _volumeBar(volume),
                          ),
                        Row(
                          children: [
                            SizedBox(
                              width: 50,
                              child: Text(
                                _fmt(shownPosition),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: _progressTheme,
                                child: Slider(
                                  min: 0,
                                  max: maxMs,
                                  value: positionMs,
                                  onChangeStart: _onScrubStart,
                                  onChanged: _onScrub,
                                  onChangeEnd: _onScrubEnd,
                                  semanticFormatterCallback: (v) =>
                                      _fmt(Duration(milliseconds: v.round())),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 50,
                              child: Text(
                                _fmt(duration),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            _iconButton(Icons.replay_10_rounded, '后退 10 秒',
                                () => _skip(-_skipStep)),
                            _iconButton(
                              value.isPlaying
                                  ? Icons.pause_rounded
                                  : (ended
                                      ? Icons.replay_rounded
                                      : Icons.play_arrow_rounded),
                              value.isPlaying ? '暂停' : '播放',
                              _togglePlay,
                              size: 30,
                            ),
                            _iconButton(Icons.forward_10_rounded, '前进 10 秒',
                                () => _skip(_skipStep)),
                            const Spacer(),
                            _speedButton(value.playbackSpeed),
                            _iconButton(
                              _volumeIcon(volume),
                              _volumeOpen ? '收起音量' : '音量',
                              _toggleVolumePanel,
                            ),
                            if (widget.onToggleFullscreen != null)
                              _iconButton(
                                widget.fullscreen
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                                widget.fullscreen ? '退出全屏' : '全屏',
                                widget.onToggleFullscreen!,
                                size: 23,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _volumeBar(double volume) {
    return Container(
      margin: const EdgeInsets.only(right: 2, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _toggleMute,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(_volumeIcon(volume), size: 17, color: Colors.white70),
            ),
          ),
          SizedBox(
            width: 130,
            child: SliderTheme(
              data: _volumeTheme,
              child: Slider(
                min: 0,
                max: 1,
                value: volume,
                onChanged: _setVolume,
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${(volume * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _speedButton(double speed) {
    return PopupMenuButton<double>(
      tooltip: '播放速度',
      initialValue: speed,
      color: const Color(0xFF1F1F1F),
      position: PopupMenuPosition.over,
      onSelected: (value) {
        _video.setPlaybackSpeed(value);
        setState(() {});
      },
      itemBuilder: (context) => _speeds
          .map(
            (s) => PopupMenuItem<double>(
              value: s,
              height: 40,
              child: Row(
                children: [
                  if (s == speed)
                    const Icon(Icons.check_rounded,
                        size: 16, color: Colors.white)
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Text(
                    _speedLabel(s),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Text(
          _speedLabel(speed),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
