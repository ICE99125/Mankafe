import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// ProxyType — 代理类型
enum ProxyType { http, socks5 }

/// ProxyProbeStatus — 连通性探测结果，用于把连不上 / 认证失败 / 不是代理分开提示
enum ProxyProbeStatus { ok, unreachable, authFailed, protocolError }

class ProxyProbeResult {
  const ProxyProbeResult(this.status, [this.detail = '']);

  final ProxyProbeStatus status;
  final String detail;

  bool get ok => status == ProxyProbeStatus.ok;
}

/// ProxySettings — 一份完整的代理配置（设置页网络 › 代理）
class ProxySettings {
  const ProxySettings({
    this.type = ProxyType.http,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
    this.bypass = '',
  });

  final ProxyType type;
  final String host;
  final int port;

  /// 用户名 / 密码用于代理返回407（HTTP）或认证子协商（SOCKS5）
  final String username;
  final String password;

  /// 逗号分隔的直连名单
  final String bypass;

  /// 主机端口合法才真正挂代理
  bool get usable => host.trim().isNotEmpty && port > 0 && port <= 65535;

  String get address => '${host.trim()}:$port';

  ProxySettings copyWith({
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    String? bypass,
  }) {
    return ProxySettings(
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      bypass: bypass ?? this.bypass,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'host': host.trim(),
        'port': port,
        'username': username,
        'password': password,
        'bypass': bypass,
      };

  factory ProxySettings.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'];
    final port = json['port'];
    return ProxySettings(
      type: ProxyType.values.firstWhere(
        (t) => t.name == typeName,
        // 旧版本存过 `https`（当时并没有实现），按 HTTP 代理读回来
        orElse: () => ProxyType.http,
      ),
      host: (json['host'] as String? ?? '').trim(),
      port: port is int ? port : int.tryParse('$port') ?? 0,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      bypass: json['bypass'] as String? ?? '',
    );
  }
}

/// Socks5Exception — SOCKS5 握手失败：带着能直接展示给用户的原因
class Socks5Exception implements Exception {
  const Socks5Exception(this.status, this.message);

  final ProxyProbeStatus status;
  final String message;

  @override
  String toString() => 'Socks5Exception($message)';
}

/// ProxyConfig — 全局代理配置
class ProxyConfig {
  ProxyConfig._();

  /// 持久化键，AppState 与启动时读取共用同一个
  static const String prefKey = 'pref_proxy';

  static ProxySettings? _settings;

  static ProxySettings? get settings => _settings;

  static bool get enabled => _settings?.usable ?? false;

  /// 当前生效的代理地址（`host:port`），未启用时为空串
  static String get address => enabled ? _settings!.address : '';

  static String encode(ProxySettings settings) => jsonEncode(settings.toJson());

  /// 解析持久化内容：JSON 或旧版 `host:port`
  static ProxySettings? decode(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('{')) {
      try {
        final map = jsonDecode(value);
        if (map is Map) {
          return ProxySettings.fromJson(Map<String, dynamic>.from(map));
        }
      } catch (_) {
        // 落到下面的旧格式解析
      }
    }
    final idx = value.lastIndexOf(':');
    if (idx <= 0 || idx == value.length - 1) return null;
    final host = value.substring(0, idx).trim();
    final port = int.tryParse(value.substring(idx + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      return null;
    }
    return ProxySettings(host: host, port: port);
  }

  /// 应用代理
  static void apply(ProxySettings? settings) {
    _settings = settings;
    HttpOverrides.global = (settings == null || !settings.usable)
        ? null
        : _ProxyHttpOverrides(settings);
  }

