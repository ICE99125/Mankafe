# 漫咖 · Material 3 设计规范

唯一标准：<https://m3.material.io/>。本文件描述 `lib/theme`、`lib/widgets`
里已经落地的 token 与组件用法；新增页面前先读这里，不要另造一套视觉语言。

## 1. 设计原则

- 官方组件优先：`AppBar` / `NavigationBar` / `TabBar` / `SearchBar` / `Card` /
  `ListTile` / `FilledButton` / `FilterChip` / `AlertDialog` / `ModalBottomSheet` /
  `SnackBar`，不手绘相似控件。
- 内容优先：页面主体是封面网格 / 列表，容器只做分组，不叠 Card、不做装饰性
  圆形与大面积渐变。
- 形状克制：常规容器 12dp；按钮 20dp；底部 sheet 顶部 28dp；不再全站胶囊。
- 层级用 Surface + tonal elevation 表达，不靠阴影。
- 全站同一套字阶与字重：标题最高 `w500`，正文 `w400`。
- Edge-to-edge：状态栏 / 导航栏透明，`SafeArea` + `MediaQuery.paddingOf`
  处理 Insets。

## 2. Token（`lib/theme/app_theme.dart`）

### 形状 `AppShape`

| token | 值 | 用途 |
| --- | --- | --- |
| `xs` | 4 | 小徽标、细条 |
| `sm` | 8 | 小容器、小徽标 |
| `md` | 12 | Card、封面、列表分组 |
| `lg` | 16 | 大容器 |
| `button` | 20 | Filled / Outlined / Text 按钮 |
| `xl` | 28 | Dialog |
| `sheetTopRadius` | 28 | ModalBottomSheet 顶部 |
| `searchBarRadius` | 24 | 紧凑 SearchBar（48dp 高） |

### 间距 `AppSpacing`

`xs=4`、`sm=8`、`md=12`、`base=16`、`lg=24`、`xl=32`、`page=16`、`pageV=16`。
页面左右统一 16dp；分组之间 16dp；组内 8/12dp。

### 动效 `AppMotion`

- `emphasizedDecelerate` / `emphasizedAccelerate` / `standard`
- 时长：`fast=100ms`、`short=150ms`、`medium=200ms`、`long=250ms`、
  `slow=400ms`、`slower=500ms`

### 颜色

`AppTheme.fromScheme(ColorScheme)` 生成完整 `ThemeData`；预设 6 个种子：

| 名称 | 种子 |
| --- | --- |
| 晴空蓝 | `#0061A4` |
| 鸢尾紫 | `#6750A4` |
| 湖青 | `#00696D` |
| 珊瑚 | `#984061` |
| 靛蓝 | `#4355B9` |
| 秋栗 | `#8B5000` |

浅色 `surface` 为 `#F8F9FF`（截图脚本据此识别应用屏）。
`AppTheme.fromScheme` 已为动态取色留好入口：接入 `dynamic_color` 后，把
`ColorScheme.fromSeed` 换成 `DynamicColorBuilder` 给出的 scheme 即可。

### 组件主题

- `AppBar`：64dp、`surface`、`onSurface`、`scrolledUnderElevation: 3`
- 顶栏滚动毛玻璃：一级页面滚离顶部后，`BrandBar` 切成
  `surfaceContainerLowest` 62% + `BackdropFilter` 26σ 模糊 + 0.5dp 发丝线；
  回到顶部恢复不透明 `surface`（由 `BrandBarScrollScope` 统一驱动）。要让
  模糊真正可见，页面滚动视图必须**从屏幕顶部开始**：顶栏用 `Stack` 叠在
  内容上方，滚动列表首屏用 `topPad` 垫出「顶栏 + 固定筛选区」的高度，
  滚动后内容才会走到顶栏背后。精选四个分段、动画、写真首页 / 全新上架
  按此结构。
- 小说页 / 书架页：标题、搜索、题材胶囊、排序、书架 chips / 四类页签 /
  续读条整块固定，并且是**一整块**毛玻璃——外层只用 `BrandGlassPanel`
  铺一次 `BackdropFilter`，内层 `BrandBar` 传 `glass: false` / `glassBorder:
  false`，中间不再出现第二条分隔线；只在整块最底部画 0.5dp 发丝线。
  固定区高度首帧实测（`GlobalKey`），列表 `topPad` = 顶栏高 + 实测固定区高；
  网格滚动时从固定区底下穿过再进入毛玻璃。书架顶部只保留「已收藏 /
  有更新」筛选（横向 `ListView` 起排，左对齐），不再放浏览记录与我的下载入口。
  续读条按当前页签取该类最近一条历史（漫画 / 小说 / 写真 / 动画各记各的），
  切页签就换成对应内容的上次停驻。
