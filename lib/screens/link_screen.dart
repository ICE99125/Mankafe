import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/link.dart';
import '../services/route_manager.dart';
import '../state/app_state.dart';
import '../widgets/ui.dart';
import 'proxy_screen.dart';

/// LinkScreen — 链路管理：把当前走哪条线、其它线通不通、怎么切全部可视化
class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key});

  @override
  State<LinkScreen> createState() => LinkScreenState();
}

class LinkScreenState extends State<LinkScreen> {
  bool _busy = false;

  /// 请求日志分页：一页20 条，翻页只换当前页，不再整段滚到底
  static const int _logsPerPage = 20;
  int _logPage = 0;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addCustom(RouteManager routes) async {
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (context) => const _AddLinkDialog(),
    );
    if (result == null) return;
    await _run(() => routes.addCustomLink(result.name, result.url));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Consumer<RouteManager>(
      builder: (context, routes, _) {
        final active = routes.activeLink;
        final totalLogs = routes.logs.length;
        final pageCount = (totalLogs + _logsPerPage - 1) ~/ _logsPerPage;
        final currentPage =
            pageCount == 0 ? 0 : _logPage.clamp(0, pageCount - 1);
        final pageStart = currentPage * _logsPerPage;
        final logs = routes.logs.skip(pageStart).take(_logsPerPage).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('链路管理'),
            actions: [
              IconButton(
                tooltip: '重新测速',
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          await routes.probeAll();
                          if (routes.mode == RouteMode.auto) {
                            await routes.setMode(RouteMode.auto);
                          }
                        }),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.speed_rounded),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 当前链路大卡
                SurfaceCard(
                  color: scheme.primaryContainer,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.hub_rounded,
                              size: 18, color: scheme.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Text(
                            '当前链路',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: scheme.onPrimaryContainer),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              routes.mode.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: linkHealthColor(active.health, scheme),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              active.name,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        active.baseUrl,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onPrimaryContainer
                                .withValues(alpha: 0.86)),
                      ),
                      const SizedBox(height: 14),
                      // 四个事实按田字排列：两两一行、左右等宽
                      _FactGrid(
                        items: [
                          _FactItem(label: '状态', value: active.healthLabel),
                          _FactItem(
                            label: '延迟',
                            value: active.latencyMs == null
                                ? '—'
                                : '${active.latencyMs} ms',
                          ),
                          _FactItem(label: '来源', value: active.origin.label),
                          _FactItem(
                            label: '畅通链路',
                            value: '${routes.onlineCount} 条',
                          ),
                        ],
                      ),
                      if (routes.lastNotice != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          routes.lastNotice!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.8)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 模式与工具
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('切换策略',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w500)),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<RouteMode>(
                          segments: const [
                            ButtonSegment(
                              value: RouteMode.auto,
                              label: Text('自动择优'),
                              icon: Icon(Icons.auto_mode_rounded, size: 17),
                            ),
                            ButtonSegment(
                              value: RouteMode.manual,
                              label: Text('手动锁定'),
                              icon: Icon(Icons.pan_tool_alt_rounded, size: 16),
                            ),
                          ],
                          selected: {routes.mode},
                          showSelectedIcon: false,
                          onSelectionChanged: (set) =>
                              routes.setMode(set.first),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Divider(height: 24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('故障时自动回退'),
                        value: routes.autoFallback,
                        onChanged: routes.setAutoFallback,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() async {
                                        await routes.probeAll();
                                        if (routes.mode == RouteMode.auto) {
                                          await routes.setMode(RouteMode.auto);
                                        }
                                      }),
                              icon: const Icon(Icons.speed_rounded, size: 18),
                              label: const Text('一键测速'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _busy
                                  ? null
                                  : () => _run(routes.refreshNetwork2),
                              icon: const Icon(Icons.cloud_download_rounded,
                                  size: 18),
                              label: const Text('拉取下发'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // 链路列表
                const SectionHeader(title: '全部链路'),
                ...routes.links.map((link) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _LinkRow(
                        link: link,
                        selected: link.id == routes.activeId,
                        busy: _busy,
                        onSelect: () => routes.switchTo(link.id),
                        onProbe: () => _run(() => routes.probeOne(link.id)),
                        onDelete: link.removable
                            ? () => routes.removeCustomLink(link.id)
                            : null,
                      ),
                    )),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _addCustom(routes),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('添加自定义链路'),
                ),
                const SizedBox(height: 20),

                // 代理独立于链路：决定出口，不参与链路选择
                _ProxyCard(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ProxyScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // network2 下发信息
                const SectionHeader(title: '线路下发信息'),
                SurfaceCard(
                  child: routes.network2 == null
                      ? Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                size: 18, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '暂无下发结果，显示内置候选。',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (routes.network2!.api.isNotEmpty)
                              _InfoLine('API 主机', routes.network2!.api),
                            if (routes.network2!.cdn.isNotEmpty)
                              _InfoLine('图片 CDN', routes.network2!.cdn),
                            _InfoLine(
                              '下发线路',
                              '${routes.links.where((l) => l.origin == LinkOrigin.discovered).length} 条',
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),

                // 请求日志
                SectionHeader(
                  title: '最近请求',
                  subtitle: '${routes.logs.length} 条',
                  actionLabel: routes.logs.isEmpty ? null : '清空',
                  onAction: () {
                    setState(() => _logPage = 0);
                    routes.clearLogs();
                  },
                ),
                SurfaceCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: routes.logs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Center(
                            child: Text('暂无请求记录',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < logs.length; i++)
                              _LogRow(log: logs[i], last: i == logs.length - 1),
                          ],
                        ),
                ),
                if (pageCount > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: currentPage > 0
                              ? () => setState(() => _logPage = currentPage - 1)
                              : null,
                          icon:
                              const Icon(Icons.chevron_left_rounded, size: 18),
                          label: const Text('上一页'),
                        ),
                        Expanded(
                          child: Text(
                            '${pageStart + 1}-${pageStart + logs.length} / $totalLogs',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: currentPage < pageCount - 1
                              ? () => setState(() => _logPage = currentPage + 1)
                              : null,
                          icon:
                              const Icon(Icons.chevron_right_rounded, size: 18),
                          label: const Text('下一页'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// _FactItem — 一条标签 + 值的事实数据
class _FactItem {
  final String label;
  final String value;
  const _FactItem({required this.label, required this.value});
}

/// _FactGrid — 田字网格：每行两个等宽格子，行数按条目数自动补齐
class _FactGrid extends StatelessWidget {
  final List<_FactItem> items;
  const _FactGrid({required this.items});

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final left = items[i];
      final right = i + 1 < items.length ? items[i + 1] : null;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: _gap));
      rows.add(
        // stretch 需要确定的高度，IntrinsicHeight 让同一行的两块取较高的那个
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _Fact(item: left)),
              const SizedBox(width: _gap),
              Expanded(
                child: right == null ? const SizedBox() : _Fact(item: right),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

/// _Fact — 链路信息的一格
class _Fact extends StatelessWidget {
  final _FactItem item;
  const _Fact({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.onPrimaryContainer.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// _LinkRow — 线路列表的一行，含选中、探测与删除
class _LinkRow extends StatelessWidget {
  final RouteLink link;
  final bool selected;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onProbe;
  final VoidCallback? onDelete;

  const _LinkRow({
    required this.link,
    required this.selected,
    required this.busy,
    required this.onSelect,
    required this.onProbe,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      color: selected ? scheme.secondaryContainer : null,
      onTap: busy ? null : onSelect,
      child: Row(
        children: [
          link.health == LinkHealth.checking
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : LinkDot(health: link.health, size: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        link.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OriginChip(origin: link.origin),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  link.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      link.health == LinkHealth.online
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 13,
                      color: link.health == LinkHealth.online
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${link.healthLabel}'
                      '${link.latencyMs != null && link.health == LinkHealth.online ? ' · ${link.latencyMs} ms' : ''}'
                      '${link.detail != null && link.health == LinkHealth.offline ? ' · ${link.detail}' : ''}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: '删除自定义链路',
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              onPressed: busy ? null : onDelete,
            ),
          IconButton(
            tooltip: '单独测速',
            icon: const Icon(Icons.network_check_rounded, size: 18),
            onPressed: busy ? null : onProbe,
          ),
          // 新版 Flutter 用 RadioGroup 统一管理选中值
          RadioGroup<String>(
            groupValue: selected ? link.id : null,
            onChanged: (String? _) {
              if (!busy) onSelect();
            },
            child: Radio<String>(value: link.id),
          ),
        ],
      ),
    );
  }
}

/// _InfoLine — 标签加值的一行
class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  const _InfoLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// _LogRow — 请求日志的一行
class _LogRow extends StatelessWidget {
  final RequestLog log;
  final bool last;
  const _LogRow({required this.log, this.last = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = log.error ?? 'HTTP ${log.status}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
            ),
      child: Row(
        children: [
          Icon(
            log.ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 15,
            color: log.ok ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${log.method} ${log.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
                Text(
                  '${log.linkName} · $detail',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${log.latencyMs} ms',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                log.timeLabel,
                style:
                    theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// _AddLinkDialog — 添加自定义链路对话框
class _AddLinkDialog extends StatefulWidget {
  const _AddLinkDialog();

  @override
  State<_AddLinkDialog> createState() => _AddLinkDialogState();
}

class _AddLinkDialogState extends State<_AddLinkDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController(text: 'https://');

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final name = _nameController.text.trim();
      Navigator.of(context).pop((
        name: name.isEmpty ? '自定义链路' : name,
        url: _urlController.text.trim(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自定义链路'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称'),
              validator: (v) => v == null || v.trim().isEmpty ? '请填写名称' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://your-host.example',
              ),
              validator: (v) {
                final uri = Uri.tryParse((v ?? '').trim());
                if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                  return '请输入含 http(s):// 的合法地址';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加并测速')),
      ],
    );
  }
}

/// _ProxyCard — 代理入口：独立于链路列表的单独卡片，点击进入代理设置页
class _ProxyCard extends StatelessWidget {
  const _ProxyCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final proxy = context.watch<AppState>().proxy;
    final enabled = proxy != null && proxy.usable;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.vpn_lock_rounded,
          color: enabled ? scheme.primary : scheme.outline,
        ),
        title: Text(t.proxyTitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              enabled
                  ? t.proxyStatusShortOn(proxy.address)
                  : t.proxyStatusShortOff,
              style: theme.textTheme.bodySmall?.copyWith(
                color: enabled ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: scheme.outline),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
