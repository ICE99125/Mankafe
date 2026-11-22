import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/proxy_screen.dart';
import '../services/api_client.dart';
import 'ui.dart';

/// RequestErrorInfo — 一次请求失败的归因结果：标题 / 说明 / 是否代理问题
class RequestErrorInfo {
  const RequestErrorInfo(this.title, this.message, {this.isProxy = false});

  final String title;
  final String message;

  /// 只有确实经代理失败才为 true（决定是否展示去设置代理入口）
  final bool isProxy;
}

/// 按异常类型映射成用户可读的标题与说明
RequestErrorInfo describeRequestError(AppLocalizations t, Object error) {
  if (error is ProxyUnavailableException) {
    return RequestErrorInfo(t.proxyErrorTitle, t.proxyErrorBody(error.address),
        isProxy: true);
  }
  if (error is LinkUnreachableException) {
    return RequestErrorInfo(t.linkErrorTitle, t.linkErrorBody);
  }
  if (error is ApiFormatException) {
    return RequestErrorInfo(t.dataFormatErrorTitle, t.dataFormatErrorBody);
  }
  if (error is ApiException && error.status != null) {
    return RequestErrorInfo(t.apiErrorTitle, t.apiErrorBody(error.status!));
  }
  // 业务错误：原样透出服务端 message
  final serverMessage = error is ApiException ? error.message : '';
  return RequestErrorInfo(t.loadFailed,
      serverMessage.isNotEmpty ? serverMessage : t.loadFailedHint);
}

/// RequestErrorState — 请求失败的统一错误态
class RequestErrorState extends StatelessWidget {
  const RequestErrorState({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  Future<void> _openProxy(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProxyScreen()),
    );
    // 改完代理返回后直接重试，省一次点击
    onRetry();
  }

  IconData get _icon {
    final error = this.error;
    if (error is ProxyUnavailableException) return Icons.vpn_lock_rounded;
    if (error is ApiFormatException) return Icons.data_object_rounded;
    if (error is ApiException && error.status != null) {
      return Icons.error_outline_rounded;
    }
    return Icons.cloud_off_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final info = describeRequestError(t, error);

    return EmptyState(
      icon: _icon,
      title: info.title,
      message: info.message,
      action: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          if (info.isProxy)
            FilledButton.tonalIcon(
              onPressed: () => _openProxy(context),
              icon: const Icon(Icons.vpn_lock_rounded, size: 18),
              label: Text(t.proxyErrorAction),
            ),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(t.retry),
          ),
        ],
      ),
    );
  }
}
