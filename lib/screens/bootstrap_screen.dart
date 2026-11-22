import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_strings.dart';
import '../models/link.dart';
import '../services/route_manager.dart';
import '../widgets/ui.dart';
import 'shell.dart';

/// BootstrapScreen — 启动自检页，逐条检测链路后进入主界面
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  bool _skipped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final routes = context.read<RouteManager>();
    await routes.runStartupCheck();
    await Future.delayed(const Duration(milliseconds: 650));
    _enter();
  }

  void _enter() {
    if (!mounted || _skipped) return;
    _skipped = true;
    // 淡入从0.85 起，避免透明度卡在0 时内容不可见
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AppShell(),
        transitionDuration: const Duration(milliseconds: 180),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: Tween<double>(begin: 0.85, end: 1).animate(animation),
          child: child,
        ),
      ),
    );
  }

  void _skip() {
    _enter();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Consumer<RouteManager>(
          builder: (context, routes, _) {
            final network = routes.networkLinks;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(),
                      Center(
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Icon(Icons.auto_stories_rounded,
                              size: 42, color: scheme.onPrimaryContainer),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        t.appName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineLarge
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '进入前先检测链路是否畅通',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 30),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          minHeight: 7,
                          value:
                              routes.startupDone ? 1 : routes.startupProgress,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (!routes.startupDone)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(Icons.check_circle_rounded,
                                size: 16, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              routes.startupDone
                                  ? (routes.lastNotice ?? '检测完成，正在进入…')
                                  : routes.startupPhase,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          Text(
                            '${network.where((l) => l.health != LinkHealth.unknown && l.health != LinkHealth.checking).length}/${network.length}',
                            style: theme.textTheme.labelMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      SurfaceCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        child: SizedBox(
                          height: 206,
                          child: ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: network.length,
                            separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.5)),
                            itemBuilder: (context, i) {
                              final link = network[i];
                              final checking =
                                  link.health == LinkHealth.checking;
                              return SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    checking
                                        ? const SizedBox(
                                            width: 11,
                                            height: 11,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 1.8),
                                          )
                                        : LinkDot(
                                            health: link.health, size: 11),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        link.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                    Text(
                                      link.health == LinkHealth.online
                                          ? '${link.latencyMs ?? 0} ms'
                                          : link.healthLabel,
                                      style:
                                          theme.textTheme.labelMedium?.copyWith(
                                        color: link.health == LinkHealth.online
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const Spacer(),
                      Center(
                        child: TextButton(
                          onPressed: _skip,
                          child: const Text('跳过检测，直接使用当前链路'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '无广告 · 无内购',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
