import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/media_page.dart';
import '../services/repository.dart';
import '../services/route_manager.dart';
import '../state/shell_tab.dart';
import '../utils/app_route.dart';
import '../widgets/brand_header.dart';
import 'animation_play_screen.dart';
import 'catalog_screen.dart';
import 'comic_detail_screen.dart';
import 'comments_screen.dart';
import 'content_detail_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';
import 'reader_screen.dart';
import 'topic_detail_screen.dart';

/// AppShell — 主壳：M3 [NavigationBar] 6 个目的地 + IndexedStack
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = shellTabIndex.value;

  /// 已经访问过的一级页面（懒构建 IndexedStack）
  final Set<int> _visited = <int>{};

  /// 当前一级页面是否已离开顶部：顶栏据此在主题色与毛玻璃之间切换
  final ValueNotifier<bool> _scrolled = ValueNotifier<bool>(false);

  void _onTabIndexChanged() {
    if (!mounted || shellTabIndex.value == _index) return;
    setState(() {
      _index = shellTabIndex.value;
      _visited.add(_index);
    });
    _scrolled.value = false;
  }

  @override
  void initState() {
    super.initState();
    // 截图 / 验证用：`--dart-define=DEBUG_TAB=3` 直接落在指定一级页面
    if (kDebugMode) {
      const debugTab = int.fromEnvironment('DEBUG_TAB', defaultValue: -1);
      if (debugTab >= 0 && debugTab < kShellTabCount) {
        _index = debugTab;
        shellTabIndex.value = debugTab;
      }
    }
    _visited.add(_index);
    shellTabIndex.addListener(_onTabIndexChanged);
    _maybeOpenDebugRoute();
  }

  /// 调试直达：--dart-define=DEBUG_OPEN=comic:<path_word>
  void _maybeOpenDebugRoute() {
    if (!kDebugMode) return;
    const spec = String.fromEnvironment('DEBUG_OPEN');
    if (spec.isEmpty) return;
    final parts = spec.split(':');
    if (parts.length < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final arg = parts.sublist(1).join(':');
      switch (parts.first) {
        case 'comic':
          openComicDetail(context, arg);
        case 'cartoon':
          openContentDetail(context, MediaKind.animation, arg);
        case 'post':
          openContentDetail(context, MediaKind.photo, arg);
        case 'cartoonplay':
          // `cartoonplay:<path_word>:<chapter_uuid>`：直达播放页
          final seg = arg.split(':');
          if (seg.length < 2) return;
          openAnimationPlay(
            context,
            pathWord: seg[0],
            chapterUuid: seg[1],
            chapterName: '第01集',
          );
        case 'reader':
          // 章节 uuid 由目录接口取，避免验证时手抄 uuid
          final chapters = await context.read<Repository>().chapters(arg);
          if (!mounted || chapters.isEmpty) return;
          openReader(context, pathWord: arg, chapterUuid: chapters.first.uuid);
        case 'comments':
          // 直达漫画评论页，用来验证分页 / 懒加载（点进去要滚半屏，不好复现）
          if (!mounted) return;
          Navigator.of(context).push(NoTransitionPageRoute<void>(
            builder: (_) => ComicCommentsScreen(pathWord: arg),
          ));
        case 'topic':
          // 直达专题详情页：首页专题条在首屏中部，模拟器上盲点坐标不稳，验证页头说明 / 分页时用这个钩子
          TopicDetailScreen.open(context, pathWord: arg, title: '');
      }
    });
  }

  Widget _pageFor(int index, String name, Widget Function() build) {
    if (!_visited.contains(index)) return const SizedBox.shrink();
    return KeyedSubtree(key: ValueKey('slot-$name'), child: build());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final linkId =
        context.select<RouteManager, String>((routes) => routes.activeLink.id);
    // 网络代际：启动自检 / 自愈完成后 +1，页面因此重建并重新请求
    final revision =
        context.select<RouteManager, int>((routes) => routes.revision);
    // 懒构建 IndexedStack：只有访问过的一级页面才真正挂载
    final pages = <Widget>[
      _pageFor(
          0, 'home', () => HomeScreen(key: ValueKey('home-$linkId-$revision'))),
      _pageFor(
          1,
          'novel',
          () => CatalogScreen(
              key: ValueKey('novel-$linkId-$revision'),
              kind: CatalogKind.novel)),
      _pageFor(
          2,
          'photo',
          () => CatalogScreen(
              key: ValueKey('photo-$linkId-$revision'),
              kind: CatalogKind.photo)),
      _pageFor(
          3,
          'animation',
          () => CatalogScreen(
              key: ValueKey('animation-$linkId-$revision'),
              kind: CatalogKind.animation)),
      _pageFor(4, 'library',
          () => LibraryScreen(key: ValueKey('library-$linkId-$revision'))),
      _pageFor(5, 'profile',
          () => ProfileScreen(key: ValueKey('profile-$linkId-$revision'))),
    ];
    return Scaffold(
      body: BrandBarScrollScope(
        scrolled: _scrolled,
        child: NotificationListener<ScrollMetricsNotification>(
          // 切到另一个列表（例如频道内的顶部页签）时不一定有 ScrollNotification
          onNotification: (notification) {
            if (notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical) {
              final value = notification.metrics.pixels > 4;
              if (_scrolled.value != value) _scrolled.value = value;
            }
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            // 一级页面共用一层监听：任意列表离开顶部就把顶栏切成毛玻璃
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  notification.metrics.axis == Axis.vertical) {
                final value = notification.metrics.pixels > 4;
                if (_scrolled.value != value) _scrolled.value = value;
              }
              return false;
            },
            child: IndexedStack(index: _index, children: pages),
          ),
        ),
      ),
      // 底栏比页面 surface 深一档
      bottomNavigationBar: Container(
        padding: const EdgeInsets.only(top: 0.5),
        color: Theme.of(context).colorScheme.outlineVariant,
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() {
              _index = i;
              _visited.add(i);
            });
            // 新页面从顶部开始，顶栏先恢复主题色，等它滚动后再切毛玻璃
            _scrolled.value = false;
            shellTabIndex.value = i;
          },
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home),
              label: t.navHome,
            ),
            NavigationDestination(
              icon: const Icon(Icons.menu_book_outlined),
              selectedIcon: const Icon(Icons.menu_book),
              label: t.navNovel,
            ),
            NavigationDestination(
              icon: const Icon(Icons.photo_library_outlined),
              selectedIcon: const Icon(Icons.photo_library),
              label: t.navPhoto,
            ),
            NavigationDestination(
              icon: const Icon(Icons.smart_display_outlined),
              selectedIcon: const Icon(Icons.smart_display),
              label: t.navAnimation,
            ),
            NavigationDestination(
              icon: const Icon(Icons.bookmarks_outlined),
              selectedIcon: const Icon(Icons.bookmarks),
              label: t.navLibrary,
            ),
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              selectedIcon: const Icon(Icons.person),
              label: t.navProfile,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    shellTabIndex.removeListener(_onTabIndexChanged);
    _scrolled.dispose();
    super.dispose();
  }
}
