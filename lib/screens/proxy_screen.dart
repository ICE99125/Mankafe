import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/proxy_config.dart';
import '../services/repository.dart';
import '../state/app_state.dart';
import '../widgets/ui.dart';

/// ProxyScreen — 代理设置页：链路管理 → 代理设置
class ProxyScreen extends StatefulWidget {
  const ProxyScreen({super.key});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  ProxyType _type = ProxyType.http;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _bypass;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final current = context.read<AppState>().proxy;
    _type = current?.type ?? ProxyType.http;
    _host = TextEditingController(text: current?.host ?? '');
    _port = TextEditingController(
        text: current == null || current.port <= 0 ? '' : '${current.port}');
    _username = TextEditingController(text: current?.username ?? '');
    _password = TextEditingController(text: current?.password ?? '');
    _bypass = TextEditingController(text: current?.bypass ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _bypass.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 校验并组装当前表单
  ProxySettings? _read(AppLocalizations t) {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty) {
      _toast(t.proxyInvalidHost);
      return null;
    }
    if (port == null || port <= 0 || port > 65535) {
      _toast(t.proxyInvalidPort);
      return null;
    }
    return ProxySettings(
      type: _type,
      host: host,
      port: port,
      username: _username.text.trim(),
      password: _password.text,
      bypass: _bypass.text.trim(),
    );
  }

  String _describe(
      AppLocalizations t, ProxyProbeResult result, ProxySettings settings) {
    return switch (result.status) {
      ProxyProbeStatus.ok => t.proxyTestOk(result.detail),
      ProxyProbeStatus.unreachable => t.proxyTestUnreachable(settings.address),
      ProxyProbeStatus.authFailed => t.proxyTestAuthFailed,
      ProxyProbeStatus.protocolError => t.proxyTestProtocol(result.detail),
    };
  }

  Future<void> _test() async {
    final t = AppLocalizations.of(context);
    final settings = _read(t);
    if (settings == null) return;
    setState(() => _busy = true);
    final result = await ProxyConfig.probe(settings);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(_describe(t, result, settings));
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final repo = context.read<Repository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final clearing = _host.text.trim().isEmpty && _port.text.trim().isEmpty;
    final settings = clearing ? null : _read(t);
    if (!clearing && settings == null) return;

    setState(() => _busy = true);
    await app.setProxy(settings);
    // 重建传输层：新请求立即走新配置，进行中的请求不会被掐断
    repo.refreshTransport();
    ProxyProbeResult? probe;
    if (settings != null) probe = await ProxyConfig.probe(settings);
    if (!mounted) return;

    final message = settings == null
        ? t.proxyCleared
        : (probe!.ok ? t.proxySaved : _describe(t, probe, settings));
    // 先显示提示再返回，SnackBar 由上层 Messenger 接管，不会随页面消失
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    navigator.pop();
  }

  Future<void> _clear() async {
    _host.clear();
    _port.clear();
    _username.clear();
    _password.clear();
    _bypass.clear();
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = AppLocalizations.of(context);
    final current = context.watch<AppState>().proxy;
    final status = (current != null && current.usable)
        ? t.proxyStatusOn(current.address)
        : t.proxyStatusOff;

    return Scaffold(
      appBar: AppBar(title: Text(t.proxySettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ProxyType>(
                  initialValue: _type,
                  isDense: true,
                  decoration:
                      InputDecoration(labelText: t.proxyType, isDense: true),
                  items: [
                    DropdownMenuItem(
                        value: ProxyType.http, child: Text(t.proxyTypeHttp)),
                    DropdownMenuItem(
                        value: ProxyType.socks5,
                        child: Text(t.proxyTypeSocks5)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => _type = value);
                        },
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: t.proxyHost,
                          hintText: '10.0.2.2',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _port,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: t.proxyPort,
                          hintText: _type == ProxyType.socks5 ? '1080' : '9000',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: t.proxyUsername,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: t.proxyPassword,
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: _obscure ? t.passwordShow : t.passwordHide,
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bypass,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    labelText: t.proxyBypass,
                    helperText: t.proxyBypassHint,
                    helperMaxLines: 2,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  t.proxySecurityNote,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(t.proxySaveAction),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _test,
            child: Text(_busy ? t.proxyTesting : t.proxyTestAction),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : _clear,
            child: Text(t.proxyClearAction),
          ),
        ],
      ),
    );
  }
}
