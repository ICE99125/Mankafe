import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/link.dart';
import 'api_endpoints.dart';
import 'http_cache.dart';
import 'http_factory.dart';
import 'proxy_config.dart';
import 'route_manager.dart';

/// ApiException — 业务错误，带 code 与 HTTP 状态码
class ApiException implements Exception {
  final String message;
  final int? code;

  /// HTTP 状态码，仅非2xx 响应时设置
  final int? status;

  const ApiException(this.message, {this.code, this.status});

  @override
  String toString() => message;
}

/// ApiFormatException — 响应拿到了但格式不对，如 HTML 升级页、纯文本 error
class ApiFormatException implements Exception {
  const ApiFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// AuthExpiredException — 登录态失效（HTTP 401 / 信封 code=401）
class AuthExpiredException implements Exception {
  const AuthExpiredException();

  @override
  String toString() => '登录已过期';
}

/// ProxyUnavailableException — 代理层失败，不切换线路
class ProxyUnavailableException implements Exception {
  const ProxyUnavailableException(this.address, this.detail);

  final String address;
  final String detail;

  @override
  String toString() => '代理 $address 不可用：$detail';
}

/// LinkUnreachableException — 目标服务 / 线路不可达（解析、连接或502/504）
class LinkUnreachableException implements Exception {
  const LinkUnreachableException(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// ApiClient — 统一网络层，按当前链路发请求，解析 code / message / results 信封
class ApiClient {
  ApiClient(
    this.routes, {
    String? Function()? token,
    void Function()? onUnauthorized,
    http.Client? httpClient,
    HttpCache? cache,
  })  : _token = token,
        _onUnauthorized = onUnauthorized,
        _http = httpClient ?? buildHttpClient(),
        _cache = cache ?? HttpCache.instance;

  final RouteManager routes;
  final String? Function()? _token;
  final void Function()? _onUnauthorized;
  final HttpCache _cache;
  http.Client _http;

  /// 重建传输层，旧 client 延迟30s 关闭，避免掐断进行中的请求
  void refreshTransport() {
    final old = _http;
    _http = buildHttpClient();
    Timer(const Duration(seconds: 30), old.close);
  }

  static const Duration _timeout = Duration(seconds: 6);

  /// GET 并返回信封里的 results；useCache=false 时完全绕过缓存
  Future<dynamic> get(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
    bool allowRetry = true,
    bool useCache = true,
  }) async {
    final ttl = useCache ? _cache.ttlFor(path) : null;
    final key = ttl == null ? null : _cache.keyFor(path, query);

    if (key != null) {
      final cached = await _cache.readFresh(key);
      if (cached != null) {
        if (kDebugMode) debugPrint('[cache] 命中 $path');
        return cached;
      }
    }

    try {
      final results = await _send('GET', path,
          query: query, timeout: timeout, allowRetry: allowRetry);
      if (key != null && ttl != null) {
        await _cache.write(key, results, ttl);
      }
      return results;
    } on LinkUnreachableException {
      // 连不上才回退；业务错误说明服务端明确拒绝，缓存会掩盖它
      if (key != null) {
        final stale = await _cache.readStale(key);
        if (stale != null) {
          if (kDebugMode) debugPrint('[cache] 离线回退 $path');
          return stale;
        }
      }
      rethrow;
    }
  }

  /// 直取 CDN 原始字节，如轻小说卷正文，不走信封解析
  Future<List<int>> getBytes(
    String url, {
    Duration? timeout,
  }) async {
    final uri = Uri.parse(url);
    final link = routes.activeLink;
    final sw = Stopwatch()..start();
    try {
      final response = await _http
          .get(uri, headers: apiHeaders(token: _token?.call()))
          .timeout(timeout ?? const Duration(seconds: 20));
      sw.stop();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException('HTTP ${response.statusCode}',
            status: response.statusCode);
      }
      _log(link, 'GET', uri, sw, status: response.statusCode);
      return response.bodyBytes;
    } on ApiException catch (error) {
      sw.stop();
      _log(link, 'GET', uri, sw, error: error.message);
      rethrow;
    } catch (error) {
      sw.stop();
      _log(link, 'GET', uri, sw, error: error.toString());
      throw _classifyTransportError(error, uri);
    }
  }