- **写真「发现 / 排行榜」**：标签胶囊 + 排序行、周榜 / 月榜 / 总榜单页签都固定，
  和标题、搜索框、四分段拼成一整块毛玻璃；列表首屏垫「顶栏 + 实测筛选高」，
  滚动内容从整块底下穿过。首页 / 全新上架没有额外筛选，只有顶栏一层玻璃。
- `NavigationBar`：80dp、`surfaceContainerHigh` 底（比页面 `surface` 深一档），
  顶部 0.5dp `outlineVariant` 发丝线；`secondaryContainer` 胶囊指示器
- `TabBar`：3dp `primary` 下划线，`tabAlignment: start`
- 按钮：最小 48dp 热区；`FilledButton` 20dp
- `Card`：`surfaceContainerLowest`（纯白，压在 `surface` 页面上形成明暗层）、
  12dp、elevation 0
- `ListTile`：标题 `bodyLarge`，`minVerticalPadding: 4`
- 输入框：`Filled`、4dp
- `Dialog` 28dp / `BottomSheet` 顶部 28dp + 拖拽条
- `SnackBar`：floating + `inverseSurface`

## 3. 共享组件

### `widgets/brand_header.dart`

- `BrandBar`：官方 `AppBar(primary: false)` + 手动状态栏 padding + 固定高度
  `SizedBox`，可直接放在 `Column` 里（避免无界高度崩溃）。
  被 push 的页面自动出现返回键（未显式传 `leading` 时，按**本页所在 route
  是不是 navigator 的第一条**判断：不是第一条才补 `BrandBackButton`）。
  不要改回 `Navigator.canPop()`：它问的是「此刻整个栈上面还有没有一层」，
  一级页面在自己被详情页盖住 / 详情页正在 pop 的窗口里重建时，栈里仍有上面
  那条 route，返回箭头会被烘进顶栏，转场结束后没人再重建顶栏，那枚多余
  返回键就一直挂着，点一下才消失（`test/widgets/brand_back_button_test.dart` 守着）。
- `BrandSearchField`：官方 `SearchBar`，紧凑形态 **48dp 高 / 24dp 圆角**、
  `surfaceContainerHigh`、左右 12dp 内边距；比默认 56dp 省出首屏一行。
- `BrandTabBar`：官方 `TabBar` / `TabBar.secondary`，3dp 指示条。
- `BrandTitle`：`titleLarge` 加粗标题，版本号做成压在名称**右下角**的主题色
  小胶囊（`labelSmall` + `onPrimary`），不额外占一行高度。
- `BrandBackButton` / `BrandIconButton`：48dp 热区。

### `widgets/ui.dart`

- `SurfaceCard` → 官方 `Card`（12dp、无阴影，保留 `radius` 兼容旧调用）
- `SectionHeader` → `titleMedium` + 16dp 外部间距
- `EmptyState` / `LinkStatusBanner`：低对比、无装饰容器

### `widgets/browse_widgets.dart`

- `CoverCarousel`：152dp 高、12dp 圆角、短 scrim、4dp 指示点，无左右箭头
- 卡片常量：`kCardCoverAspectRatio=3/4`、`kCardRadius=12`、
  `kCardCoverTitleGap=7`、`kCardTitleHeight=36` 等，骨架复用同一组常量

## 4. 一级导航

官方 `NavigationBar`，6 个目的地（顺序固定）：

**精选 / 小说 / 写真 / 动画 / 书架 / 个人**

- 懒构建 `IndexedStack`：只有访问过的页面才真正挂载，避免六页同时 build
  带来的离屏 `ScrollPosition` 与首屏请求。
- 标签文案来自 `AppLocalizations.navNovel = 小说`、`navPhoto = 写真` 等，
  与书架内部页签（漫画 / 小说 / 写真 / 动画）保持一致。

## 5. 骨架屏系统（`lib/widgets/skeleton.dart`）

### 原则

- 布局与真实页面共享尺寸常量，图片占位保持真实宽高比（封面 3:4）。
- 只表达结构：封面块 + 一两条标题线，不模拟图标、角标、辅助文字。
- 颜色取主题：`base = surfaceContainerHighest`，高光为 `onSurface` 5–10%
  叠加，不出现纯黑/纯白/高饱和。
