import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_info.dart';
import '../l10n/app_localizations.dart';
import '../models/auth_user.dart';
import '../services/repository.dart';
import '../services/route_manager.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';
import 'downloads_screen.dart';
import 'history_screen.dart';
import 'link_screen.dart';
import 'login_screen.dart';
import 'profile_edit_screen.dart';
import 'settings_screen.dart';

/// ProfileScreen — 个人中心：顶部恢复头像 + 背景板的头图式布局
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _openLogin(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<bool>(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, AppLocalizations t) async {
    final repo = context.read<Repository>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.signOutConfirmTitle),
        content: Text(t.signOutConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.signOutAction),
          ),
        ],
      ),
    );
    if (ok == true) await repo.logout();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return Consumer<AppState>(
      builder: (context, app, _) {
        final user = app.authUser;
        final routes = context.watch<RouteManager>();
        final host = routes.network2?.cdn ?? '';
        final isLoggedIn = app.isLoggedIn && user != null;
        return Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: EdgeInsets.only(
                  top: AppSpacing.md,
                  bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom),
              children: [
                _ProfileHeroCard(
                  isLoggedIn: isLoggedIn,
                  user: user,
                  avatarHost: host,
                  expired: app.authExpired,
                  favorites: app.favoriteCount,
                  history: app.history.length,
                  mode: app.readDirection == ReadDirection.horizontal
                      ? t.pageTurnHorizontal
                      : t.pageTurnVertical,
                  onTap: isLoggedIn
                      ? () => _open(context, const ProfileEditScreen())
                      : () => _openLogin(context),
                ),
                _ProfileCard(
                  margin: const EdgeInsets.fromLTRB(
                      AppSpacing.base, AppSpacing.base, AppSpacing.base, 0),
                  children: [
                    if (isLoggedIn)
                      _MenuRow(
                        icon: Icons.person_outline_rounded,
                        iconColor: scheme.primary,
                        label: t.rowProfile,
                        onTap: () => _open(context, const ProfileEditScreen()),
                      ),
                    _MenuRow(
                      icon: Icons.history_rounded,
                      iconColor: const Color(0xFFE07A1F),
                      label: t.rowHistory,
                      onTap: () => _open(context, const HistoryScreen()),
                    ),
                    _MenuRow(
                      icon: Icons.file_download_outlined,
                      iconColor: const Color(0xFFC9971A),
                      label: t.rowDownloads,
                      onTap: () => _open(context, const DownloadsScreen()),
                    ),
                    _MenuRow(
                      icon: Icons.hub_rounded,
                      iconColor: const Color(0xFF2A9D74),
                      label: t.rowLinks,
                      onTap: () => _open(context, const LinkScreen()),
                    ),
                    _MenuRow(
                      icon: Icons.settings_rounded,
                      iconColor: const Color(0xFF7B5BD6),
                      label: t.rowSettings,
                      onTap: () => _open(context, const SettingsScreen()),
                    ),
                  ],
                ),
                if (isLoggedIn)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.base, AppSpacing.lg, AppSpacing.base, 0),
                    child: SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _confirmSignOut(context, t),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: scheme.surfaceContainerLowest,
                          foregroundColor: scheme.onSurface,
                          side: BorderSide.none,
                          elevation: 0,
                          shape: const RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(AppShape.xl)),
                          ),
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        label: Text(t.profileSignOut),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.base, AppSpacing.lg, AppSpacing.base, 0),
                  child: Text(
                    '${t.appName} ${AppInfo.versionLabel}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.outline),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// _ProfileHeroCard — 个人页头卡，头像、昵称、ID 复制与三列统计
class _ProfileHeroCard extends StatelessWidget {
  final bool isLoggedIn;
  final AuthUser? user;
  final String avatarHost;
  final bool expired;
  final int favorites;
  final int history;
  final String mode;
  final VoidCallback onTap;

  const _ProfileHeroCard({
    required this.isLoggedIn,
    required this.user,
    required this.avatarHost,
    required this.expired,
    required this.favorites,
    required this.history,
    required this.mode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final name = isLoggedIn ? user!.displayName : t.profileGuest;
    final subtitle = isLoggedIn
        ? (user!.userId.isEmpty ? t.profileReader : t.userIdLabel(user!.userId))
        : (expired ? t.sessionExpired : t.profileTapSignIn);
    final canCopy = isLoggedIn && user!.userId.isNotEmpty;

    Future<void> copyId() async {
      await Clipboard.setData(ClipboardData(text: user!.userId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.userIdCopied)));
    }

    return _ProfileCard(
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.base, AppSpacing.base, AppSpacing.base, 0),
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.base),
            child: Column(
              children: [
                Row(
                  children: [
                    UserAvatar(
                      avatar: isLoggedIn ? user!.avatar : '',
                      host: avatarHost,
                      fallbackText: isLoggedIn ? name : '',
                      size: 88,
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    const SizedBox(width: AppSpacing.base),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: expired
                                        ? scheme.error
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              if (canCopy)
                                Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: IconButton(
                                    onPressed: copyId,
                                    icon: Icon(
                                      Icons.copy_rounded,
                                      size: 17,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size(28, 28),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 24,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.base),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.55),
                ),
                const SizedBox(height: AppSpacing.base),
                Row(
                  children: [
                    _HeroStat(
                      value: t.favoritesCount(favorites),
                      label: t.statFavorites,
                    ),
                    _StatDivider(color: scheme),
                    _HeroStat(
                      value: t.readsCount(history),
                      label: t.statRead,
                    ),
                    _StatDivider(color: scheme),
                    _HeroStat(value: mode, label: t.statMode),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// _HeroStat — 个人页头卡里的单列统计
class _HeroStat extends StatelessWidget {
  final String value;
  final String label;

  const _HeroStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// _StatDivider — 统计列之间的竖分隔
class _StatDivider extends StatelessWidget {
  final ColorScheme color;

  const _StatDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.6,
      height: 32,
      color: color.outlineVariant.withValues(alpha: 0.55),
    );
  }
}

/// _ProfileCard — 白色圆角卡：个人页的两块内容（头卡 / 菜单）共用同一规格
class _ProfileCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  const _ProfileCard({
    required this.children,
    this.margin =
        const EdgeInsets.symmetric(horizontal: AppSpacing.base, vertical: 0),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: margin,
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppShape.xl)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// _MenuRow — 菜单行：44dp 色块图标 + 标题 + 可选右侧状态 + 箭头，行高64dp
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  const _MenuRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    iconColor.withValues(alpha: 0.14),
                    scheme.surfaceContainerLowest,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              const SizedBox(width: AppSpacing.base),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
              const SizedBox(width: AppSpacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: 24,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
