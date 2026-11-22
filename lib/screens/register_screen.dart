import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/api_client.dart';
import '../services/repository.dart';

/// RegisterScreen — 注册页
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.initialUsername});

  /// 从登录页带过来的用户名，注册失败后回去改密码时不用重打
  final String? initialUsername;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _repeatController = TextEditingController();
  final _inviteController = TextEditingController();

  bool _busy = false;
  bool _obscurePassword = true;
  bool _obscureRepeat = true;
  String? _error;

  /// 原版在提交前就会拦密码格式不对，规则按6–20 位、不含空白
  static final _passwordPattern = RegExp(r'^[^\s]{6,20}$');

  @override
  void initState() {
    super.initState();
    final initial = widget.initialUsername?.trim() ?? '';
    if (initial.isNotEmpty) _usernameController.text = initial;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _repeatController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final repeat = _repeatController.text;

    String? error;
    if (username.isEmpty) {
      error = t.registerEmptyUsername;
    } else if (password.isEmpty) {
      error = t.registerEmptyPassword;
    } else if (!_passwordPattern.hasMatch(password)) {
      error = t.registerPasswordFormat;
    } else if (repeat.isEmpty) {
      error = t.registerEmptyRepeat;
    } else if (password != repeat) {
      error = t.registerPasswordMismatch;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    var ok = false;
    try {
      await context.read<Repository>().register(
            username: username,
            password: password,
            inviteCode: _inviteController.text,
          );
      ok = true;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = t.registerServerError(e.message));
    } catch (_) {
      if (mounted) setState(() => _error = t.registerGenericError);
    } finally {
      // 先结束忙碌态再弹成功框：否则按钮上的进度圈会在弹窗下面一直转，页面上永远有动画在跑
      if (mounted) setState(() => _busy = false);
    }
    if (!ok || !mounted) return;

    final go = await _showSuccess();
    if (!mounted) return;
    // 原版注册完不自动登录，只把用户送回登录页
    if (go) Navigator.of(context).pop(username);
  }

  /// 注册成功，点击前往登录
  Future<bool> _showSuccess() async {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.check_circle_outline_rounded, color: scheme.primary),
        title: Text(t.registerSuccessTitle),
        content: Text(t.registerSuccessBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.registerSuccessAction),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: Text(t.registerTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _usernameController,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: t.registerUsername,
              prefixIcon: const Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            enabled: !_busy,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t.registerPassword,
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? t.passwordShow : t.passwordHide,
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _repeatController,
            enabled: !_busy,
            obscureText: _obscureRepeat,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t.registerPasswordRepeat,
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: _obscureRepeat ? t.passwordShow : t.passwordHide,
                icon: Icon(
                  _obscureRepeat
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscureRepeat = !_obscureRepeat),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _inviteController,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: t.registerInviteCode,
              prefixIcon: const Icon(Icons.card_giftcard_rounded),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 16, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Text(t.registerSubmitting),
                      ],
                    )
                  : Text(t.registerButton),
            ),
          ),
        ],
      ),
    );
  }
}
