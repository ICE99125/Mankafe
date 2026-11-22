import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/services/proxy_config.dart';

/// SOCKS5 是「真的能用」还是「下拉里摆着好看」，靠这套测试说话。
///
/// 这里起一个真正的本地 SOCKS5 服务（RFC 1928 的握手 + CONNECT）当上游，
/// 再让 `HttpClient` 通过 [ProxyConfig] 挂上去访问本地 HTTP 服务器 ——
/// 覆盖 `connectionFactory` → 握手 → 隧道 socket 交回 HttpClient 的全链路。
void main() {
  test('经 SOCKS5 代理的 HttpClient 能拿到真实响应体', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    http.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write('socks5-ok');
      request.response.close();
    });

    final proxy = await _FakeSocks5Proxy.start();
    addTearDown(proxy.close);

    ProxyConfig.apply(ProxySettings(
      type: ProxyType.socks5,
      host: '127.0.0.1',
      port: proxy.port,
    ));
    addTearDown(() => ProxyConfig.apply(null));

    expect(ProxyConfig.enabled, isTrue, reason: 'SOCKS5 配置必须是可用状态');

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:${http.port}/ping'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, 200);
    expect(body, 'socks5-ok');
    expect(proxy.connections, 1, reason: '连接必须真的经过 SOCKS5 代理');
    expect(proxy.lastTargetPort, http.port);
  });

  test('代理要求认证、密码不对时抛 authFailed，而不是含糊的协议错误', () async {
    final proxy = await _FakeSocks5Proxy.start(
      requireAuth: true,
      username: 'user',
      password: 'secret',
    );
    addTearDown(proxy.close);

    final socket = await Socket.connect(
        InternetAddress.loopbackIPv4, proxy.port,
        timeout: const Duration(seconds: 5));
    await expectLater(
      ProxyConfig.openSocks5Tunnel(
        socket,
        host: 'example.com',
        port: 443,
        username: 'user',
        password: 'wrong',
      ),
      throwsA(isA<Socks5Exception>()
          .having((e) => e.status, 'status', ProxyProbeStatus.authFailed)),
    );
    socket.destroy();
  });

  test('认证正确时握手成功并拿到隧道 socket', () async {
    final proxy = await _FakeSocks5Proxy.start(
      requireAuth: true,
      username: 'user',
      password: 'secret',
    );
    addTearDown(proxy.close);

    final socket = await Socket.connect(
        InternetAddress.loopbackIPv4, proxy.port,
        timeout: const Duration(seconds: 5));
    final tunnel = await ProxyConfig.openSocks5Tunnel(
      socket,
      host: 'example.com',
      port: 443,
      username: 'user',
      password: 'secret',
    );
    expect(tunnel, isNotNull);
    tunnel.destroy();
    expect(proxy.authAccepted, isTrue);
  });

  test('探测：端口没人监听 → unreachable；不是 SOCKS5 → protocolError', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final unreachable = await ProxyConfig.probe(ProxySettings(
      type: ProxyType.socks5,
      host: '127.0.0.1',
      port: closedPort,
    ));
    expect(unreachable.status, ProxyProbeStatus.unreachable);

    // 一个只会说 HTTP 的端口：SOCKS5 握手会撞到「版本不是 SOCKS5」。
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    http.listen((request) {
      request.response.write('http');
      request.response.close();
    });
    final mismatch = await ProxyConfig.probe(ProxySettings(
      type: ProxyType.socks5,
      host: '127.0.0.1',
      port: http.port,
    ));
    expect(mismatch.status, ProxyProbeStatus.protocolError);
  });
}

/// 极简 SOCKS5 服务器：只支持域名寻址的 CONNECT，够验证客户端实现。
class _FakeSocks5Proxy {
  _FakeSocks5Proxy._(
      this._server, this.requireAuth, this.username, this.password);

  final ServerSocket _server;
  final bool requireAuth;
  final String username;
  final String password;

  int connections = 0;
  int? lastTargetPort;
  bool authAccepted = false;

  int get port => _server.port;

  static Future<_FakeSocks5Proxy> start({
    bool requireAuth = false,
    String username = '',
    String password = '',
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _FakeSocks5Proxy._(server, requireAuth, username, password);
    server.listen(proxy._handle, onError: (_) {});
    return proxy;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    connections++;
    final iterator = StreamIterator<List<int>>(client);
    final buffer = <int>[];

    Future<int> readByte() async {
      while (buffer.isEmpty) {
        if (!await iterator.moveNext()) throw const SocketException('closed');
        buffer.addAll(iterator.current);
      }
      return buffer.removeAt(0);
    }

    Socket? upstream;
    try {
      if (await readByte() != 0x05) return;
      final methods = await readByte();
      final offered = <int>[];
      for (var i = 0; i < methods; i++) {
        offered.add(await readByte());
      }
      if (requireAuth) {
        if (!offered.contains(0x02)) {
          client.add([0x05, 0xFF]);
          await client.flush();
          return;
        }
        client.add([0x05, 0x02]);
        await client.flush();
        if (await readByte() != 0x01) return;
        final ulen = await readByte();
        final user = <int>[];
        for (var i = 0; i < ulen; i++) {
          user.add(await readByte());
        }
        final plen = await readByte();
        final pass = <int>[];
        for (var i = 0; i < plen; i++) {
          pass.add(await readByte());
        }
        final ok =
            utf8.decode(user) == username && utf8.decode(pass) == password;
        client.add([0x01, ok ? 0x00 : 0x01]);
        await client.flush();
        if (!ok) return;
        authAccepted = true;
      } else {
        client.add([0x05, 0x00]);
        await client.flush();
      }

      if (await readByte() != 0x05) return;
      if (await readByte() != 0x01) return; // 只支持 CONNECT
      await readByte(); // RSV
      final atyp = await readByte();
      String targetHost;
      if (atyp == 0x03) {
        final length = await readByte();
        final host = <int>[];
        for (var i = 0; i < length; i++) {
          host.add(await readByte());
        }
        targetHost = utf8.decode(host);
      } else if (atyp == 0x01) {
        final parts = <String>[];
        for (var i = 0; i < 4; i++) {
          parts.add('${await readByte()}');
        }
        targetHost = parts.join('.');
      } else {
        client.add([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        return;
      }
      final port = (await readByte() << 8) | await readByte();
      lastTargetPort = port;

      try {
        upstream = await Socket.connect(
          InternetAddress(targetHost == 'localhost' ? '127.0.0.1' : targetHost),
          port,
          timeout: const Duration(seconds: 5),
        );
      } catch (_) {
        upstream = null;
      }

      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await client.flush();
      if (upstream == null) {
        // 测试机没有外网（例如 example.com）：握手成功即可，不再转发。
        return;
      }

      // 双向转发：客户端剩余字节 → 上游；上游响应 → 客户端。
      final tail = <int>[];
      while (buffer.isNotEmpty) {
        tail.add(buffer.removeAt(0));
      }
      if (tail.isNotEmpty) upstream.add(tail);
      () async {
        while (await iterator.moveNext()) {
          upstream!.add(iterator.current);
        }
        await upstream!.close();
      }();

      upstream.listen(
        (data) => client.add(data),
        onDone: () => client.destroy(),
        onError: (_) => client.destroy(),
      );
    } catch (_) {
      upstream?.destroy();
      client.destroy();
    }
  }
}
