import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_version.dart';
import '../services/device_profile.dart';
import '../services/http_cache.dart';
import '../services/image_store.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

/// SettingsScreen — 设置页，网络、缓存、外观与账号
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int? _cacheBytes;
  int _apiCacheBytes = 0;
  int _imageCacheBytes = 0;
  bool _cacheError = false;
  bool _clearing = false;

  // 新版本探测，输入框常驻展开，初值取当前生效的请求头版本
  late final TextEditingController _versionCtrl =
      TextEditingController(text: DeviceProfile.effectiveVersion);
  late final TextEditingController _codeCtrl =
      TextEditingController(text: DeviceProfile.effectiveVersionCode);
  bool _probing = false;
  String? _probeError;
  AppVersionSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
  }

  @override
  void dispose() {
    _versionCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  /// 把输入框里的值同步到 [DeviceProfile]，请求头下一跳立即生效
  void _syncHeaderVersion() {
    final version = _versionCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (version.isEmpty || code.isEmpty) {
      DeviceProfile.customVersionEnabled = false;
      DeviceProfile.customVersion = DeviceProfile.version;
      DeviceProfile.customVersionCode = DeviceProfile.versionCode;
      _versionCtrl.text = DeviceProfile.version;
      _codeCtrl.text = DeviceProfile.versionCode;
      setState(() {});
      return;
    }
    final custom =
        version != DeviceProfile.version || code != DeviceProfile.versionCode;
    DeviceProfile.customVersionEnabled = custom;
    DeviceProfile.customVersion = version;
    DeviceProfile.customVersionCode = code;
    setState(() {});
  }

  Future<void> _probeVersion() async {
    final repo = context.read<Repository>();
    setState(() {
      _probing = true;
      _probeError = null;
    });
    try {
      final snapshot = await repo.probeAppVersion();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } catch (error) {
      if (!mounted) return;
      setState(() => _probeError = error.toString());
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// 一键把请求头版本切到探测到的最新版本
  void _useLatestVersion() {
    final latest = _snapshot?.android;
    if (latest == null || latest.version.isEmpty) return;
    final t = AppLocalizations.of(context);
    final current = int.tryParse(DeviceProfile.versionCode) ?? 0;
    _versionCtrl.text = latest.version;
    _codeCtrl.text = '${current + 1}';
    _syncHeaderVersion();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t.versionProbeFilled(latest.version, '${current + 1}')),
      ),
    );
  }

  Future<void> _copyDownloadUrl(String url) async {
    final t = AppLocalizations.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.versionProbeCopied)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.versionProbeCopyFailed)),
      );
    }
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 单个文件读取失败不影响整体统计
        }
      }
    }
    return total;
  }

  Future<void> _refreshCacheSize() async {
    var bytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    var failed = false;
    try {
      final tmp = await getTemporaryDirectory();
      bytes += await _dirSize(tmp);
    } catch (_) {
      failed = true;
    }
    // 接口响应缓存与图片磁盘缓存都在 ApplicationSupport 下，不在 temp 里
    _apiCacheBytes = 0;
    _imageCacheBytes = 0;
    try {
      _apiCacheBytes = await HttpCache.instance.diskSizeBytes();
      _imageCacheBytes = await ImageStore.instance.diskSizeBytes();
      bytes += _apiCacheBytes + _imageCacheBytes;
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _cacheBytes = bytes;
      _cacheError = failed;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
    }
    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
    }
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  Future<void> _clearCache() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cacheConfirmTitle),
        content: Text(t.cacheConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.cacheClearAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clearing = true);
    var cleared = PaintingBinding.instance.imageCache.currentSizeBytes;
    var failed = false;
    try {
      final tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        cleared += await _dirSize(tmp);
        await for (final entity in tmp.list(followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {
            failed = true;
          }
        }
      }
    } catch (_) {
      failed = true;
    }
    // 两套自建缓存单独清：临时目录删除动不到它们
    try {
      final api = _apiCacheBytes;
      final image = _imageCacheBytes;
      await HttpCache.instance.clear();
      await ImageStore.instance.clear();
      cleared += api + image;
    } catch (_) {
      failed = true;
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (!mounted) return;
    setState(() => _clearing = false);
    await _refreshCacheSize();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed
            ? t.cacheClearFailed
            : t.cacheCleared(_formatBytes(cleared))),
      ),
    );
  }

  String _cacheSubtitle(AppLocalizations t) {
    if (_clearing) return t.cacheClearing;
    if (_cacheError) return t.cacheComputeFailed;
    final bytes = _cacheBytes;
    if (bytes == null) return '';
    if (bytes == 0) return t.cacheEmpty;
    return t.cacheSizeLabel(_formatBytes(bytes));
  }

  /// 配置卡：两个版本输入框 + 探测 / 一键填入（胶囊按钮）
  Widget _buildVersionControls(AppLocalizations t) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final latest = _snapshot?.android.version ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _versionCtrl,
                decoration:
                    _versionFieldDecoration(t.versionProbeFieldVersion, scheme),
                onChanged: (_) => _syncHeaderVersion(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    _versionFieldDecoration(t.versionProbeFieldCode, scheme),
                onChanged: (_) => _syncHeaderVersion(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: _probing ? null : _probeVersion,
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.all(Radius.circular(AppShape.button)),
              ),
              textStyle: theme.textTheme.titleMedium,
            ),
            icon: _probing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.travel_explore_rounded, size: 20),
            label: Text(_probing ? t.versionProbeRunning : t.versionProbeRun),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.tonalIcon(
            onPressed: latest.isEmpty ? null : _useLatestVersion,
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.all(Radius.circular(AppShape.button)),
              ),
              textStyle: theme.textTheme.titleMedium,
            ),
            icon: const Icon(Icons.bolt_rounded, size: 20),
            label: Text(t.versionProbeFillLatest),
          ),
        ),
        if (_probeError != null) ...[
          const SizedBox(height: 12),
          Text(
            '${t.versionProbeFailed}：$_probeError',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }

  /// 版本输入框：只要描边，不铺 `surfaceContainerHighest` 灰底
  InputDecoration _versionFieldDecoration(String label, ColorScheme scheme) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: border(scheme.outlineVariant),
      enabledBorder: border(scheme.outlineVariant),
      focusedBorder: border(scheme.primary, 1.5),
    );
  }

  /// 结果卡：只列比当前请求头版本更新的渠道
  Widget _buildVersionResult(AppLocalizations t, ColorScheme scheme) {
    final theme = Theme.of(context);
    final channels = _visibleChannels(_snapshot);

    if (channels.isEmpty) {
      return Row(
        children: [
          Icon(Icons.check_circle_outline_rounded,
              size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            t.versionProbeUpToDate,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < channels.length; i++)
          Padding(
            // 只在渠道之间留间距，最后一个不再带下边距
            padding: EdgeInsets.only(top: i == 0 ? 0 : 20),
            child: _versionChannel(
              t,
              scheme,
              channels[i].name,
              channels[i].channel,
            ),
          ),
      ],
    );
  }

  /// 只留比当前请求头版本更新的渠道
  List<({String name, AppVersionChannel channel})> _visibleChannels(
      AppVersionSnapshot? snapshot) {
    if (snapshot == null) return const [];
    final all = <({String name, AppVersionChannel channel})>[
      (name: 'Android', channel: snapshot.android),
      (name: 'iOS', channel: snapshot.ios),
      (name: 'Android Test', channel: snapshot.androidTest),
    ];
    return all
        .where((e) =>
            e.channel.version.isNotEmpty &&
            compareAppVersion(
                    e.channel.version, DeviceProfile.effectiveVersion) >
                0)
        .toList();
  }

  /// 有更新的渠道卡片，展示版本号、强制标记与下载地址
  Widget _versionChannel(
    AppLocalizations t,
    ColorScheme scheme,
    String fallbackName,
    AppVersionChannel channel,
  ) {
    final theme = Theme.of(context);
    final name = channel.name.isNotEmpty ? channel.name : fallbackName;
    final isDark = theme.brightness == Brightness.dark;
    // M3 没有 success 色，这里自带一对绿：更新是好消息，用绿色最直观
    final newFg = isDark ? const Color(0xFF9FD8B1) : const Color(0xFF1F7A43);
    final newBg = isDark ? const Color(0xFF1D3B2A) : const Color(0xFFDFF3E3);
    // 地址用等宽字体、单行显示（超出省略），完整地址由复制按钮保证
    final urlStyle = theme.textTheme.bodySmall!.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurface,
      height: 1.35,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            _chip(t.versionProbeNewFound, newBg, newFg),
            const SizedBox(width: 6),
            _chip(
              channel.forced ? t.versionProbeForced : t.versionProbeNotForced,
              channel.forced
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              channel.forced
                  ? scheme.onErrorContainer
                  : scheme.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            // 图标套一层浅底圆角方块，和左边标题块形成对齐的视觉锚点
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.smartphone_rounded,
                size: 24,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel.version,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: newFg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  t.versionProbeLatest,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
        if (channel.hasDownload) ...[
          const SizedBox(height: 14),
          // 地址单独一块浅底、只占一行：折行会断在 `/copy/` 这种位置，很难看
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              channel.url,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: urlStyle,
            ),
          ),
          const SizedBox(height: 10),
          // 复制做成通栏按钮，压在地址下方
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () => _copyDownloadUrl(channel.url),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t.versionProbeCopy),
            ),
          ),
        ],
      ],
    );
  }

  Widget _chip(String text, Color background, Color foreground) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    // 由 MaterialPageRoute 独立打开
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Consumer<AppState>(
        builder: (context, app, _) {
          return CustomScrollView(
            slivers: [
              // 标题只留在顶部导航栏里：不要 SliverAppBar.large 那种大标题块
              SliverAppBar(
                pinned: true,
                title: Text(t.settingsTitle),
                scrolledUnderElevation: 0,
              ),
              // ---------- 外观（含界面语言） ----------
              SliverToBoxAdapter(
                child: SectionHeader(title: t.appearanceSection),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.themeMode, style: theme.textTheme.labelLarge),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<ThemeMode>(
                            segments: [
                              ButtonSegment(
                                  value: ThemeMode.system,
                                  label: Text(t.followSystem,
                                      maxLines: 1, softWrap: false)),
                              ButtonSegment(
                                  value: ThemeMode.light,
                                  label: Text(t.themeLight,
                                      maxLines: 1, softWrap: false)),
                              ButtonSegment(
                                  value: ThemeMode.dark,
                                  label: Text(t.themeDark,
                                      maxLines: 1, softWrap: false)),
                            ],
                            style: SegmentedButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            selected: {app.themeMode},
                            showSelectedIcon: false,
                            onSelectionChanged: (set) =>
                                app.setThemeMode(set.first),
                          ),
                        ),
                        const Divider(height: 26),
                        Text(t.seedColor, style: theme.textTheme.labelLarge),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: List.generate(
                            AppTheme.seedPresets.length,
                            (i) {
                              final preset = AppTheme.seedPresets[i];
                              final selected = app.seedIndex == i;
                              return GestureDetector(
                                onTap: () => app.setSeed(i),
                                child: Column(
                                  children: [
                                    Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: preset.color,
                                        shape: BoxShape.circle,
                                        border: selected
                                            ? Border.all(
                                                color: scheme.onSurface,
                                                width: 2.5)
                                            : null,
                                      ),
                                      child: selected
                                          ? const Icon(Icons.check_rounded,
                                              color: Colors.white, size: 20)
                                          : null,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(t.seedLabel(i),
                                        style: theme.textTheme.labelSmall),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 26),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.uiLanguage),
                          trailing: DropdownButton<AppLanguage>(
                            value: app.language,
                            underline: const SizedBox.shrink(),
                            borderRadius: BorderRadius.circular(12),
                            items: [
                              for (final lang in AppLanguage.values)
                                DropdownMenuItem(
                                  value: lang,
                                  child: Text(switch (lang) {
                                    AppLanguage.system => t.languageSystem,
                                    AppLanguage.zh => t.languageChinese,
                                    AppLanguage.en => t.languageEnglish,
                                  }),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) app.setLanguage(value);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // ---------- 阅读 ----------
              SliverToBoxAdapter(
                child: SectionHeader(title: t.readingSection),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.pageTurn, style: theme.textTheme.labelLarge),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<ReadDirection>(
                            segments: [
                              ButtonSegment(
                                  value: ReadDirection.horizontal,
                                  label: Text(t.pageTurnHorizontal),
                                  icon: const Icon(Icons.swap_horiz_rounded,
                                      size: 16)),
                              ButtonSegment(
                                  value: ReadDirection.vertical,
                                  label: Text(t.pageTurnVertical),
                                  icon: const Icon(Icons.swap_vert_rounded,
                                      size: 16)),
                            ],
                            selected: {app.readDirection},
                            showSelectedIcon: false,
                            onSelectionChanged: (set) =>
                                app.setReadDirection(set.first),
                          ),
                        ),
                        const Divider(height: 20),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.showProgress),
                          subtitle: Text(
                            t.showProgressHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          value: app.showPageIndicator,
                          onChanged: app.setShowPageIndicator,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // ---------- 存储（清除缓存） ----------
              SliverToBoxAdapter(
                child: SectionHeader(title: t.storageSection),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SurfaceCard(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.cleaning_services_outlined,
                          color: scheme.onPrimaryContainer,
                          size: 22,
                        ),
                      ),
                      title: Text(t.cacheClear),
                      subtitle: Text(_cacheSubtitle(t)),
                      trailing: TextButton(
                        onPressed: _clearing ? null : _clearCache,
                        child: Text(t.cacheClearAction),
                      ),
                    ),
                  ),
                ),
              ),
              // ---------- 新版本探测（只读） ----------
              SliverToBoxAdapter(
                child: SectionHeader(title: t.versionProbeSection),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SurfaceCard(
                    child: _buildVersionControls(t),
                  ),
                ),
              ),
              if (_snapshot != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: SurfaceCard(
                      // 底部收窄：最后一个元素是地址块里的复制按钮
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                      child: _buildVersionResult(t, scheme),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 24 + MediaQuery.paddingOf(context).bottom,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