- 单一 `SkeletonShimmer`：1400ms 横向扫光，`srcATop`，柔和；系统
  `disableAnimations` 时停在 0.5。
- 文字占位用 `SkeletonText`，行高与真实文字一致。

### 基础组件

`SkeletonShimmer`（兼容别名 `Shimmer`）、`SkeletonBox`、`SkeletonText`、
`SkeletonCircle`、`SkeletonImage`、`SkeletonGate`（最短展示 350ms +
200ms `AnimatedSwitcher`）。

`SkeletonBox.radius` 接受 `double` 或 `BorderRadius`；`skeletonColor(context)`
取当前主题骨架色。

### 页面骨架

`HomeSkeleton`（banner 152 + 指示点 + SectionHeader + 三列网格）、
`CarouselSkeleton`（与 `CoverCarousel` 同版式：左右 16dp 内缩、顶部 8dp、
152dp 高、12dp 圆角 + 指示点；写真 / 动画首屏轮播加载时都显示它）、
`ProfileSkeleton`（头像行 + 统计行 + ListTile 行高）、
`ComicDetailSkeleton` / `ContentDetailSkeleton`（封面 + 标题 + 简介线 +
`kChapterGridDelegate` 章节网格）、
`BookShelfSkeleton`、`SearchResultSkeleton`、`MediaGridSkeleton`、
`MediaGridBoxSkeleton`、`TextTabsSkeleton`、`DiscoverSkeleton`、
`RankListSkeleton`、`MediaIndexSkeleton`、`NovelListSkeleton`、
`TileListSkeleton`、`ReaderSkeleton`。

`MediaGridSkeleton` 是 box 版（`GridView`，`shrinkWrap` + 禁止滚动）；
放进 `CustomScrollView.slivers` 时必须包 `SliverToBoxAdapter`。

### 加载状态

| 状态 | 表现 |
| --- | --- |
| Initial Loading | 页面骨架（`SkeletonGate` / `PagedMediaList` 首屏骨架） |
| Refreshing | 保留旧内容，只用 `RefreshIndicator` |
| Loading More | 仅列表底部 20dp 小转圈 / 重试按钮 |
| Empty | `EmptyState`，不再显示骨架 |
| Error | `RequestErrorState`，独立重试 |
| Content | 正常内容 |

首屏骨架最短展示 350ms，避免瞬间闪烁；刷新期间不清空旧数据。

## 6. 页面要点

- **首页**：`BrandBar`（品牌 + 48dp 紧凑 SearchBar + 4 个 top tab）→ 152dp 轮播
  →「为你推荐」三列网格。搜索框收紧后头部约 168dp，不再叠加第二层容器。
  发现 / 排行榜的顶栏改用和筛选区同一套 `BrandGlassPanel` 底，两段之间不留
  色差接缝；排行榜两行页签都 `dividerHeight: 0`，不画内部分割线。
- **个人中心**：无标题 AppBar，直接在 `surface` 上铺两张 28dp 圆角白卡。
  头卡：88dp 圆形头像 + `headlineSmall` 粗体昵称 + ID（右侧复制）+ 箭头，
  一条细线后是三列统计（收藏 / 读过 / 阅读模式，数值 `titleSmall`、标签
  `labelSmall`），整卡可点登录或编辑资料。菜单卡：5 条 64dp 行，行首 44dp
  浅色方块图标（粉 / 橙 / 黄 / 绿 / 紫），标题用 `bodyMedium`，
  右侧只留箭头——浏览记录不写条数、网络链路不写节点状态；退出登录是整宽
  56dp 白底圆角按钮，页脚保留版本号。无渐变、无分组标题。
- **链路管理 · 最近请求**：一页 20 条分页查看（上一页 / 下一页 + 当前区间），
  响应耗时与请求时间在行尾垂直两行排列，给路径让出宽度；清空日志回到第一页。
- **浏览记录**：四分段三列网格；记录卡片不带作者行，因此网格行高从
  `kCardTextExtent` 里扣掉作者行（`kCardTextExtent - kCardTitleAuthorGap -
  kCardAuthorHeight`），卡片底部不再留一块空白；加载骨架用同一高度。
- **书架**：`BrandBar` + 登录后「已收藏（收藏数）/ 有更新」两颗 `ChoiceChip`
  + 4 类 `TabBar` +「上次停驻」续读条（48×64 封面 + 已读章节 + 继续按钮）
  + 网格 / 空态。顶部不再放浏览记录、我的下载入口。
