import 'package:flutter/widgets.dart';

/// NoTransitionPageRoute — 无转场路由，push 当帧即到最终位置
class NoTransitionPageRoute<T> extends PageRouteBuilder<T> {
  NoTransitionPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog,
    super.opaque,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.maintainState,
  }) : super(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        );
}
