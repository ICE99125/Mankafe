import 'package:flutter_test/flutter_test.dart';

import 'package:mankafe/services/device_profile.dart';
import 'package:mankafe/widgets/net_image.dart';

import 'package:mankafe/models/comic.dart';
import 'package:mankafe/models/content.dart';
import 'package:mankafe/models/home_index.dart';
import 'package:mankafe/models/media_page.dart';
import 'package:mankafe/utils/paged_fetch.dart';

/// 这两个 fixture 直接照抄线上 `/api/v3/h5/cartoonIndex` 与
/// `/api/v3/h5/postIndex` 的真实容器形态：
///   - banners / tags / ordering / newPosts 是裸数组
///   - topics / recCartoons / rankWeekPosts / rankMonthPosts 是
///     `{list, total, limit, offset}` 信封
/// 早期实现只认裸数组，导致专题和所有推荐 / 榜单一块都渲染不出来。
Map<String, dynamic> cartoonIndexFixture() => {
      'banners': [
        {
          'type': '5',
          'cover': 'https://s3.mangafunb.fun/recommend/a.jpg',
          'brief': '黑色五葉草第二季',
          'out_uuid': 'abffa9e3-b13f-11f1',
          'comic': {
            'name': '黑色五葉草第二季',
            'path_word': 'blackclover2ndseason',
          },
        },
      ],
      'topics': {
        'list': [
          {
            'title': '2026年10月秋季新番動畫',
            'cover': 'https://s3.mangafunb.fun/topic/x.jpg',
            'period': '',
            'path_word': 'xinfandonghua2610',
            'datetime_created': '2026-10-13',
          },
        ],
        'total': '11',
        'limit': '4',
        'offset': '0',
      },
      'recCartoons': {
        'list': [
          {
            'type': '5',
            'comic': {
              'path_word': 'tenseigoblindakedoshitsumonaru',
              'name': '轉生哥布林有問題嗎？',
              'cover': 'https://st.mangafunb.fun/t/a.jpg',
            },
          },
        ],
        'total': '63',
        'limit': '3',
        'offset': '0',
      },
      'tags': [
        {
          'initials': '16',
          'name': '奇幻',
          'path_word': 'qihuan',
          'count': '247',
        },
      ],
      'ordering': [
        {'name': '更新時間', 'path_word': 'datetime_updated'},
        {'name': '熱度', 'path_word': 'popular'},
      ],
    };

Map<String, dynamic> postIndexFixture() => {
      'rankWeekPosts': {
        'list': [
          {
            'sort': '1',
            'popular': '34',
            'date_type': '2',
            'post': {
              'uuid': '2079',
              'name': '【越南coser】Byoru-甘雨奶牛比基尼',
              'cover': 'https://s3.mangafunb.fun/post/a.jpg',
            },
          },
        ],
        'total': '43',
        'limit': '6',
        'offset': '0',
      },
      'rankMonthPosts': {
        'list': [
          {
            'popular': '583',
            'post': {
              'uuid': '1721',
              'name': '【越南coser】Tiny Asa-米塔',
              'cover': 'https://s3.mangafunb.fun/post/b.jpg',
            },
          },
        ],
        'total': '199',
        'limit': '6',
        'offset': '0',
      },
      'newPosts': [
        {
          'name': '全一集',
          'datetime_created': '2026-11-10 18:09:28',
          'post': {
            'uuid': '2090',
            'name': '【2026年11月獨家】FangLin-流螢',
            'cover': 'https://s3.mangafunb.fun/post/c.jpg',
          },
        },
      ],
      'banners': [
        {
          'type': '130',
          'cover': 'https://s3.mangafunb.fun/recommend/p.jpg',
          'brief': 'Byoru-飛霄',
          'out_uuid': '2020',
          'comic': {'name': 'Byoru-飛霄', 'path_word': '2020'},
        },
      ],
    };