- **频道页**（小说 / 写真 / 动画）：`BrandBar` + 频道内 `TabBar` + 题材
  `FilterChip` 行（16dp 起排、8dp 间距、无边框胶囊、选中 `primary` + 反色
  对勾）+ `ChoiceChip` 胶囊排序（更新时间 / 热度）+ 三列网格；
  被 push 时自动带返回键。
- **精选「发现」**：题材行（全部 / 爱情 / 欢乐向…）和地区行（全部 / 日漫 /
  韩漫 / 美漫 / 已完结）都改成横向 `ChoiceChip` 胶囊（16dp 起排、8dp 间距），
  连同排序行一起固定在顶栏下面不滚，整块用 `BrandGlassPanel` 铺毛玻璃；
  网格滚动时从整块底下穿过。
- **精选「排行榜」**：受众行（男频 / 女频 / 小说）与周期行（上升最快 / 周榜 /
  月榜 / 总榜单）固定在顶栏下面，和顶栏拼成一整块毛玻璃；列表首屏按
  「顶栏 + 实测筛选区高度」垫高，滚起来名次行从整块底下穿过。
- **Tag 统一规格**：所有题材 / 状态 / 排序标签都走全局 `chipTheme` ——
  `StadiumBorder`、无描边、`surfaceContainerHighest` 底，选中实心 `primary`
  配 `onPrimary` 文字与对勾，禁止页面内单独写死圆角或描边。字号用 `labelMedium`，
  左右留白 8dp；固定筛选行的 `ChoiceChip` 统一 `materialTapTargetSize:
  shrinkWrap`，行高收到 40dp（小说题材行 44dp），胶囊不再撑到 48dp 占位置。
- **写真排行榜**：周榜 / 月榜 / 总榜单 三段用官方 `TabBar`（3dp primary
  下划线指示器，不再用纯文字变色 tab），下面是和精选页相同的 `RankRow`
  单列行（名次徽章、封面、标题 / 作者 / 热度），不再用三列封面网格。
  首页「上升最快 / 周榜 / 月榜」同样改成 `TabBar`。频道内「排行榜」的
  两行筛选（男频 / 女频 / 小说、上升最快 / 周榜 / 月榜 / 总榜单）也改为
  官方 `TabBar` 下划线页签，不再用纯文字变色行。
- **内容网格卡片**：三列条目统一用官方 `Card`（`surfaceContainerLowest`、12dp
  圆角、无阴影）承载，封面满宽裁到卡片上圆角，标题 / 作者 / 热度 / 日期
  落在 10dp 内边距里；骨架复用同一张 Card 与同一批尺寸常量。
- **设置**：`SliverAppBar` + 四个分组（外观 / 阅读 / 存储 / 新版本探测），
  每组一张 `SurfaceCard`；主题模式与翻页方式用 `SegmentedButton`，种子色是
  38dp 圆形色板 + 选中勾，版本参数沿用两个 `OutlineInputBorder` 输入框，
  两颗 52dp 全宽按钮（`FilledButton` / `FilledButton.tonal`，20dp 圆角）。
- **详情 / 阅读器 / 下载 / 历史 / 登录**：沿用同一 `AppTheme` 组件，
  容器不超过一层 Card，标题 `titleMedium`，列表用 `ListTile`。

### 6.1 下拉刷新

所有带列表的页面都保留下拉刷新，且刷新时走网络、不吃旧缓存：

- 顶栏叠在列表上的一级页面，`RefreshIndicator.edgeOffset` 必须等于
  `topPad`（状态栏 + 顶栏 + 固定筛选区），指示器从毛玻璃下方出现；
  不设 `edgeOffset` 时它会落在屏幕最顶端，被顶栏挡住，看起来像没刷新。
- `PagedMediaList` 通过 `refreshEdgeOffset` 接收这个值；精选发现页、
  排行榜、小说 / 写真 / 动画频道、书架按各自实测的固定区高度传入。
- `onRefresh` 先 `HttpCache.instance.markAllStale()`，再 `reset` 拉第一页；
  已有内容不清空，失败只影响页脚。
- 浏览记录未登录也保留下拉刷新（刷本机记录），不再因为未登录直接
  返回不可刷新的列表。

## 7. 验收清单

- [ ] 使用官方组件，没有手绘的"仿 M3"控件
- [ ] 页面主体为内容，Card 只用于分组，无装饰圆 / 大渐变 / 全胶囊
- [ ] 标题字重不超过 `w500`，字号来自主题字阶
- [ ] 状态栏 / 导航栏透明，内容不被 Insets 遮挡
- [ ] 骨架与真实布局同尺寸，切换时无明显跳动