  /// POST JSON，登录等写接口使用
  Future<dynamic> post(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    bool allowRetry = true,
  }) {
    return _send('POST', path,
        body: body, timeout: timeout, allowRetry: allowRetry);
  }

  /// DELETE，参数放 query
  Future<dynamic> delete(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
    bool allowRetry = true,
  }) {
    return _send('DELETE', path,
        query: query, timeout: timeout, allowRetry: allowRetry);
  }

  /// POST application/x-www-form-urlencoded
  Future<dynamic> postForm(
    String path, {
    required Map<String, String> fields,
    Duration? timeout,
    bool allowRetry = true,
  }) {
    return _send('POST', path,
        form: fields, timeout: timeout, allowRetry: allowRetry);
  }

  /// DELETE 带 form body，删除评论接口只认 body 里的参数
  Future<dynamic> deleteForm(
    String path, {
    required Map<String, String> fields,
    Duration? timeout,
    bool allowRetry = true,
  }) {
    return _send('DELETE', path,
        form: fields, timeout: timeout, allowRetry: allowRetry);
  }

  /// POST multipart/form-data，用于头像 / 图片上传
  Future<dynamic> postMultipart(
    String path, {
    required String field,
    required List<int> bytes,
    required String filename,
    Map<String, String>? fields,
    Duration? timeout,
    bool allowRetry = true,
  }) async {
    final link = routes.activeLink;
    final uri = apiUri(link.baseUrl, path, const {'platform': '3'});
    final headers = apiHeaders(token: _token?.call());
    final sw = Stopwatch()..start();
    final limit = timeout ?? const Duration(seconds: 30);

    try {
      final request = http.MultipartRequest('POST', uri)
        ..headers.addAll(headers)
        ..files.add(
            http.MultipartFile.fromBytes(field, bytes, filename: filename));
      if (fields != null && fields.isNotEmpty) {
        request.fields.addAll(fields);
      }
      final streamed = await _http.send(request).timeout(limit);
      final response = await http.Response.fromStream(streamed).timeout(limit);
      sw.stop();
      return _decode(link, uri, 'POST', response, sw);
    } on AuthExpiredException {
      sw.stop();
      _log(link, 'POST', uri, sw, error: '登录已过期');
      rethrow;
    } on ApiException catch (error) {
      sw.stop();
      _log(link, 'POST', uri, sw, error: error.message);
      rethrow;
    } on ApiFormatException catch (error) {
      sw.stop();
      _log(link, 'POST', uri, sw, error: error.message);
      rethrow;
    } catch (error) {
      sw.stop();
      _log(link, 'POST', uri, sw, error: error.toString());
      final failure = _classifyTransportError(error, uri);
      // 代理挂了换线路也没用，直接抛给界面提示检查代理设置
      if (failure is ProxyUnavailableException) throw failure;
      if (allowRetry && routes.handleFailure(link.id)) {
        return postMultipart(path,
            field: field,
            bytes: bytes,
            filename: filename,
            fields: fields,
            timeout: timeout,
            allowRetry: false);
      }
      throw failure;
    }
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Map<String, String>? form,
    Duration? timeout,
    bool allowRetry = true,
    int stage = 0,
  }) async {
    final link = routes.activeLink;
    final params = <String, String>{'platform': '3', ...?query};
    final uri = apiUri(link.baseUrl, path, params);
    final headers = apiHeaders(token: _token?.call());
    if (method == 'POST' && form == null) {
      headers['content-type'] = 'application/json';
    }
    final sw = Stopwatch()..start();

    try {
      final http.Response response = await switch (method) {
        'POST' => _http.post(uri,
            headers: headers,
            body: form ?? jsonEncode(body ?? const <String, dynamic>{})),
        'DELETE' => _http.delete(uri, headers: headers, body: form),
        _ => _http.get(uri, headers: headers),
      }
          .timeout(timeout ?? _timeout);
      sw.stop();
      return _decode(link, uri, method, response, sw);
    } on AuthExpiredException {
      sw.stop();
      _log(link, method, uri, sw, error: '登录已过期');
      rethrow;
    } on ApiException catch (error) {
      // 业务错误不触发链路回退，直接抛给调用方
      sw.stop();
      _log(link, method, uri, sw, error: error.message);
      rethrow;
    } on ApiFormatException catch (error) {
      // 响应已拿到但格式不对，换线路无用
      sw.stop();
      _log(link, method, uri, sw, error: error.message);
      rethrow;
    } catch (error, stack) {
      sw.stop();
      _log(link, method, uri, sw, error: error.toString());
      if (kDebugMode) debugPrint('[api] $method $uri 失败: $error\n$stack');
      final failure = _classifyTransportError(error, uri);
      // 代理挂了换线路也没用，直接抛给界面提示检查代理设置
      if (failure is ProxyUnavailableException) throw failure;
      if (allowRetry) {
        // 同一条线路上再试一次
        if (stage == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          return _send(method, path,
              query: query,
              body: body,
              form: form,
              // 重试用更短的上限，避免一次失败等两倍超时
              timeout: _retryTimeout(timeout),
              allowRetry: true,
              stage: 1);
        }
        // 换一条已探测畅通的线路重试一次
        if (routes.handleFailure(link.id)) {
          return _send(method, path,
              query: query,
              body: body,
              form: form,
              timeout: timeout,
              allowRetry: false,
              stage: 2);
        }
      }
      throw failure;
    }
  }

  /// 重试用的超时上限，最多10s
  static Duration _retryTimeout(Duration? timeout) {
    const cap = Duration(seconds: 10);
    final base = timeout ?? _timeout;
    return base > cap ? cap : base;
  }

  /// 把连接错误分成「代理不可用」与「线路不可达」，供界面区分文案
  Object _classifyTransportError(Object error, Uri uri) {
    final settings = ProxyConfig.settings;
    if (settings != null &&
        settings.usable &&
        !ProxyConfig.bypasses(uri.host, settings.bypass) &&
        ProxyConfig.isProxyFailure(error,
            host: settings.host.trim(), port: settings.port)) {
      return ProxyUnavailableException(settings.address, error.toString());
    }
    return LinkUnreachableException(error.toString());
  }

  /// 401 处理：只有带着 Token 的请求才算登录已过期
  void _notifyUnauthorized() {
    final token = _token?.call();
    if (token != null && token.isNotEmpty) _onUnauthorized?.call();
  }

  /// 校验 HTTP 状态与信封，返回 results，成功时补一条请求日志
  dynamic _decode(
    RouteLink link,
    Uri uri,
    String method,
    http.Response response,
    Stopwatch sw,
  ) {
    if (response.statusCode == 401) {
      _notifyUnauthorized();
      throw const AuthExpiredException();
    }
    if (response.statusCode == 502 ||
        response.statusCode == 503 ||
        response.statusCode == 504) {
      // 网关错误按线路不可达处理，不是业务错误
      throw LinkUnreachableException('HTTP ${response.statusCode}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('HTTP ${response.statusCode}',
          status: response.statusCode);
    }

    // 200 也可能是 HTML 升级页 / 纯文本 error，属接口问题
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiFormatException('响应不是 JSON（HTTP ${response.statusCode}）');
    }
    if (decoded is! Map) {
      throw const ApiFormatException('响应格式异常：不是 JSON 对象');
    }
    final code = decoded['code'];
    if (code == 401) {
      _notifyUnauthorized();
      throw const AuthExpiredException();
    }
    if (code != 200) {
      final message = decoded['message'];
      throw ApiException(
        message is String && message.isNotEmpty ? message : '请求失败（$code）',
        code: code is int ? code : null,
      );
    }
    final results = decoded['results'];
    if (results is String && results.length > 256) {
      // 个别线路可能返回加密后的 results 字符串；上传接口的短路径不在此列
      throw const ApiFormatException('服务端返回了非结构化响应（疑似加密 results）');
    }

    _log(link, method, uri, sw, status: response.statusCode);
    routes.noteSuccess(link.id);
    if (kDebugMode) {
      debugPrint(
          '[api] $method ${uri.path} → 200 (${sw.elapsedMilliseconds} ms)');
    }
    return results;
  }

  void _log(
    RouteLink link,
    String method,
    Uri uri,
    Stopwatch sw, {
    int? status,
    String? error,
  }) {
    routes.addLog(RequestLog(
      time: DateTime.now(),
      method: method,
      path: uri.path,
      linkName: link.name,
      latencyMs: sw.elapsedMilliseconds,
      status: status,
      error: error,
    ));
  }

  void dispose() => _http.close();
}