  /// 启动时从持久化里恢复，必须在 runApp 之前调用
  static Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    apply(decode(prefs.getString(prefKey)));
  }

  /// 命中直连名单则返回 true
  static bool bypasses(String host, String bypass) {
    if (bypass.trim().isEmpty) return false;
    final target = host.toLowerCase();
    for (final raw in bypass.split(',')) {
      var pattern = raw.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern.startsWith('*.')) {
        pattern = pattern.substring(2);
      } else if (pattern.startsWith('.')) {
        pattern = pattern.substring(1);
      }
      if (target == pattern || target.endsWith('.$pattern')) return true;
    }
    return false;
  }

  /// 判断底层连接异常是否由代理导致
  static bool isProxyFailure(
    Object error, {
    required String host,
    required int port,
  }) {
    final proxyHost = host.trim().toLowerCase();
    if (error is Socks5Exception) return true;
    if (error is HandshakeException || error is TlsException) return true;
    if (error is HttpException) return true;
    if (error is SocketException) {
      final address = error.address;
      if (address != null &&
          proxyHost.isNotEmpty &&
          address.host.toLowerCase() == proxyHost &&
          (error.port == null || error.port == port)) {
        return true;
      }
      if (proxyHost.isNotEmpty &&
          error.message.toLowerCase().contains(proxyHost)) {
        return true;
      }
      final code = error.osError?.errorCode;
      return error.port == port &&
          (code == 111 || code == 110 || code == 113 || code == 101);
    }
    return false;
  }

  /// 保存 / 测试前的连通性探测
  static Future<ProxyProbeResult> probe(ProxySettings settings) async {
    if (settings.type == ProxyType.socks5) return _probeSocks5(settings);

    final Socket socket;
    try {
      socket = await Socket.connect(
        settings.host.trim(),
        settings.port,
        timeout: const Duration(seconds: 4),
      );
    } catch (error) {
      return ProxyProbeResult(ProxyProbeStatus.unreachable, '$error');
    }
    try {
      const target = 'example.com:443';
      final buffer = StringBuffer()
        ..write('CONNECT $target HTTP/1.1\r\n')
        ..write('Host: $target\r\n');
      if (settings.username.isNotEmpty) {
        final basic = base64Encode(
            utf8.encode('${settings.username}:${settings.password}'));
        buffer.write('Proxy-Authorization: Basic $basic\r\n');
      }
      buffer.write('\r\n');
      socket.write(buffer.toString());
      await socket.flush();
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 4));
      final match =
          RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(line.trim());
      if (match == null) {
        return ProxyProbeResult(ProxyProbeStatus.protocolError, line.trim());
      }
      final code = int.parse(match.group(1)!);
      if (code == 407) {
        return const ProxyProbeResult(ProxyProbeStatus.authFailed, 'HTTP 407');
      }
      if (code >= 100 && code < 600) {
        return ProxyProbeResult(ProxyProbeStatus.ok, 'HTTP $code');
      }
      return ProxyProbeResult(ProxyProbeStatus.protocolError, 'HTTP $code');
    } catch (error) {
      return ProxyProbeResult(ProxyProbeStatus.protocolError, '$error');
    } finally {
      socket.destroy();
    }
  }

  static Future<ProxyProbeResult> _probeSocks5(ProxySettings settings) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        settings.host.trim(),
        settings.port,
        timeout: const Duration(seconds: 4),
      );
    } catch (error) {
      return ProxyProbeResult(ProxyProbeStatus.unreachable, '$error');
    }
    try {
      final tunnel = await openSocks5Tunnel(
        socket,
        host: 'example.com',
        port: 443,
        username: settings.username,
        password: settings.password,
      );
      tunnel.destroy();
      return const ProxyProbeResult(ProxyProbeStatus.ok, 'SOCKS5 CONNECT 成功');
    } on Socks5Exception catch (error) {
      socket.destroy();
      return ProxyProbeResult(error.status, error.message);
    } catch (error) {
      socket.destroy();
      return ProxyProbeResult(ProxyProbeStatus.protocolError, '$error');
    }
  }

  /// 在已连通的 [proxy] 上做 SOCKS5（RFC 1928）握手 + `CONNECT host:port`
  static Future<Socket> openSocks5Tunnel(
    Socket proxy, {
    required String host,
    required int port,
    String username = '',
    String password = '',
  }) async {
    final iterator = StreamIterator<Uint8List>(proxy);
    final pending = <int>[];

    Future<void> fill() async {
      if (!await iterator.moveNext()) {
        // 已经 TCP 连上了却读不到握手数据：对方不是 SOCKS5 代理（或直接断开）
        throw const Socks5Exception(
            ProxyProbeStatus.protocolError, '对方不是 SOCKS5 代理，握手前就断开了连接');
      }
      pending.addAll(iterator.current);
    }

    Future<int> readByte() async {
      while (pending.isEmpty) {
        await fill();
      }
      return pending.removeAt(0);
    }

    Future<void> readInto(int count) async {
      while (pending.length < count) {
        await fill();
      }
      pending.removeRange(0, count);
    }

    final hasAuth = username.isNotEmpty || password.isNotEmpty;
    proxy.add([0x05, hasAuth ? 0x02 : 0x01, 0x00, if (hasAuth) 0x02]);
    await proxy.flush();

    if (await readByte() != 0x05) {
      throw const Socks5Exception(
          ProxyProbeStatus.protocolError, '代理返回的版本不是 SOCKS5');
    }
    final method = await readByte();
    if (method == 0xFF) {
      throw const Socks5Exception(ProxyProbeStatus.authFailed, '代理拒绝了所有认证方式');
    }
    if (method == 0x02) {
      final user = utf8.encode(username);
      final pass = utf8.encode(password);
      if (user.length > 255 || pass.length > 255) {
        throw const Socks5Exception(
            ProxyProbeStatus.authFailed, 'SOCKS5 用户名或密码过长');
      }
      proxy.add([0x01, user.length, ...user, pass.length, ...pass]);
      await proxy.flush();
      if (await readByte() != 0x01) {
        throw const Socks5Exception(
            ProxyProbeStatus.protocolError, 'SOCKS5 认证子协商版本错误');
      }
      if (await readByte() != 0x00) {
        throw const Socks5Exception(
            ProxyProbeStatus.authFailed, 'SOCKS5 用户名或密码错误');
      }
    } else if (method != 0x00) {
      throw Socks5Exception(ProxyProbeStatus.protocolError,
          '代理要求不支持的认证方式 0x${method.toRadixString(16)}');
    }

    final target = utf8.encode(host);
    if (target.length > 255) {
      throw const Socks5Exception(ProxyProbeStatus.protocolError, '目标域名过长');
    }
    proxy.add([
      0x05,
      0x01, // CONNECT
      0x00,
      0x03, // 域名寻址
      target.length,
      ...target,
      (port >> 8) & 0xFF,
      port & 0xFF,
    ]);
    await proxy.flush();

    if (await readByte() != 0x05) {
      throw const Socks5Exception(
          ProxyProbeStatus.protocolError, 'CONNECT 回复的版本不是 SOCKS5');
    }
    final reply = await readByte();
    await readInto(1); // RSV
    final addressType = await readByte();
    if (reply != 0x00) {
      throw Socks5Exception(ProxyProbeStatus.protocolError,
          'CONNECT 被代理拒绝（REP=0x${reply.toRadixString(16)}）');
    }
    switch (addressType) {
      case 0x01:
        await readInto(4 + 2);
      case 0x03:
        final length = await readByte();
        await readInto(length + 2);
      case 0x04:
        await readInto(16 + 2);
      default:
        throw Socks5Exception(ProxyProbeStatus.protocolError,
            '无法识别的地址类型 0x${addressType.toRadixString(16)}');
    }

    // 握手期间已经从 socket 读过字节
    final incoming = StreamController<Uint8List>();
    void pump() {
      if (pending.isNotEmpty) {
        incoming.add(Uint8List.fromList(pending));
        pending.clear();
      }
      iterator.moveNext().then((hasNext) {
        if (!hasNext) {
          incoming.close();
          return;
        }
        incoming.add(iterator.current);
        pump();
      }, onError: (Object error, StackTrace stack) {
        incoming.addError(error, stack);
        incoming.close();
      });
    }

    pump();
    return _TunnelSocket(proxy, incoming.stream);
  }
}

