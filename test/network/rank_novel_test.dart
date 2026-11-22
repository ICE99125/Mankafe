import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 榜单 `/api/v3/ranks` 的真实口径（2026-11 实测）：
/// - `type=1` = 漫画榜，男频 / 女频靠 `audience_type=male|female` 分；
/// - `type=5` = 轻小说榜，条目内层是 `book`，18 条一页、`offset` 真分页；
/// - `type=2/3/4` 无效，之前把 2 当女频、把轻小说退化成热度列表都是错的。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}

class _RankHarness {
  late final Repository repo;
  final List<Map<String, String>> queries = [];

  _RankHarness() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState();
    final routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      if (request.url.path != '/api/v3/ranks') {
        return http.Response('{"code":200,"results":{}}', 200);
      }
      queries.add(request.url.queryParameters);
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
      final type = request.url.queryParameters['type'];
      final list = [
        for (var i = 0; i < 18 && offset + i < 165; i++)
          type == '5'
              ? {
                  'sort': offset + i + 1,
                  'popular': 500 - i,
                  'date_type': 1,
                  'book': {
                    'uuid': 'book-${offset + i}',
                    'path_word': 'book-${offset + i}',
                    'name': '輕小說${offset + i}',
                    'cover': '',
                    'author': [
                      {'name': '作者${offset + i}', 'path_word': 'a${offset + i}'}
                    ],
                  },
                }
              : {
                  'sort': offset + i + 1,
                  'popular': 500 - i,
                  'date_type': 2,
                  'comic': {
                    'uuid': 'comic-${offset + i}',
                    'path_word': 'comic-${offset + i}',
                    'name': '漫畫${offset + i}',
                    'cover': '',
                    'author': [
                      {'name': '作者${offset + i}', 'path_word': 'a${offset + i}'}
                    ],
                  },
                },
      ];
      return http.Response(
        jsonEncode({
          'code': 200,
          'message': '请求成功',
          'results': {
            'list': list,
            'total': 165,
            'limit': 18,
            'offset': offset
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('轻小说榜：type=5 + book 内层，18 条一页且 offset 能续页', () async {
    final h = _RankHarness();

    final first = await h.repo.rankPage(
      dateType: 'day',
      type: '5',
      audience: 'male',
      offset: 0,
      limit: 18,
    );
    expect(h.queries.first['type'], '5');
    expect(h.queries.first['date_type'], 'day');
    expect(h.queries.first['audience_type'], 'male');
    expect(h.queries.first['limit'], '18');
    expect(h.queries.first['offset'], '0');

    expect(first.kind, MediaKind.novel);
    expect(first.items.length, 18);
    expect(first.items.first.name, '輕小說0');
    expect(first.items.first.authorLabel, '作者0');
    expect(first.hasMore, isTrue, reason: 'total=165、18 条一页，必须还能续');

    final second = await h.repo.rankPage(
      dateType: 'day',
      type: '5',
      audience: 'male',
      offset: first.items.length,
      limit: 18,
    );
    expect(h.queries.last['offset'], '18');
    expect(second.items.first.name, '輕小說18');
    expect(second.hasMore, isTrue);
  });

  test('男频 / 女频都是漫画榜 type=1，只靠 audience_type 区分', () async {
    final h = _RankHarness();

    final male = await h.repo.rankPage(
      dateType: 'week',
      type: '1',
      audience: 'male',
      limit: 18,
    );
    expect(h.queries.last['type'], '1');
    expect(h.queries.last['audience_type'], 'male');
    expect(male.kind, MediaKind.comic);
    expect(male.items.first.name, '漫畫0');

    final female = await h.repo.rankPage(
      dateType: 'week',
      type: '1',
      audience: 'female',
      limit: 18,
    );
    expect(h.queries.last['type'], '1');
    expect(h.queries.last['audience_type'], 'female');
    expect(female.kind, MediaKind.comic);
  });
}
