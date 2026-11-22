import 'package:flutter/foundation.dart';

/// 底部导航一级目的地（M3 NavigationBar，6 项，按用户指定的顺序）
const int kHomeTabIndex = 0;
const int kNovelTabIndex = 1;
const int kPhotoTabIndex = 2;
const int kAnimationTabIndex = 3;
const int kShelfTabIndex = 4;
const int kProfileTabIndex = 5;

/// 一级导航目的地数量
const int kShellTabCount = 6;

/// 全局唯一的当前 tab
final ValueNotifier<int> shellTabIndex = ValueNotifier<int>(kHomeTabIndex);
