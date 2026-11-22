import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/image_store.dart';

void main() {
  group('HttpCache：TTL 分级', () {
    final cache = HttpCache(directory: Directory.systemTemp);

    test('章节图片 / 正文缓存 7 天，是流量大头', () {
      expect(cache.ttlFor('/api/v3/comic/abc/chapter2/uuid'),
          const Duration(days: 7));
      expect(cache.ttlFor('/api/v3/post/uuid/chapter/cid'),
          const Duration(days: 7));
    });

    test('动画播放地址只缓存 30 分钟（m3u8 可能带时效签名）', () {
      expect(cache.ttlFor('/api/v3/cartoon/abc/chapter/uuid'),
          const Duration(minutes: 30));
      // 同一部动画的详情页仍然走 30 分钟，不受影响。
      expect(cache.ttlFor('/api/v3/cartoon/abc'), const Duration(minutes: 30));
    });

    test('章节目录 6 小时，详情 30 分钟，列表 10 分钟，评论 3 分钟', () {
      expect(cache.ttlFor('/api/v3/comic/abc/group/default/chapters'),
          const Duration(hours: 6));
      expect(cache.ttlFor('/api/v3/comic2/abc'), const Duration(minutes: 30));
      expect(cache.ttlFor('/api/v3/comics'), const Duration(minutes: 10));
      expect(cache.ttlFor('/api/v3/comments'), const Duration(minutes: 3));
    });

    test('登录态 / 写接口一律不缓存', () {
      expect(cache.ttlFor('/api/v3/member/collect/comics'), isNull);
      expect(cache.ttlFor('/api/v3/member/info'), isNull);
      expect(cache.ttlFor('/api/v3/login'), isNull);
      expect(cache.ttlFor('/api/v3/upload/image/1'), isNull);
    });
  });

  group('HttpCache：键与新鲜度', () {
    test('缓存键不含 host，换线路仍命中；查询参数排序后一致', () {
      final a = cacheKey('/api/v3/comics', {'limit': '21', 'offset': '0'});
      final b = cacheKey('/api/v3/comics', {'offset': '0', 'limit': '21'});
      expect(a, b);
      expect(a.contains('http'), isFalse);
    });

    test('新鲜期内命中；markAllStale 后不再算新鲜但可回退', () async {
      final dir = await Directory.systemTemp.createTemp('cache_test');
      var now = DateTime(2026, 11, 12, 10, 0, 0);
      final cache = HttpCache(directory: dir, clock: () => now);

      await cache.write(
          '/api/v3/comics',
          {
            'list': [1]
          },
          const Duration(minutes: 10));
      expect(await cache.readFresh('/api/v3/comics'), {
        'list': [1]
      });

      // 用户下拉刷新：水位线抬高，新鲜度失效。
      cache.markAllStale();
      expect(await cache.readFresh('/api/v3/comics'), isNull);
      // 但数据还在，弱网时能顶上。
      expect(await cache.readStale('/api/v3/comics'), {
        'list': [1]
      });

      await dir.delete(recursive: true);
    });

    test('超过 TTL 自动失效', () async {
      final dir = await Directory.systemTemp.createTemp('cache_ttl');
      var now = DateTime(2026, 11, 12, 10, 0, 0);
      final cache = HttpCache(directory: dir, clock: () => now);

      await cache.write('/api/v3/comics', 'x', const Duration(minutes: 10));
      now = now.add(const Duration(minutes: 9));
      expect(await cache.readFresh('/api/v3/comics'), 'x');
      now = now.add(const Duration(minutes: 2));
      expect(await cache.readFresh('/api/v3/comics'), isNull);

      await dir.delete(recursive: true);
    });

    test('超过 14 天的陈旧数据不再回退（旧章节地址没有意义）', () async {
      final dir = await Directory.systemTemp.createTemp('cache_stale');
      var now = DateTime(2026, 11, 1);
      final cache = HttpCache(directory: dir, clock: () => now);

      await cache.write('/api/v3/comics', 'x', const Duration(minutes: 1));
      now = now.add(const Duration(days: 15));
      expect(await cache.readStale('/api/v3/comics'), isNull);

      await dir.delete(recursive: true);
    });

    test('写入的内容能跨实例读回（真正落盘）', () async {
      final dir = await Directory.systemTemp.createTemp('cache_disk');
      final first = HttpCache(directory: dir);
      await first.write(
          '/api/v3/comic2/abc',
          {
            'comic': {'name': '测试'}
          },
          const Duration(hours: 1));

      // 新实例 = 冷启动，内存为空，只能从磁盘读。
      final second = HttpCache(directory: dir);
      expect(await second.readFresh('/api/v3/comic2/abc'), {
        'comic': {'name': '测试'}
      });

      await dir.delete(recursive: true);
    });

    test('并发写入一条都不能丢（目录初始化竞态回归）', () async {
      // 真机现象：首页那批请求并发到达，早期实现里只有第一个能拿到缓存目录，
      // 其余写入被静默丢弃，导致「有些接口第二次启动还在打网络」。
      final dir = await Directory.systemTemp.createTemp('cache_concurrent');
      final cache = HttpCache(directory: dir);

      await Future.wait([
        for (var i = 0; i < 12; i++)
          cache.write('/api/v3/list/$i', {'i': i}, const Duration(hours: 1)),
      ]);

      final cold = HttpCache(directory: dir);
      for (var i = 0; i < 12; i++) {
        expect(await cold.readFresh('/api/v3/list/$i'), {'i': i},
            reason: '第 $i 条被丢了');
      }

      await dir.delete(recursive: true);
    });

    test('clear 之后彻底读不到', () async {
      final dir = await Directory.systemTemp.createTemp('cache_clear');
      final cache = HttpCache(directory: dir);
      await cache.write('/api/v3/comics', 'x', const Duration(hours: 1));
      await cache.clear();
      expect(await cache.readFresh('/api/v3/comics'), isNull);
      expect(await cache.readStale('/api/v3/comics'), isNull);
      await dir.delete(recursive: true);
    });
  });

  group('ImageStore：图片磁盘缓存', () {
    test('存进去能读出来，且是同一份字节', () async {
      final dir = await Directory.systemTemp.createTemp('img_cache');
      final store = ImageStore(directory: dir);
      final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));

      expect(await store.load('https://x/a.jpg'), isNull);
      await store.save('https://x/a.jpg', bytes);
      expect(await store.load('https://x/a.jpg'), bytes);

      // 冷启动：新实例内存为空，从磁盘读回同样的内容。
      final cold = ImageStore(directory: dir);
      expect(await cold.load('https://x/a.jpg'), bytes);

      await dir.delete(recursive: true);
    });

    test('不同 URL 不会串图', () async {
      final dir = await Directory.systemTemp.createTemp('img_key');
      final store = ImageStore(directory: dir);
      await store.save('https://x/a.jpg', Uint8List.fromList([1, 2, 3]));
      expect(await store.load('https://x/b.jpg'), isNull);
      await dir.delete(recursive: true);
    });

    test('并发保存一条都不能丢', () async {
      final dir = await Directory.systemTemp.createTemp('img_concurrent');
      final store = ImageStore(directory: dir);

      await Future.wait([
        for (var i = 0; i < 12; i++)
          store.save('https://x/$i.jpg', Uint8List.fromList([i])),
      ]);

      final cold = ImageStore(directory: dir);
      for (var i = 0; i < 12; i++) {
        expect(await cold.load('https://x/$i.jpg'), [i], reason: '第 $i 张被丢了');
      }

      await dir.delete(recursive: true);
    });

    test('clear 之后读不到', () async {
      final dir = await Directory.systemTemp.createTemp('img_clear');
      final store = ImageStore(directory: dir);
      await store.save('https://x/a.jpg', Uint8List.fromList([1]));
      await store.clear();
      expect(await store.load('https://x/a.jpg'), isNull);
      await dir.delete(recursive: true);
    });

    test('预热与正式加载共用一次下载：同 URL 并发不重复打图床', () async {
      final dir = await Directory.systemTemp.createTemp('img_warm');
      var requests = 0;
      final client = MockClient((request) {
        requests++;
        return Future.value(http.Response('abcd', 200));
      });
      final store = ImageStore(directory: dir, client: client);
      const url = 'https://x/warm.jpg';
      await Future.wait<dynamic>([
        store.warm(url),
        store.get(url),
        store.get(url),
      ]).timeout(const Duration(seconds: 10));

      expect(requests, 1, reason: '预热 / 当前页 / 列表同一张图只能下一次');
      expect(await store.load(url), [97, 98, 99, 100],
          reason: '预热落盘的字节就是正式加载读到的那份');
      await dir.delete(recursive: true);
    });
  });
}

/// 用真实实例生成 key（与 ApiClient 内部一致）。
String cacheKey(String path, Map<String, String> query) =>
    HttpCache(directory: Directory.systemTemp).keyFor(path, query);
