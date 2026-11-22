import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 强制出一帧，走 Timer 驱动的 warm-up 路径，不依赖引擎 vsync
DateTime? _lastWarmUpKickAt;

void kickFrame() {
  final binding = SchedulerBinding.instance;

  // 真机 / 正常虚拟屏：直接请求一帧，vsync 可用时下一帧就到
  binding.scheduleFrame();

  final now = DateTime.now();
  final last = _lastWarmUpKickAt;
  if (last != null && now.difference(last) < const Duration(milliseconds: 64)) {
    return;
  }
  _lastWarmUpKickAt = now;

  // MuMu 等虚拟屏：引擎 vsync 不送达，scheduleFrame 会一直挂着不产出帧
  Timer(const Duration(seconds: 0), () {
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      binding.scheduleWarmUpFrame();
    }
  });
}

/// 让 [future] 完成后（无论成功还是失败）都强制出一帧，并返回原 future 本身
Future<T> kickOnDone<T>(Future<T> future) =>
    future..then((_) => kickFrame(), onError: (_) {});

/// ForceFrameObserver — 路由观察者：每次 push / replace / pop 之后强制出一帧
class ForceFrameObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    kickFrame();
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    kickFrame();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // 刻意不在这里补帧：pop 时下面那一页本来就一直在屏上，不需要补首帧
    super.didPop(route, previousRoute);
  }
}

/// FrameHeartbeat — 全局保底帧心跳，停摆后约50ms 补一帧
class FrameHeartbeat {
  FrameHeartbeat._();

  static Timer? _timer;
  static DateTime _lastFrameAt = DateTime.now();
  static DateTime _lastForceAt = DateTime.now();
  static bool _running = false;

  /// 心跳周期
  static const Duration _tick = Duration(milliseconds: 32);

  /// 引擎停帧的判定门槛
  static const Duration _stallThreshold = Duration(milliseconds: 50);

  static void start() {
    if (_running) return;
    _running = true;
    final binding = SchedulerBinding.instance;
    binding.addPersistentFrameCallback((_) => _lastFrameAt = DateTime.now());
    _timer = Timer.periodic(_tick, (_) {
      if (binding.schedulerPhase != SchedulerPhase.idle) return;
      final since = DateTime.now().difference(_lastFrameAt);
      // 帧在流动，无需干预
      if (since < _stallThreshold) return;
      // 引擎停摆：直接驱动一次 begin/draw
      _forceFrame(binding);
    });
  }

  /// 手动跑一次 begin/draw，把当前控件树 paint 出来
  static void _forceFrame(SchedulerBinding binding) {
    // 只在完全 idle 时驱动：路由 push/pop 的过渡期里正在拆除 element 树
    if (!binding.framesEnabled ||
        binding.schedulerPhase != SchedulerPhase.idle) {
      return;
    }
    final now = DateTime.now();
    final elapsed = now.difference(_lastForceAt);
    _lastForceAt = now;
    // 关键：喂给帧管线的时间戳必须是单调递增的真实时间
    final dt = elapsed > const Duration(milliseconds: 200)
        ? const Duration(milliseconds: 200)
        : elapsed;
    final timestamp = binding.currentFrameTimeStamp + dt;
    try {
      // ignore: invalid_use_of_protected_member
      binding.handleBeginFrame(timestamp);
      // ignore: invalid_use_of_protected_member
      binding.handleDrawFrame();
    } catch (error) {
      debugPrint('[beat] forceFrame failed: $error');
    }
    // 重新挂一次 vsync 请求，让引擎在恢复正常后继续按帧出图
    try {
      binding.scheduleFrame();
    } catch (_) {
      // 忽略：此时 vsync 仍不可用，下一轮心跳会再次尝试
    }
  }

  /// 停止保底出帧（供测试或应用退出使用）
  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
