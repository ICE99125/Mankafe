import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/auth_user.dart';
import '../services/api_client.dart';
import '../services/image_store.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../services/route_manager.dart';
import '../state/app_state.dart';
import '../widgets/ui.dart';
import '../widgets/user_avatar.dart';

/// ProfileEditScreen — 个人资料编辑页，头像、用户名、昵称、性别，底部登出
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  bool _saving = false;
  bool _uploading = false;

  /// 正在保存的字段（nickname / gender），用于只在对应行显示 loading 占位
  String? _savingField;

  /// 刚选中的本地图片，用于上传成功后立即预览（避免 CDN 同路径缓存导致看起来没变）
  Uint8List? _preview;

  Future<void> _save({String? nickname, int? gender, String? field}) async {
    if (_saving) return;
    final t = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _savingField = field;
    });
    try {
      await context.read<Repository>().updateProfile(
            nickname: nickname,
            gender: gender,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.profileSaved)));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text(t.profileSaveFailed(e.message))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(t.profileSaveFailed(''))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _savingField = null;
        });
      }
    }
  }

  /// 本地选图 → 上传 → 用返回路径更新账号头像
  Future<void> _pickAvatar(AuthUser user) async {
    if (_uploading || _saving) return;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<Repository>();
    final host = context.read<RouteManager>().network2?.cdn ?? '';

    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    if (bytes.lengthInBytes > 2 * 1024 * 1024) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.avatarTooLarge)));
      return;
    }

    setState(() => _uploading = true);
    try {
      final path = await repo.uploadAvatar(bytes: bytes, filename: picked.name);
      await repo.updateProfile(avatar: path);
      // 服务端可能返回同一路径，图片缓存会命中旧图，这里主动淘汰
      for (final p in [user.avatar, path]) {
        final url = resolveImageUrl(p, host: host);
        if (url == null) continue;
        await NetworkImage(url).evict();
        // 自建的图片磁盘缓存也要一起淘汰，否则下次启动又读回旧图
        await ImageStore.instance.evict(url);
      }
      if (!mounted) return;
      setState(() => _preview = bytes);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.profileSaved)));
    } on ApiException catch (e) {
      if (mounted) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
              SnackBar(content: Text(t.profileSaveFailed(e.message))));
      }
    } catch (_) {
      if (mounted) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(t.profileSaveFailed(''))));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _editNickname(AuthUser user) async {
    final t = AppLocalizations.of(context);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _NicknameDialog(
        title: t.nicknameDialogTitle,
        label: t.editNickname,
        initial: user.nickname.isNotEmpty ? user.nickname : user.userName,
      ),
    );
    if (!mounted || value == null) return;
    if (value.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.nicknameEmpty)));
      return;
    }
    if (value.characters.length > 20) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.nicknameTooLong)));
      return;
    }
    if (value == user.nickname) return;
    await _save(nickname: value, field: 'nickname');
  }

  Future<void> _pickGender(AuthUser user) async {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(t.editGender,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ),
            for (final v in const [0, 1, 2])
              ListTile(
                title: Text(t.genderLabel(v)),
                trailing: v == user.gender
                    ? Icon(Icons.check_rounded, color: scheme.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || picked == null || picked == user.gender) return;
    await _save(gender: picked, field: 'gender');
  }

  Future<void> _signOut() async {
    final t = AppLocalizations.of(context);
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
    if (ok != true) return;
    await repo.logout();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final user = context.watch<AppState>().authUser;
    final host = context.watch<RouteManager>().network2?.cdn ?? '';

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        title: Text(t.profileEditTitle),
        actions: [
          // 固定尺寸占位：保存中只切换内容，不改变 AppBar 的布局宽度
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: _saving
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : null,
              ),
            ),
          ),
        ],
      ),
      body: user == null
          ? EmptyState(
              icon: Icons.person_off_outlined,
              title: t.profileSignInFirst,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        onTap: (_saving || _uploading)
                            ? null
                            : () => _pickAvatar(user),
                        title: Text(t.editAvatar,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w500)),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.editAvatarHint,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFFE07B24)),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                t.editAvatarFormats,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 头像位固定44x44：上传中只换成 loading，不改变行宽/行高
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: _uploading
                                  ? Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.4,
                                            color: scheme.primary),
                                      ),
                                    )
                                  : _preview != null
                                      ? ClipOval(
                                          child: Image.memory(
                                            _preview!,
                                            width: 44,
                                            height: 44,
                                            fit: BoxFit.cover,
                                          ),
                                        )
                                      : UserAvatar(
                                          avatar: user.avatar,
                                          host: host,
                                          fallbackText: user.displayName,
                                          size: 44,
                                          backgroundColor:
                                              scheme.secondaryContainer,
                                          foregroundColor:
                                              scheme.onSecondaryContainer,
                                        ),
                            ),
                            // 箭头始终保留，避免上传中消失造成布局跳动
                            Icon(Icons.chevron_right_rounded,
                                size: 20, color: scheme.onSurfaceVariant),
                          ],
                        ),
                      ),
                      _divider(scheme),
                      _ValueRow(
                        label: t.editUsername,
                        value:
                            user.userName.isEmpty ? user.userId : user.userName,
                        showChevron: false,
                      ),
                      _divider(scheme),
                      _ValueRow(
                        label: t.editNickname,
                        value: user.displayName,
                        busy: _saving && _savingField == 'nickname',
                        onTap: (_saving || _uploading)
                            ? null
                            : () => _editNickname(user),
                      ),
                      _divider(scheme),
                      _ValueRow(
                        label: t.editGender,
                        value: t.genderLabel(user.gender),
                        busy: _saving && _savingField == 'gender',
                        onTap: (_saving || _uploading)
                            ? null
                            : () => _pickGender(user),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: _signOut,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(t.profileSignOut),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _divider(ColorScheme scheme) => Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      );
}

/// _NicknameDialog — 昵称编辑弹窗：自持 [TextEditingController]
class _NicknameDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initial;

  const _NicknameDialog({
    required this.title,
    required this.label,
    required this.initial,
  });

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 20,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(t.confirm),
        ),
      ],
    );
  }
}

/// _ValueRow — 单行标签 + 值 + 箭头，值与箭头右对齐
class _ValueRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool busy;
  final bool showChevron;

  const _ValueRow({
    required this.label,
    required this.value,
    this.onTap,
    this.busy = false,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      onTap: onTap,
      title: Text(label,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w500)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (showChevron)
            SizedBox(
              width: 20,
              height: 20,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedOpacity(
                    opacity: busy ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.chevron_right_rounded,
                        size: 20, color: scheme.onSurfaceVariant),
                  ),
                  if (busy)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