/// _TunnelSocket — 把已在代理隧道里的 socket 包成 HttpClient 能用的 [Socket]
class _TunnelSocket extends Stream<Uint8List> implements Socket {
  _TunnelSocket(this._inner, this._incoming);

  final Socket _inner;
  final Stream<Uint8List> _incoming;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _incoming.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get remotePort => _inner.remotePort;

  @override
  void destroy() => _inner.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}

/// _ProxyHttpOverrides — 给所有 HttpClient 挂代理
class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this.settings);

  final ProxySettings settings;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => ProxyConfig.bypasses(uri.host, settings.bypass)
        ? 'DIRECT'
        : 'PROXY ${settings.address}';
    if (settings.type == ProxyType.socks5) {
      // findProxy 只说 HTTP 代理的语言
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        if (proxyHost == null) {
          return Socket.startConnect(uri.host, uri.port);
        }
        final socket = await Socket.connect(
          proxyHost,
          proxyPort ?? settings.port,
          timeout: const Duration(seconds: 20),
        );
        try {
          final tunnel = await ProxyConfig.openSocks5Tunnel(
            socket,
            host: uri.host,
            port: uri.port,
            username: settings.username,
            password: settings.password,
          );
          return ConnectionTask.fromSocket(
              Future.value(tunnel), tunnel.destroy);
        } catch (_) {
          socket.destroy();
          rethrow;
        }
      };
    } else if (settings.username.isNotEmpty) {
      // 凭据只交给 HttpClient 内存态，不写日志、不在界面回显
      client.authenticateProxy = (host, port, scheme, realm) {
        client.addProxyCredentials(
          host,
          port,
          realm ?? '',
          HttpClientBasicCredentials(settings.username, settings.password),
        );
        return Future<bool>.value(true);
      };
    }
    return client;
  }
}
