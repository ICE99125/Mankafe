import 'package:flutter/foundation.dart';

import 'comic.dart';

/// BannerTarget — 轮播 type 对应的内容频道
enum BannerTarget { comic, animation, photo, external, unknown }

/// HomeBanner — 轮播项，comic 可能为 null
class HomeBanner {
  final String title;
  final String cover;
  final String subtitle;

  /// 点击轮播时使用的路由标识
  final String linkPathWord;

  /// 服务端下发的外链 id
  final String outUuid;

  /// 原始 type，决定点击后走哪个详情接口
  final String type;

  /// 可进入内容详情、且不是下载营销位的轮播
  bool get isContent =>
      target != BannerTarget.external &&
      target != BannerTarget.unknown &&
      routeId().isNotEmpty;

  BannerTarget get target => switch (type) {
        '1' => BannerTarget.comic,
        '5' => BannerTarget.animation,
        '130' => BannerTarget.photo,
        // 3 / 6 是下载或更新外链
        '3' || '6' => BannerTarget.external,
        _ => BannerTarget.unknown,
      };

  const HomeBanner({
    required this.title,
    required this.cover,
    this.subtitle = '',
    this.linkPathWord = '',
    this.outUuid = '',
    this.type = '',
  });

  /// 按频道决定跳转标识，都为空时返回空串
  String routeId({bool preferUuid = false}) {
    if (preferUuid && outUuid.isNotEmpty) return outUuid;
    if (linkPathWord.isNotEmpty) return linkPathWord;
    return outUuid;
  }

  factory HomeBanner.fromJson(Map<String, dynamic> json) {
    final comic = json['comic'];
    final comicName = comic is Map ? (comic['name'] ?? '').toString() : '';
    final brief = (json['brief'] ?? '').toString().trim();
    return HomeBanner(
      title: brief.isNotEmpty ? brief : comicName,
      cover: (json['cover'] ?? '').toString(),
      subtitle: comicName,
      linkPathWord: comic is Map ? (comic['path_word'] ?? '').toString() : '',
      outUuid: (json['out_uuid'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
    );
  }
}

/// HomeTopic — 首页专题横滑项
class HomeTopic {
  final String title;
  final String cover;
  final String period;
  final String pathWord;

  const HomeTopic({
    required this.title,
    required this.cover,
    this.period = '',
    this.pathWord = '',
  });

  factory HomeTopic.fromJson(Map<String, dynamic> json) => HomeTopic(
        title: (json['title'] ?? '').toString(),
        cover: (json['cover'] ?? '').toString(),
        period: (json['period'] ?? '').toString(),
        pathWord: (json['path_word'] ?? '').toString(),
      );
}

/// HomeIndex — 首页聚合数据
class HomeIndex {
  final List<HomeBanner> banners;
  final List<HomeTopic> topics;
  final List<Comic> recommend;
  final List<Comic> hot;
  final List<Comic> newest;
  final List<Comic> rankDay;
  final List<Comic> rankWeek;
  final List<Comic> rankMonth;
  final List<Comic> finish;

  const HomeIndex({
    this.banners = const [],
    this.topics = const [],
    this.recommend = const [],
    this.hot = const [],
    this.newest = const [],
    this.rankDay = const [],
    this.rankWeek = const [],
    this.rankMonth = const [],
    this.finish = const [],
  });

  factory HomeIndex.fromJson(Map<String, dynamic> json) {
    // 单项解析失败只丢这一条
    List<T> section<T>(String key, T Function(Map<String, dynamic>) build) {
      final out = <T>[];
      for (final entry in _items(json[key], key)) {
        try {
          out.add(build(entry));
        } catch (error) {
          if (kDebugMode) debugPrint('[homeIndex2] $key 单项解析失败: $error');
        }
      }
      return out;
    }

    List<Comic> comics(String key) => section(key, Comic.fromEntryJson)
        .where((c) => c.pathWord.isNotEmpty)
        .toList();

    return HomeIndex(
      banners: section('banners', HomeBanner.fromJson),
      topics: section('topics', HomeTopic.fromJson)
          .where((t) => t.cover.isNotEmpty)
          .toList(),
      recommend: comics('recComics'),
      hot: comics('hotComics'),
      newest: comics('newComics'),
      rankDay: comics('rankDayComics'),
      rankWeek: comics('rankWeekComics'),
      rankMonth: comics('rankMonthComics'),
      finish: comics('finishComics'),
    );
  }

  /// /api/v3/topics 的 results 转专题列表，坏条目只丢自己
  static List<HomeTopic> topicsFrom(dynamic results) {
    final out = <HomeTopic>[];
    for (final entry in _items(results, 'topics')) {
      try {
        final topic = HomeTopic.fromJson(entry);
        if (topic.cover.isNotEmpty) out.add(topic);
      } catch (error) {
        if (kDebugMode) debugPrint('[topics] 单项解析失败: $error');
      }
    }
    return out;
  }

  List<Comic> get pool {
    final seen = <String>{};
    final out = <Comic>[];
    for (final list in [recommend, hot, newest, rankWeek]) {
      for (final c in list) {
        if (seen.add(c.pathWord)) out.add(c);
      }
    }
    return out;
  }

  /// 兼容裸数组与 {list: [...]} 两种容器
  static List<Map<String, dynamic>> _items(dynamic node, [String key = '']) {
    final List<dynamic> raw = node is List
        ? node
        : node is Map && node['list'] is List
            ? node['list'] as List
            : const [];
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is Map) {
        out.add(Map<String, dynamic>.from(item));
      } else if (kDebugMode) {
        debugPrint('[homeIndex2] $key 跳过非对象条目: ${item.runtimeType}');
      }
    }
    return out;
  }
}
