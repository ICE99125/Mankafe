import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/api_client.dart';
import '../services/repository.dart';
import '../widgets/ui.dart';
import 'register_screen.dart';

/// LoginScreen — 账号密码登录页，成功后 pop(true)
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    String? error;
    if (username.isEmpty) {
      error = t.loginEmptyUsername;
    } else if (password.isEmpty) {
      error = t.loginEmptyPassword;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Repository>().login(username, password);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = t.loginServerError(e.message));
    } catch (_) {
      if (mounted) setState(() => _error = t.loginGenericError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 打开注册页，返回时回填用户名
  Future<void> _openRegister() async {
    final username = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => RegisterScreen(
          initialUsername: _usernameController.text.trim(),
        ),
      ),
    );
    if (!mounted || username == null) return;
    setState(() {
      _usernameController.text = username;
      _passwordController.clear();
      _error = null;
    });
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
        title: Text(t.loginTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          SectionHeader(title: t.accountSection, subtitle: t.loginIntro),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _usernameController,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: t.loginUsername,
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _passwordController,
                  enabled: !_busy,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: t.loginPassword,
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip:
                          _obscurePassword ? t.passwordShow : t.passwordHide,
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
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
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
                              Text(t.loginSubmitting),
                            ],
                          )
                        : Text(t.loginButton),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: _busy ? null : _openRegister,
              child: Text(t.loginGoRegister),
            ),
          ),
        ],
      ),
    );
  }
}