void main() {
  test('cartoonIndex：{list} 信封里的 topics / recCartoons 必须解析出来', () {
    final index =
        MediaIndex.fromResults(cartoonIndexFixture(), MediaKind.animation);

    expect(index.kind, MediaKind.animation);
    expect(index.banners.length, 1);
    // 动画轮播的 comic.path_word 实测可直接打 /api/v3/cartoon/{path_word}。
    expect(index.banners.first.linkPathWord, 'blackclover2ndseason');
    expect(index.banners.first.routeId(), 'blackclover2ndseason');

    expect(index.topics.length, 1);
    expect(index.topics.first.pathWord, 'xinfandonghua2610');

    expect(index.tags.length, 1);
    expect(index.tags.first.pathWord, 'qihuan');
    expect(index.tags.first.count, 247); // 服务端给的是字符串

    expect(index.orderings.map((o) => o.pathWord),
        ['datetime_updated', 'popular']);

    final rec = index.groups.where((g) => g.key == 'recCartoons').toList();
    expect(rec.length, 1);
    expect(rec.first.title, '动画推荐');
    expect(rec.first.total, 63);
    expect(rec.first.items.length, 1);
    expect(rec.first.items.first.pathWord, 'tenseigoblindakedoshitsumonaru');
    expect(rec.first.items.first.cover, 'https://st.mangafunb.fun/t/a.jpg');

    // 元数据区块不能被当成内容分组。
    expect(index.groups.map((g) => g.key),
        isNot(containsAll(['banners', 'topics', 'tags', 'ordering'])));
  });

  test('postIndex：榜单 {list} 信封与 newPosts 裸数组都要变成真实条目', () {
    final index = MediaIndex.fromResults(postIndexFixture(), MediaKind.photo);

    expect(index.banners.length, 1);
    expect(index.banners.first.routeId(), '2020');
    expect(index.topics, isEmpty);
    expect(index.tags, isEmpty);
    expect(index.orderings, isEmpty);

    expect(index.groups.length, 3);
    final keys = index.groups.map((g) => g.key).toSet();
    expect(keys, {'rankWeekPosts', 'rankMonthPosts', 'newPosts'});

    final week = index.groups.firstWhere((g) => g.key == 'rankWeekPosts');
    expect(week.title, '写真周榜');
    expect(week.total, 43);
    // 写真条目没有 path_word，必须退化成 uuid 才能打开 /api/v3/post/{uuid}。
    expect(week.items.single.pathWord, '2079');
    expect(week.items.single.name, '【越南coser】Byoru-甘雨奶牛比基尼');
    expect(week.items.single.popular, 34);

    final newest = index.groups.firstWhere((g) => g.key == 'newPosts');
    expect(newest.items.single.pathWord, '2090');
    expect(newest.items.single.updatedAt, '2026-11-10 18:09:28');
  });

  test('轮播 type 决定真实详情频道，下载/更新外链必须被排除', () {
    HomeBanner banner(String type, {Map<String, dynamic>? comic}) =>
        HomeBanner.fromJson({
          'type': type,
          'cover': 'https://s3.mangafunb.fun/recommend/x.jpg',
          'brief': '标题',
          'out_uuid': 'https://www.manga2026.xyz/download',
          'comic': comic,
        });

    // homeIndex2 实测：1 漫画、130 写真；cartoonIndex 实测：5 动画。
    final comic = banner('1', comic: {'name': '魂環', 'path_word': 'hunhuan'});
    expect(comic.target, BannerTarget.comic);
    expect(comic.isContent, isTrue);
    expect(comic.routeId(), 'hunhuan');

    final animation = banner('5',
        comic: {'name': '黑色五葉草第二季', 'path_word': 'blackclover2ndseason'});
    expect(animation.target, BannerTarget.animation);
    expect(animation.isContent, isTrue);

    final photo = banner('130', comic: {'name': 'Byoru', 'path_word': '2020'});
    expect(photo.target, BannerTarget.photo);
    expect(photo.isContent, isTrue);
    expect(photo.routeId(), '2020');

    // 服务端下发的「下载 / 更新至最新版」轮播：comic 为 null，不做跳转。
    for (final type in ['3', '6']) {
      final external = banner(type);
      expect(external.target, BannerTarget.external);
      expect(external.isContent, isFalse);
    }
    expect(banner('999').target, BannerTarget.unknown);
    expect(banner('999').isContent, isFalse);
  });

  test('Comic 保留与中文名同序的 theme/author path_word', () {
    final comic = Comic.fromJson({
      'name': '魂環',
      'path_word': 'hunhuan',
      'theme': [
        {'name': '愛情', 'path_word': 'aiqing'},
        {'name': '奇幻', 'path_word': 'qihuan'},
      ],
      'author': [
        {'name': 'AliceCrazy', 'path_word': 'AliceCrazy'},
      ],
    });
    expect(comic.themes, ['愛情', '奇幻']);
    expect(comic.themeWords, ['aiqing', 'qihuan']);
    expect(comic.authors, ['AliceCrazy']);
    expect(comic.authorWords, ['AliceCrazy']);

    // 旧接口偶尔给纯字符串数组：展示有值，但没有可筛选的 path_word。
    final legacy = Comic.fromJson({
      'name': '旧条目',
      'path_word': 'old',
      'theme': ['愛情'],
    });
    expect(legacy.themes, ['愛情']);
    expect(legacy.themeWords, ['']);
  });

  test('ContentDetail.tags 兼容 company 单对象与 mannequins 数组', () {
    final detail = ContentDetail(
      kind: MediaKind.animation,
      item: Comic.fromJson({'name': 'x', 'path_word': 'x'}),
      raw: {
        'company': {'name': 'P.A.WORKS', 'path_word': 'paworks'},
        'mannequins': [
          {'name': 'FangLin', 'path_word': 'FangLin'},
        ],
        'parodies': null,
      },
    );
    expect(detail.tags('company').single.pathWord, 'paworks');
    expect(detail.tags('mannequins').single.pathWord, 'FangLin');
    expect(detail.tags('parodies'), isEmpty);
  });

  test('AnimationPlay：lines 是对象形态，video 为空表示该线路没配地址', () {
    // 实测 /cartoon/{p}/chapter/{uuid} 带 Token 的真实结构。
    final play = AnimationPlay.fromJson({
      'count': 6,
      'name': '第01集',
      'cover': '',
      'vid': null,
      'video': 'https://vd77.example.xyz/videos/x/hls.m3u8',
      'uuid': '83ceccfb-c1b2-11f1-82db-fa163e02432f',
      'lines': {
        'line1': {'name': '線路一', 'path_word': 'line1', 'config': false},
        'line2': {'name': '線路二', 'path_word': 'line2', 'config': false},
        'line3': {'name': '線路三', 'path_word': 'line3', 'config': true},
      },
    });

    expect(play.hasVideo, isTrue);
    expect(play.count, 6);
    expect(play.lines.map((l) => l.pathWord), ['line1', 'line2', 'line3']);
    // 不传 line 时服务端给默认线路，config=true 的那条即当前线路。
    expect(play.activeLine?.pathWord, 'line3');

    final noVideo = AnimationPlay.fromJson({
      'name': '第01集',
      'video': null,
      'lines': {
        'line1': {'name': '線路一', 'path_word': 'line1', 'config': false},
      },
    }, line: 'line1');
    expect(noVideo.hasVideo, isFalse);
    expect(noVideo.activeLine?.pathWord, 'line1');
  });

  test('ContentChapter：剧集列表的 lines 是数组，同样解析成 AnimationLine', () {
    final chapter = ContentChapter.fromJson({
      'name': '第01集',
      'uuid': '83ceccfb-c1b2-11f1-82db-fa163e02432f',
      'v_cover': '',
      'lines': [
        {'name': '線路三', 'path_word': 'line3', 'config': true},
      ],
    });
    expect(chapter.lines.single.name, '線路三');
    expect(chapter.lines.single.configured, isTrue);
  });

  test('线路可用性：只有 config:false 才禁用，缺 config 字段不算不可用', () {
    // 实测播放接口：未配置的线路是显式 `config: false`（点了也没有地址）。
    final lines = AnimationLine.listFrom({
      'line1': {'name': '線路一', 'path_word': 'line1', 'config': false},
      'line2': {'name': '線路二', 'path_word': 'line2', 'config': false},
      'line3': {'name': '線路三', 'path_word': 'line3', 'config': true},
      'line4': {'name': '線路四', 'path_word': 'line4'},
    });
    expect(lines.map((l) => l.usable).toList(), [false, false, true, true]);
    expect(lines[3].configured, isFalse);
    expect(lines[3].configKnown, isFalse);
  });

  test('图片请求头：图床要求 referer / user-agent，不能为空', () {
    // 实测 st.mangafunb.fun 的封面：不带 referer / user-agent 直接返回错误，
    // 带上就是 200。缺了这两个头，列表里就会出现「有些图一直出不来」。
    expect(imageHeaders['referer'], isNotEmpty);
    expect(imageHeaders['user-agent'], isNotEmpty);
    expect(imageHeaders['referer'], DeviceProfile.referer);
    expect(imageHeaders['user-agent'], DeviceProfile.userAgent);
  });

  test('聚合页对空 / 脏响应不抛异常，也不产出伪分组', () {
    final index = MediaIndex.fromResults(<String, dynamic>{
      'banners': 'bad',
      'topics': {'list': 'bad'},
      'ordering': [
        {'name': '无 path_word'},
      ],
      'unknown': [
        {'post': null, 'comic': null, 'name': ''},
      ],
    }, MediaKind.photo);

    expect(index.banners, isEmpty);
    expect(index.topics, isEmpty);
    expect(index.orderings, isEmpty);
    expect(index.groups, isEmpty);
  });

  group('章节目录翻页（服务端强制 limit=100）', () {
    /// 造一个「总量 total、每页最多 pageSize 条」的假上游。
    Future<PageResult<String>> Function(int) upstream(
      int total, {
      int pageSize = 100,
      bool ignoreOffset = false,
    }) {
      return (offset) async {
        final start = ignoreOffset ? 0 : offset;
        final end = (start + pageSize).clamp(0, total);
        return PageResult(
          [for (var i = start; i < end; i++) 'c$i'],
          total,
        );
      };
    }

    test('103 话分两页拉全，不会只剩前 100 话', () async {
      final got = await fetchAllPages<String>(
        fetchPage: upstream(103),
        keyOf: (e) => e,
      );
      expect(got.length, 103);
      expect(got.first, 'c0');
      expect(got.last, 'c102');
    });

    test('279 话分三页拉全', () async {
      final got = await fetchAllPages<String>(
        fetchPage: upstream(279),
        keyOf: (e) => e,
      );
      expect(got.length, 279);
    });

    test('恰好 100 话只请求一次', () async {
      var calls = 0;
      final got = await fetchAllPages<String>(
        fetchPage: (offset) {
          calls++;
          return upstream(100)(offset);
        },
        keyOf: (e) => e,
      );
      expect(got.length, 100);
      expect(calls, 1);
    });

    test('上游忽略 offset 时按 key 去重并立即收手（不会死循环）', () async {
      var calls = 0;
      final got = await fetchAllPages<String>(
        fetchPage: (offset) {
          calls++;
          return upstream(500, ignoreOffset: true)(offset);
        },
        keyOf: (e) => e,
      );
      expect(got.length, 100, reason: '重复页不能重复追加');
      expect(calls, 2, reason: '第二页全是重复，应立刻停');
    });

    test('total 为 0 的空目录不会发第二轮', () async {
      var calls = 0;
      final got = await fetchAllPages<String>(
        fetchPage: (offset) {
          calls++;
          return upstream(0)(offset);
        },
        keyOf: (e) => e,
      );
      expect(got, isEmpty);
      expect(calls, 1);
    });
  });
}
