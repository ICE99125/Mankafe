import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/route_manager.dart';

/// 这些用例验证的是 [ApiClient.get] 与 [HttpCache] 的接线：
/// 缓存命中时**到底有没有发请求**，是「减轻服务端压力」能否成立的关键。
void main() {
  http.Response ok(dynamic results) => http.Response(
        jsonEncode({'code': 200, 'message': 'ok', 'results': results}),
        200,
        headers: {'content-type': 'application/json'},
      );

  /// 关掉自动回退：否则 `handleFailure` 会在没有在线线路时启动后台探测，
  /// 单测里会去连真实网络。
  ApiClient build(http.Client mock, HttpCache cache) => ApiClient(
        RouteManager()..autoFallback = false,
        httpClient: mock,
        cache: cache,
      );

  test('新鲜期内第二次请求不再打网络', () async {
    final dir = await Directory.systemTemp.createTemp('api_cache_hit');
    final cache = HttpCache(directory: dir);
    var calls = 0;
    final client = build(
      MockClient((req) async {
        calls++;
        return ok({
          'list': [
            {'path_word': 'abc'}
          ]
        });
      }),
      cache,
    );

    final first = await client.get('/api/v3/comics');
    final second = await client.get('/api/v3/comics');

    expect(calls, 1, reason: '第二次应命中缓存，不发请求');
    expect(first, second);

    await dir.delete(recursive: true);
  });

  test('下拉刷新（markAllStale）后重新走网络', () async {
    final dir = await Directory.systemTemp.createTemp('api_cache_stale');
    final cache = HttpCache(directory: dir);
    var calls = 0;
    final client = build(
      MockClient((req) async {
        calls++;
        return ok({'list': [], 'n': calls});
      }),
      cache,
    );

    await client.get('/api/v3/comics');
    await client.get('/api/v3/comics');
    expect(calls, 1);

    cache.markAllStale();
    final refreshed = await client.get('/api/v3/comics');
    expect(calls, 2);
    expect(refreshed['n'], 2);

    await dir.delete(recursive: true);
  });

  test('不缓存的接口每次都发请求（登录态数据）', () async {
    final dir = await Directory.systemTemp.createTemp('api_cache_member');
    final cache = HttpCache(directory: dir);
    var calls = 0;
    final client = build(
      MockClient((req) async {
        calls++;
        return ok({'name': 'me'});
      }),
      cache,
    );

    await client.get('/api/v3/member/info');
    await client.get('/api/v3/member/info');
    expect(calls, 2);

    await dir.delete(recursive: true);
  });

  test('连不上时回退到过期缓存，而不是抛错', () async {
    final dir = await Directory.systemTemp.createTemp('api_cache_fallback');
    final cache = HttpCache(directory: dir);
    var online = true;
    final client = build(
      MockClient((req) async {
        if (!online) throw const SocketException('网线被拔了');
        return ok({
          'list': [
            {'path_word': 'abc'}
          ]
        });
      }),
      cache,
    );

    await client.get('/api/v3/comics');
    // 模拟用户下拉刷新：缓存变「过期」，接着断网。
    cache.markAllStale();
    online = false;

    final fallback = await client.get('/api/v3/comics');
    expect(fallback['list'].first['path_word'], 'abc');
    expect(cache.lastStaleServedAt, isNotNull);

    await dir.delete(recursive: true);
  });

  test('业务错误不拿缓存掩盖（限流 / 需要登录要如实报错）', () async {
    final dir = await Directory.systemTemp.createTemp('api_cache_business');
    final cache = HttpCache(directory: dir);
    var fail = false;
    final client = build(
      MockClient((req) async {
        if (fail) {
          return http.Response(
            jsonEncode({'code': 210, 'message': '請下載安裝正版之後等待1小時'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return ok({'list': []});
      }),
      cache,
    );

    await client.get('/api/v3/comic2/abc');
    cache.markAllStale();
    fail = true;

    await expectLater(
      client.get('/api/v3/comic2/abc'),
      throwsA(isA<ApiException>()),
    );

    await dir.delete(recursive: true);
  });
}
