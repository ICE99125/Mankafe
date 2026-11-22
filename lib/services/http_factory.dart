import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 统一的 HTTP 客户端工厂，关键是指定连接超时
http.Client buildHttpClient({
  Duration connectionTimeout = const Duration(seconds: 6),
}) {
  final inner = HttpClient()
    ..connectionTimeout = connectionTimeout
    // 复用空闲连接，减少重复握手
    ..idleTimeout = const Duration(seconds: 15);
  return IOClient(inner);
}
