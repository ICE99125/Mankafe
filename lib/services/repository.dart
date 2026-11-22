import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/app_version.dart';
import '../models/auth_user.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../models/content.dart';
import '../models/home_index.dart';
import '../models/media_page.dart';
import '../state/app_state.dart';
import '../utils/gbk_codec.dart';
import '../utils/paged_fetch.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'device_profile.dart';
import 'image_url.dart';
import 'route_manager.dart';

/// NotSignedInException — 未登录时访问书架抛出，页面引导去登录
class NotSignedInException implements Exception {
  const NotSignedInException();

  @override
  String toString() => '请先登录';
}

/// _CollectSnapshot — 账号收藏 id 快照，按 token 失效，附续读位置
class _CollectSnapshot {
  final Set<String> ids;
  final Map<String, ReadingResume> resume;
  final DateTime at;
  final String? token;

  _CollectSnapshot(this.ids, this.resume, this.at, this.token);
}

/// ComicDetailData — 漫画详情，漫画 + 章节分组 + 收藏状态
class ComicDetailData {
  final Comic comic;
  final List<ChapterGroup> groups;
  final bool isCollect;

  const ComicDetailData({
    required this.comic,
    required this.groups,
    this.isCollect = false,
  });
}

/// RecommendBatch — 推荐位一屏，total 为该推荐位总条数
class RecommendBatch {
  final List<Comic> items;
  final int total;
  final int offset;

  const RecommendBatch({
    required this.items,
    this.total = 0,
    this.offset = 0,
  });
}

/// Repository — 业务数据仓库，全部数据走线上 HTTPS 请求
class Repository {
  Repository(this._client, this._routes, this._settings);

  final ApiClient _client;
  final RouteManager _routes;
  final AppState _settings;

  /// 读超时12s，覆盖 TLS 握手 + 首页聚合26KB
  static const Duration liveTimeout = Duration(seconds: 12);

  Future<Map<String, dynamic>?> _getMap(
    String path, {
    Map<String, String>? query,
  }) async {
    final results = await _client.get(path, query: query, timeout: liveTimeout);
    return results is Map ? Map<String, dynamic>.from(results) : null;
  }

  static List<Map<String, dynamic>> _listOf(Map<String, dynamic>? results) {
    final raw = results?['list'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 封面基址，取自 network2 的 static；相对路径才用它拼 CDN
  String? get imageHost => _routes.network2?.cdn;

  static const int pageSize = 21;

  /// 写真一页18 条（三列 × 6 行）
  static const int photoPageSize = 18;

  // 首页 / 聚合

  /// GET /api/v3/h5/homeIndex2，query 仅 platform=3
  Future<HomeIndex> homeIndex() async {
    final results = await _getMap(
      ApiEndpoints.homeIndex,
      query: {'platform': '3'},
    );
    if (results == null) throw const ApiException('homeIndex2 响应为空');
    try {
      return HomeIndex.fromJson(results);
    } catch (error) {
      throw ApiFormatException('homeIndex2 数据格式异常：$error');
    }
  }

  /// GET /api/v3/h5/cartoonIndex，动画聚合页
  Future<Map<String, dynamic>> cartoonIndex() async {
    final results = await _getMap(ApiEndpoints.cartoonIndex);
    if (results == null) throw const ApiException('cartoonIndex 响应为空');
    return results;
  }

  /// GET /api/v3/h5/postIndex，写真聚合页
  Future<Map<String, dynamic>> postIndex() async {
    final results = await _getMap(ApiEndpoints.postIndex);
    if (results == null) throw const ApiException('postIndex 响应为空');
    return results;
  }

  /// 动画 / 写真聚合频道，把两个 h5 首页接口压成统一的 MediaIndex
  Future<MediaIndex> mediaIndex(MediaKind kind) async {
    final results = await _getMap(
      kind == MediaKind.animation
          ? ApiEndpoints.cartoonIndex
          : ApiEndpoints.postIndex,
    );
    if (results == null) throw const ApiException('聚合页响应为空');
    return MediaIndex.fromResults(results, kind);
  }

  /// 四类内容列表分页，排序 ordering=-datetime_updated|popular
  Future<MediaPage> mediaPage(
    MediaKind kind, {
    int offset = 0,
    bool popular = false,
  }) {
    final path = switch (kind) {
      MediaKind.comic => ApiEndpoints.comics,
      MediaKind.novel => ApiEndpoints.books,
      MediaKind.animation => ApiEndpoints.cartoons,
      MediaKind.photo => ApiEndpoints.posts,
    };
    return _fetchPage(kind, path, offset: offset, popular: popular);
  }

  /// 首页「热门更新」分页，GET /api/v3/update/newest
  Future<MediaPage> newestComics({int offset = 0}) async {
    final results = await _client.get(
      ApiEndpoints.updatesNewest,
      query: {'limit': '$pageSize', 'offset': '$offset'},
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      MediaKind.comic,
      results,
      offset: offset,
      fallbackLimit: pageSize,
    );
  }

  /// 写真「全新上架」，GET /api/v3/update/post/newest，date 服务端忽略
  Future<MediaPage> newestPosts({
    int offset = 0,
    int limit = photoPageSize,
  }) async {
    final results = await _client.get(
      ApiEndpoints.updatesPostNewest,
      query: {'date': '', 'limit': '$limit', 'offset': '$offset'},
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      MediaKind.photo,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 写真发现页列表，ordering 必须带负号才是降序
  Future<MediaPage> photoPage({
    String mannequin = '',
    String tag = '',
    String ordering = '-datetime_updated',
    int offset = 0,
    int limit = photoPageSize,
  }) async {
    // 固定带空 mannequin / tag 参数，且不带 free_type
    final results = await _client.get(
      ApiEndpoints.posts,
      query: {
        'mannequin': mannequin,
        'tag': tag,
        'ordering': ordering,
        'limit': '$limit',
        'offset': '$offset',
      },
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      MediaKind.photo,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 首页「已完结」换一批，GET /api/v3/comics?top=finish
  Future<MediaPage> finishedComics({int offset = 0, int limit = 6}) async {
    final results = await _client.get(
      ApiEndpoints.comics,
      query: {
        'limit': '$limit',
        'offset': '$offset',
        'free_type': '0',
        'ordering': '-datetime_updated',
        'top': 'finish',
      },
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      MediaKind.comic,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 漫画全集分页，ordering 原样透传，负号表示降序
  Future<MediaPage> comicPage({
    String ordering = 'popular',
    String theme = '',
    int offset = 0,
    int limit = 18,
  }) async {
    final results = await _client.get(
      ApiEndpoints.comics,
      query: {
        'limit': '$limit',
        'offset': '$offset',
        'ordering': ordering,
        if (theme.isNotEmpty) 'theme': theme,
      },
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      MediaKind.comic,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 专题列表，type 21 为动画新番专题，漫画专题不传
  Future<List<HomeTopic>> topics(
      {int offset = 0, int limit = 4, int? type}) async {
    final results = await _client.get(
      ApiEndpoints.topics,
      query: {
        'limit': '$limit',
        'offset': '$offset',
        if (type != null) 'type': '$type',
      },
      timeout: liveTimeout,
    );
    return HomeIndex.topicsFrom(results);
  }

  /// 轻小说 / 动画 / 写真搜索，漫画搜索走 mediaPage
  Future<MediaPage> searchMedia(
    MediaKind kind,
    String keyword, {
    int offset = 0,
  }) {
    if (kind == MediaKind.comic) {
      return mediaPage(kind, offset: offset);
    }
    final path = switch (kind) {
      MediaKind.novel => ApiEndpoints.searchBooks,
      MediaKind.animation => ApiEndpoints.searchCartoons,
      MediaKind.photo => ApiEndpoints.searchPosts,
      MediaKind.comic => ApiEndpoints.searchComic,
    };
    return _fetchPage(kind, path, offset: offset, keyword: keyword);
  }

  Future<MediaPage> _fetchPage(
    MediaKind kind,
    String path, {
    required int offset,
    bool popular = false,
    String? keyword,
  }) async {
    final q = keyword?.trim() ?? '';
    final results = await _client.get(path,
        query: {
          'limit': '$pageSize',
          'offset': '$offset',
          'ordering': popular ? 'popular' : '-datetime_updated',
          if (q.isNotEmpty) 'q': q,
          if (kind != MediaKind.photo) 'free_type': '0',
        },
        timeout: liveTimeout);
    return MediaPage.fromResults(
      kind,
      results,
      offset: offset,
      fallbackLimit: pageSize,
    );
  }

  /// 书架列表（需登录），limit 默认 pageSize
  Future<MediaPage> collectPage(
    MediaKind kind, {
    int offset = 0,
    int limit = pageSize,
  }) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    final path = switch (kind) {
      MediaKind.comic => ApiEndpoints.collectComics,
      MediaKind.novel => ApiEndpoints.collectBooks,
      MediaKind.photo => ApiEndpoints.collectPosts,
      MediaKind.animation => ApiEndpoints.collectCartoons,
    };
    final results = await _client.get(path,
        query: {
          'limit': '$limit',
          'offset': '$offset',
          'ordering': '-datetime_updated',
          if (kind != MediaKind.photo) 'free_type': '0',
        },
        timeout: liveTimeout);
    return MediaPage.fromResults(
      kind,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 收藏状态：账号收藏里是否已有该条目，结果缓存5 分钟
  Future<bool> collectContains(
    MediaKind kind,
    String id, {
    String fallbackId = '',
  }) async {
    if (!_settings.isLoggedIn || id.isEmpty) return false;
    final snapshot = await _collectSnapshotFor(kind);
    final ids = snapshot.ids;
    return ids.contains(id) ||
        (fallbackId.isNotEmpty && ids.contains(fallbackId));
  }

  /// 收藏里记录的「上次看到哪一话」，未登录返回 null
  Future<ReadingResume?> collectResume(
    MediaKind kind, {
    String uuid = '',
    required String pathWord,
  }) async {
    if (!_settings.isLoggedIn) return null;
    if (uuid.isEmpty && pathWord.isEmpty) return null;
    final snapshot = await _collectSnapshotFor(kind);
    ReadingResume? hit;
    if (uuid.isNotEmpty) hit = snapshot.resume[uuid];
    if (hit == null && pathWord.isNotEmpty) hit = snapshot.resume[pathWord];
    return (hit != null && hit.isUsable) ? hit : null;
  }

  static const Duration _collectCacheTtl = Duration(minutes: 5);

  /// 账号收藏 id 快照，uuid 与 path_word 都收，写真只有 uuid
  final Map<MediaKind, _CollectSnapshot> _collectSnapshots = {};

  Future<_CollectSnapshot> _collectSnapshotFor(MediaKind kind) async {
    final cached = _collectSnapshots[kind];
    if (cached != null &&
        cached.token == _settings.authToken &&
        DateTime.now().difference(cached.at) < _collectCacheTtl) {
      return cached;
    }
    final ids = <String>{};
    final resume = <String, ReadingResume>{};
    var truncated = false;
    const pageLimit = 100;
    for (var offset = 0; offset < 400; offset += pageLimit) {
      MediaPage page;
      try {
        page = await collectPage(kind, offset: offset, limit: pageLimit);
      } catch (_) {
        // 拉不动就用手上已有的判定，且不写缓存，避免把残缺当完整
        truncated = true;
        break;
      }
      for (final item in page.items) {
        final lastRead = item.browseChapterId.isNotEmpty
            ? ReadingResume(
                chapterUuid: item.browseChapterId,
                chapterName: item.browseChapterName,
              )
            : null;
        if (item.uuid.isNotEmpty) {
          ids.add(item.uuid);
          if (lastRead != null) resume[item.uuid] = lastRead;
        }
        if (item.pathWord.isNotEmpty) {
          ids.add(item.pathWord);
          if (lastRead != null) resume[item.pathWord] = lastRead;
        }
      }
      if (!page.hasMore) break;
    }
    final snapshot =
        _CollectSnapshot(ids, resume, DateTime.now(), _settings.authToken);
    if (!truncated) {
      _collectSnapshots[kind] = snapshot;
    }
    return snapshot;
  }

  /// 收藏 / 取消后同步快照，避免详情页图标回退
  void _rememberCollect(MediaKind kind, String id, bool collected) {
    final cached = _collectSnapshots[kind];
    if (cached == null || cached.token != _settings.authToken) return;
    if (collected) {
      cached.ids.add(id);
    } else {
      cached.ids.remove(id);
    }
  }

  static String _browsePath(MediaKind kind) => switch (kind) {
        MediaKind.comic => ApiEndpoints.browseComics,
        MediaKind.novel => ApiEndpoints.browseBooks,
        MediaKind.photo => ApiEndpoints.browsePosts,
        MediaKind.animation => ApiEndpoints.browseCartoons,
      };

  /// 浏览记录（需登录），未登录抛 NotSignedInException
  Future<MediaPage> browsePage(MediaKind kind, {int offset = 0}) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    final path = _browsePath(kind);
    final results = await _client.get(path,
        query: {
          'limit': '$pageSize',
          'offset': '$offset',
        },
        timeout: liveTimeout);
    return MediaPage.fromResults(
      kind,
      results,
      offset: offset,
      fallbackLimit: pageSize,
    );
  }

  /// 清空账号里某一类浏览记录，DELETE 同一路径
  Future<void> clearBrowse(MediaKind kind) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    await _client.delete(_browsePath(kind), timeout: liveTimeout);
  }

  /// 收藏 / 取消收藏（需登录），form body 带 is_collect=1/0 与按类型区分的 id 字段
  Future<void> setCollected(
    String id, {
    required bool collected,
    MediaKind kind = MediaKind.comic,
  }) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    if (id.isEmpty) return;
    final path = switch (kind) {
      MediaKind.comic => ApiEndpoints.collectComic,
      MediaKind.novel => ApiEndpoints.collectBook,
      MediaKind.photo => ApiEndpoints.collectPost,
      MediaKind.animation => ApiEndpoints.collectCartoon,
    };
    final idField = switch (kind) {
      MediaKind.comic => 'comic_id',
      MediaKind.novel => 'book_id',
      MediaKind.photo => 'post_id',
      MediaKind.animation => 'cartoon_id',
    };
    final results = await _client.postForm(
      path,
      timeout: liveTimeout,
      fields: {
        idField: id,
        'is_collect': collected ? '1' : '0',
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
    // 服务端偶发用 {success:false, error:"..."} 表达业务失败，HTTP 仍200
    if (results is Map && results['success'] == false) {
      final error = results['error'];
      throw ApiException(
          error is String && error.isNotEmpty ? error : '收藏操作失败');
    }
    _rememberCollect(kind, id, collected);
  }

  // 题材 / 标签 / 筛选 / 榜单
  /// 题材标签，写真走 tag/post/count，其余走 theme/*/count
  Future<List<ThemeTag>> themeTags(MediaKind kind) async {
    final path = switch (kind) {
      MediaKind.comic => ApiEndpoints.themeComicCount,
      MediaKind.novel => ApiEndpoints.themeBookCount,
      MediaKind.animation => ApiEndpoints.themeCartoonCount,
      MediaKind.photo => ApiEndpoints.tagPostCount,
    };
    final results = await _client.get(path, timeout: liveTimeout);
    return ThemeTag.listFrom(results);
  }

  /// 通用筛选结果页，query 值一律传 path_word；company / mannequin 只对应频道传
  Future<MediaPage> filteredPage(
    MediaKind kind, {
    String theme = '',
    String author = '',
    String parody = '',
    String tag = '',
    String company = '',
    String mannequin = '',
    String top = '',
    String ordering = '-datetime_updated',
    int offset = 0,
    int limit = pageSize,
  }) async {
    final path = switch (kind) {
      MediaKind.comic => ApiEndpoints.comics,
      MediaKind.novel => ApiEndpoints.books,
      MediaKind.animation => ApiEndpoints.cartoons,
      MediaKind.photo => ApiEndpoints.posts,
    };
    final results = await _client.get(path,
        query: {
          'limit': '$limit',
          'offset': '$offset',
          'ordering': ordering,
          if (theme.isNotEmpty) 'theme': theme,
          if (author.isNotEmpty) 'author': author,
          if (parody.isNotEmpty) 'parody': parody,
          if (tag.isNotEmpty) 'tag': tag,
          if (company.isNotEmpty) 'company': company,
          if (mannequin.isNotEmpty) 'mannequin': mannequin,
          if (top.isNotEmpty) 'top': top,
          if (kind != MediaKind.photo) 'free_type': '0',
        },
        timeout: liveTimeout);
    return MediaPage.fromResults(
      kind,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 榜单，type=1 漫画榜、type=5 轻小说榜；audience 只对漫画榜生效
  Future<MediaPage> rankPage({
    String dateType = 'week',
    String type = '1',
    String audience = 'male',
    int offset = 0,
    int limit = pageSize,
  }) async {
    final results = await _client.get(
      ApiEndpoints.ranks,
      query: {
        'type': type,
        'date_type': dateType,
        'audience_type': audience,
        'limit': '$limit',
        'offset': '$offset',
      },
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      type == '5' ? MediaKind.novel : MediaKind.comic,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  /// 推荐位「换一批」，pos 为按推荐位写死的槽位码，由服务端决定内容
  Future<RecommendBatch> recommendBatch({
    required String pos,
    int limit = 3,
    int offset = 0,
  }) async {
    final results = await _getMap(
      ApiEndpoints.recs,
      query: {
        'pos': pos,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    if (results == null) throw const ApiException('recs 响应为空');
    final raw = results['list'];
    final items = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => comicFromEntry(Map<String, dynamic>.from(e)))
            .whereType<Comic>()
            .toList()
        : <Comic>[];
    final total = int.tryParse('${results['total']}') ?? 0;
    return RecommendBatch(items: items, total: total, offset: offset);
  }

  /// 推荐分组，由首页推荐 + 人气 + 已完结三个接口聚合
  Future<List<RecommendGroup>> recommendations() async {
    final groups = <RecommendGroup>[];
    Object? lastError;

    try {
      final home = await homeIndex();
      if (home.recommend.isNotEmpty) {
        groups.add(RecommendGroup(title: '为你推荐', comics: home.recommend));
      }
    } catch (e) {
      lastError = e;
    }
    try {
      final popular = await comics(ordering: 'popular');
      if (popular.isNotEmpty) {
        groups.add(RecommendGroup(title: '人气作品', comics: popular));
      }
    } catch (e) {
      lastError = e;
    }
    try {
      final page = await finishedComics(limit: pageSize);
      if (page.items.isNotEmpty) {
        groups.add(RecommendGroup(title: '已完结精选', comics: page.items));
      }
    } catch (e) {
      lastError = e;
    }

    if (groups.isEmpty) {
      throw ApiException(lastError?.toString() ?? '推荐内容为空');
    }
    return groups;
  }

  Future<List<Comic>> comics({
    String theme = '',
    String ordering = 'updated',
    int offset = 0,
  }) async {
    final results = await _getMap(
      ApiEndpoints.comics,
      query: {
        'limit': '21',
        'offset': '$offset',
        'ordering': ordering == 'popular' ? 'popular' : '-datetime_updated',
        if (theme.isNotEmpty) 'theme': theme,
      },
    );
    if (results == null) throw const ApiException('comics 响应为空');
    return _listOf(results).map(Comic.fromJson).toList();
  }

  Future<List<Comic>> search(String keyword, {int offset = 0}) async {
    final results = await _getMap(
      ApiEndpoints.searchComic,
      query: {
        'format': 'json',
        'limit': '18',
        'offset': '$offset',
        'q': keyword,
      },
    );
    if (results == null) throw const ApiException('search 响应为空');
    return _listOf(results).map(Comic.fromJson).toList();
  }

  /// 发现页搜索分页，保留 total
  Future<MediaPage> searchPage(String keyword, {int offset = 0}) async {
    final results = await _getMap(
      ApiEndpoints.searchComic,
      query: {
        'format': 'json',
        'limit': '18',
        'offset': '$offset',
        'q': keyword,
      },
    );
    return MediaPage.fromResults(
      MediaKind.comic,
      results,
      offset: offset,
      fallbackLimit: 18,
    );
  }

  // 专题

  /// 专题详情，GET /api/v3/topic/{path_word}
  Future<TopicDetail> topicDetail(String pathWord) async {
    final results = await _getMap(ApiEndpoints.topicDetail(pathWord));
    if (results == null) throw const ApiException('专题详情响应为空');
    return TopicDetail.fromJson(results);
  }

  /// 专题内作品列表，支持分页；kind 由来源频道决定
  Future<MediaPage> topicContents(
    String pathWord, {
    MediaKind kind = MediaKind.comic,
    int offset = 0,
    int limit = pageSize,
  }) async {
    final results = await _client.get(
      ApiEndpoints.topicContents(pathWord),
      query: {'limit': '$limit', 'offset': '$offset'},
      timeout: liveTimeout,
    );
    return MediaPage.fromResults(
      kind,
      results,
      offset: offset,
      fallbackLimit: limit,
    );
  }

  // 漫画详情 / 章节 / 图片

  Future<ComicDetailData> detail(String pathWord) async {
    final results = await _getMap(ApiEndpoints.comicDetail(pathWord));
    if (results == null || results['comic'] is! Map) {
      throw const ApiException('comic2 响应为空');
    }
    final comic =
        Comic.fromJson(Map<String, dynamic>.from(results['comic'] as Map));
    final rawGroups = results['groups'];
    // groups 是 Map（key=分组 path_word），也兼容 List
    final groups = rawGroups is Map
        ? rawGroups.entries.where((e) => e.value is Map).map((e) {
            final m = Map<String, dynamic>.from(e.value as Map);
            m['path_word'] ??= e.key;
            return ChapterGroup.fromJson(m);
          }).toList()
        : rawGroups is List
            ? rawGroups
                .whereType<Map>()
                .map((e) => ChapterGroup.fromJson(Map<String, dynamic>.from(e)))
                .toList()
            : <ChapterGroup>[];
    final serverCollect = _collectStateOf(results);
    return ComicDetailData(
      comic: comic,
      groups: groups,
      // 收藏状态按登录态取：已登录只看服务端，未登录才看本地收藏；
      // 服务端没给时登录态回落到账号收藏列表做一次成员检查
      isCollect: serverCollect ??
          (_settings.isLoggedIn
              ? await collectContains(
                  MediaKind.comic,
                  comic.uuid.isNotEmpty ? comic.uuid : pathWord,
                  fallbackId: pathWord,
                )
              : _settings.isFavorite(pathWord)),
    );
  }

  /// 章节目录，服务端强制分页，单页上限100 且必须带 in_mainland=1
  Future<List<Chapter>> chapters(String pathWord,
      {String group = 'default'}) async {
    const pageSize = 100;

    return fetchAllPages<Chapter>(
      pageSize: pageSize,
      keyOf: (c) => c.uuid,
      fetchPage: (offset) async {
        final results = await _getMap(
          ApiEndpoints.chapters(pathWord, group),
          query: {
            'limit': '$pageSize',
            'offset': '$offset',
            'in_mainland': '1',
          },
        );
        if (results == null) throw const ApiException('chapters 响应为空');
        final rawTotal = results['total'];
        return PageResult(
          _listOf(results).map(Chapter.fromJson).toList(),
          rawTotal is int ? rawTotal : 0,
        );
      },
    );
  }

  Future<ChapterContent> chapterContent(
    String pathWord,
    String chapterUuid,
    List<Chapter> chapters,
  ) async {
    // 空 id 会拼成404 的地址，提前拦下
    if (chapterUuid.isEmpty) {
      throw const ApiException('缺少章节 id，已跳过章节请求');
    }
    final results = await _getMap(
      ApiEndpoints.chapterImages(pathWord, chapterUuid),
    );
    if (results == null) throw const ApiException('chapter2 响应为空');
    return ChapterContent.fromJson(results);
  }

  // 轻小说 / 动画 / 写真详情

  /// 三类详情，内容对象在 results.book / cartoon / post
  Future<ContentDetail> contentDetail(
    MediaKind kind,
    String pathWord, {
    bool withChapters = true,
  }) async {
    final path = switch (kind) {
      MediaKind.novel => ApiEndpoints.bookDetail(pathWord),
      MediaKind.animation => ApiEndpoints.cartoonDetail(pathWord),
      MediaKind.photo => ApiEndpoints.postDetail(pathWord),
      MediaKind.comic => ApiEndpoints.comicDetail(pathWord),
    };
    final results = await _getMap(path);
    if (results == null) throw const ApiException('详情响应为空');
    final key = switch (kind) {
      MediaKind.novel => 'book',
      MediaKind.animation => 'cartoon',
      MediaKind.photo => 'post',
      MediaKind.comic => 'comic',
    };
    final raw = results[key];
    if (raw is! Map) throw const ApiException('详情缺少内容对象');
    final body = Map<String, dynamic>.from(raw);
    final comic = Comic.fromJson(body);
    var chapters = <ContentChapter>[];
    var total = 0;
    if (withChapters) {
      try {
        final page = await contentChapters(kind, pathWord, limit: 100);
        chapters = page.$1;
        total = page.$2;
      } catch (_) {
        // 章节接口单独失败不影响详情主体展示
      }
    }
    // 收藏状态：服务端给了就用，没给则登录态回落到账号收藏列表
    final serverCollect = _collectStateOf(results);
    final isCollect = serverCollect ??
        (_settings.isLoggedIn
            ? await collectContains(
                kind,
                comic.uuid.isNotEmpty ? comic.uuid : pathWord,
                fallbackId: pathWord,
              )
            : _settings.isFavorite(pathWord, kind: kind));
    return ContentDetail(
      kind: kind,
      item: comic,
      raw: body,
      chapters: chapters,
      chapterTotal: total,
      isCollect: isCollect,
    );
  }

  /// 详情响应里的收藏状态：is_collect 优先，动画用 collect（null=未收藏）
  static bool? _collectStateOf(Map<String, dynamic> results) {
    final flag = results['is_collect'];
    if (flag is bool) return flag;
    if (results.containsKey('collect')) {
      final collect = results['collect'];
      if (collect == null) return false;
      if (collect is Map) return true;
    }
    return null;
  }

  /// 章 / 卷 / 集列表，四类路径各不相同
  Future<(List<ContentChapter>, int)> contentChapters(
    MediaKind kind,
    String pathWord, {
    int offset = 0,
    int limit = 100,
  }) async {
    final path = switch (kind) {
      MediaKind.novel => ApiEndpoints.bookVolumes(pathWord),
      MediaKind.animation => ApiEndpoints.cartoonChapters(pathWord),
      MediaKind.photo => ApiEndpoints.postChapters(pathWord),
      MediaKind.comic => ApiEndpoints.chapters(pathWord, 'default'),
    };
    final results = await _client.get(
      path,
      query: {
        'limit': '$limit',
        'offset': '$offset',
        if (kind == MediaKind.comic) 'in_mainland': '1',
      },
      timeout: liveTimeout,
    );
    final map = results is Map ? Map<String, dynamic>.from(results) : const {};
    final raw = map['list'];
    final list = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => ContentChapter.fromJson(Map<String, dynamic>.from(e)))
            .where((c) => c.id.isNotEmpty)
            .toList()
        : <ContentChapter>[];
    return (list, _asInt(map['total']));
  }

  /// 写真章节图片 / 轻小说卷正文，返回统一的 ContentPage 列表
  Future<List<ContentPage>> contentPages(
    MediaKind kind,
    String pathWord,
    String chapterId,
  ) async {
    // 与 chapterContent 同理，空章节 id 只会换来404
    if (chapterId.isEmpty) {
      throw const ApiException('缺少章节 id，已跳过正文请求');
    }
    final path = switch (kind) {
      MediaKind.photo => ApiEndpoints.postChapter(pathWord, chapterId),
      MediaKind.novel => ApiEndpoints.bookVolume(pathWord, chapterId),
      // 动画没有图片正文，播放地址走 animationPlay
      MediaKind.animation =>
        throw const ApiException('动画播放请使用 animationPlay()，正文接口不返回图片'),
      MediaKind.comic => ApiEndpoints.chapterImages(pathWord, chapterId),
    };
    final results = await _getMap(path);
    if (results == null) throw const ApiException('正文响应为空');
    final node = results['chapter'] ?? results['volume'] ?? results;
    final contents = node is Map ? node['contents'] : null;
    final pages = ContentPage.fromContents(contents);
    if (pages.isEmpty && node is Map) {
      // 部分章节把图片放在 contents 之外的字段里，兜底再找一次
      for (final key in ['images', 'image_list', 'urls', 'txt_addr']) {
        final v = node[key];
        final extra = ContentPage.fromContents(v is String ? [v] : v);
        if (extra.isNotEmpty) return extra;
      }
    }
    return pages;
  }

  /// 动画播放，地址在 results.chapter.video（HLS m3u8），是否可播由服务端决定
  Future<AnimationPlay> animationPlay(
    String pathWord,
    String chapterUuid, {
    String line = '',
  }) async {
    final results = await _client.get(
      ApiEndpoints.cartoonChapter(pathWord, chapterUuid),
      query: {if (line.isNotEmpty) 'line': line},
      timeout: liveTimeout,
    );
    if (results is! Map) throw const ApiException('播放响应为空');
    final node = results['chapter'];
    if (node is! Map) throw const ApiException('播放响应缺少 chapter');
    return AnimationPlay.fromJson(
      Map<String, dynamic>.from(node),
      line: line,
    );
  }

  /// 轻小说卷阅读，按 txt_addr 拉取正文并按 txt_encoding 解码
  Future<NovelVolume> novelVolume(String pathWord, String volumeId) async {
    final results = await _getMap(ApiEndpoints.bookVolume(pathWord, volumeId));
    if (results == null) throw const ApiException('卷正文响应为空');
    final node = results['volume'];
    if (node is! Map) throw const ApiException('卷响应缺少 volume');
    final volume = Map<String, dynamic>.from(node);
    final sections = volume['contents'] is List
        ? (volume['contents'] as List)
            .whereType<Map>()
            .map((e) => NovelSection.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.name.isNotEmpty)
            .toList()
        : <NovelSection>[];
    final encoding = (volume['txt_encoding'] ?? '').toString();
    final rawAddr = (volume['txt_addr'] ?? '').toString().trim();
    final addr = rawAddr.startsWith('http')
        ? rawAddr
        : resolveImageUrl(rawAddr, host: imageHost) ?? '';
    var text = '';
    if (addr.isNotEmpty) {
      final bytes = await _client.getBytes(addr, timeout: liveTimeout);
      text = decodeNovelText(bytes, encoding);
    } else {
      // 极少数卷把正文直接放在 contents[].content 里
      text = (volume['contents'] is List)
          ? (volume['contents'] as List)
              .whereType<Map>()
              .map((e) => (e['content'] ?? '').toString())
              .where((s) => s.trim().isNotEmpty)
              .join('\n\n')
          : '';
    }
    return NovelVolume(
      name: (volume['name'] ?? '').toString(),
      txtAddr: addr,
      encoding: encoding,
      sections: sections,
      text: text,
    );
  }

  // 评论 / 配置

  /// 漫画评论，顶层列表不能带 reply_id，否则只返回该评论的回复
  Future<CommentPage> commentsPage(
    String comicId, {
    int offset = 0,
    int limit = 20,
  }) async {
    final results = await _getMap(
      ApiEndpoints.comments,
      query: {
        'comic_id': comicId,
        'limit': '$limit',
        'offset': '$offset',
        'platform': '3',
      },
    );
    if (results == null) throw const ApiException('comments 响应为空');
    final items = _listOf(results).map(ComicComment.fromJson).toList();
    final rawTotal = results['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    final close = results['close_comment'] == true;
    if (kDebugMode) {
      debugPrint('[comments] comic=$comicId offset=$offset '
          'items=${items.length} total=$total close=$close');
    }
    return CommentPage(items: items, total: total, closeComment: close);
  }

  /// 一条评论的整棵回复树，服务端一次返回所有层级（扁平数组）
  Future<CommentPage> commentThread(
    String comicId,
    String replyId, {
    int limit = 100,
  }) async {
    final results = await _getMap(
      ApiEndpoints.comments,
      query: {
        'comic_id': comicId,
        'reply_id': replyId,
        'limit': '$limit',
        'offset': '0',
        'platform': '3',
      },
    );
    if (results == null) throw const ApiException('comments 响应为空');
    final items = _listOf(results).map(ComicComment.fromJson).toList();
    final rawTotal = results['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    if (kDebugMode) {
      debugPrint('[comments] thread root=$replyId items=${items.length} '
          'total=$total');
    }
    return CommentPage(items: items, total: total);
  }

  /// 只取第一页，详情页「读者留言」摘要用
  Future<List<ComicComment>> comments(String comicId) async =>
      (await commentsPage(comicId, limit: 3)).items;

  /// 发表评论（需登录），form body：comic_id + comment + reply_id
  Future<void> postComment(
    String comicId,
    String content, {
    String replyId = '',
  }) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    final text = content.trim();
    if (text.isEmpty) return;
    await _client.postForm(
      ApiEndpoints.memberComment,
      timeout: liveTimeout,
      fields: {
        'comic_id': comicId,
        'comment': text,
        'reply_id': replyId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  /// 删除自己发的评论 / 回复，参数放 form body：comic_id + comment_id
  Future<void> deleteComment(String comicId, String commentId) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    if (commentId.isEmpty) return;
    await _client.deleteForm(
      ApiEndpoints.memberComment,
      timeout: liveTimeout,
      fields: {
        'comic_id': comicId,
        'comment_id': commentId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  /// 删除自己发的章节吐槽，form body 带 chapter_id + roast_id
  Future<void> deleteRoast(String chapterId, String roastId) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    if (chapterId.isEmpty || roastId.isEmpty) return;
    await _client.deleteForm(
      ApiEndpoints.memberRoast,
      timeout: liveTimeout,
      fields: {
        'chapter_id': chapterId,
        'roast_id': roastId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  /// 设置页「服务端信息」，GET /api/v3/system/config/2020/3
  Future<Map<String, dynamic>?> systemConfig() async {
    try {
      return await _getMap(ApiEndpoints.systemConfig);
    } catch (_) {
      return null;
    }
  }

  /// 评论举报配置，GET /api/v3/comment/config
  Future<Map<String, dynamic>?> commentConfig() async {
    try {
      return await _getMap(ApiEndpoints.commentConfig);
    } catch (_) {
      return null;
    }
  }

  /// 章节吐槽，参数 chapter_id 的值是章节 uuid
  Future<CommentPage> roastsPage(
    String chapterUuid, {
    int offset = 0,
    int limit = 20,
  }) async {
    final results = await _getMap(
      ApiEndpoints.roasts,
      query: {
        'chapter_id': chapterUuid,
        'limit': '$limit',
        'offset': '$offset',
        'platform': '3',
      },
    );
    if (results == null) throw const ApiException('roasts 响应为空');
    final items = _listOf(results).map(ComicComment.fromJson).toList();
    final rawTotal = results['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    final close = results['close_roast'] == true;
    if (kDebugMode) {
      debugPrint('[roasts] chapter=$chapterUuid offset=$offset '
          'items=${items.length} total=$total close=$close');
    }
    return CommentPage(items: items, total: total, closeComment: close);
  }

  /// 只取第一页，章节吐槽摘要用
  Future<List<ComicComment>> roasts(String chapterUuid) async =>
      (await roastsPage(chapterUuid, limit: 3)).items;

  // 轻小说评论

  /// 轻小说评论，与漫画评论同构，对象参数为 book_id（uuid）
  Future<CommentPage> bookCommentsPage(
    String bookId, {
    int offset = 0,
    int limit = 20,
  }) async {
    final results = await _getMap(
      ApiEndpoints.bookComments,
      query: {
        'book_id': bookId,
        'limit': '$limit',
        'offset': '$offset',
        'platform': '3',
      },
    );
    if (results == null) throw const ApiException('bookcomments 响应为空');
    final items = _listOf(results).map(ComicComment.fromJson).toList();
    final rawTotal = results['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    final close = results['close_comment'] == true;
    if (kDebugMode) {
      debugPrint('[bookcomments] book=$bookId offset=$offset '
          'items=${items.length} total=$total close=$close');
    }
    return CommentPage(items: items, total: total, closeComment: close);
  }

  /// 轻小说某条评论的整棵回复树
  Future<CommentPage> bookCommentThread(
    String bookId,
    String replyId, {
    int limit = 100,
  }) async {
    final results = await _getMap(
      ApiEndpoints.bookComments,
      query: {
        'book_id': bookId,
        'reply_id': replyId,
        'limit': '$limit',
        'offset': '0',
        'platform': '3',
      },
    );
    if (results == null) throw const ApiException('bookcomments 响应为空');
    final items = _listOf(results).map(ComicComment.fromJson).toList();
    final rawTotal = results['total'];
    final total = rawTotal is num ? rawTotal.toInt() : items.length;
    if (kDebugMode) {
      debugPrint('[bookcomments] thread book=$bookId root=$replyId '
          'items=${items.length} total=$total');
    }
    return CommentPage(items: items, total: total);
  }

  /// 发表轻小说评论（需登录），form body：book_id + comment + reply_id
  Future<void> postBookComment(
    String bookId,
    String content, {
    String replyId = '',
  }) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    final text = content.trim();
    if (text.isEmpty) return;
    await _client.postForm(
      ApiEndpoints.memberBookComment,
      timeout: liveTimeout,
      fields: {
        'book_id': bookId,
        'comment': text,
        'reply_id': replyId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  /// 删除自己发的轻小说评论 / 回复，form body：book_id + comment_id
  Future<void> deleteBookComment(String bookId, String commentId) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    if (commentId.isEmpty) return;
    await _client.deleteForm(
      ApiEndpoints.memberBookComment,
      timeout: liveTimeout,
      fields: {
        'book_id': bookId,
        'comment_id': commentId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  /// 发表吐槽（需登录），form body：chapter_id + roast + reply_id
  Future<void> postRoast(
    String chapterUuid,
    String content, {
    String replyId = '',
  }) async {
    if (!_settings.isLoggedIn) throw const NotSignedInException();
    final text = content.trim();
    if (text.isEmpty) return;
    await _client.postForm(
      ApiEndpoints.memberRoast,
      timeout: liveTimeout,
      fields: {
        'chapter_id': chapterUuid,
        'roast': text,
        if (replyId.isNotEmpty) 'reply_id': replyId,
        ...DeviceProfile.formFields(
          authorization: 'Token ${_settings.authToken ?? ''}',
        ),
      },
    );
  }

  // 账号

  /// 设置页「新版本探测」，只读展示，不走缓存
  Future<AppVersionSnapshot> probeAppVersion() async {
    final results = await _client.get(
      ApiEndpoints.appVersionLast,
      timeout: const Duration(seconds: 12),
      useCache: false,
    );
    return AppVersionSnapshot.fromResults(results);
  }

  /// 代理设置变更后重建传输层，无需重启 app
  void refreshTransport() {
    _client.refreshTransport();
    _routes.refreshTransport();
  }

  /// 账号密码登录，password = base64(明文 + "-" + salt)，salt 独立提交
  Future<AuthUser> login(String username, String password) async {
    final salt = (100 + Random().nextInt(900)).toString();
    final encoded = base64Encode(utf8.encode('${password.trim()}-$salt'));
    final results = await _client.postForm(
      ApiEndpoints.login,
      timeout: const Duration(seconds: 25),
      fields: {
        'username': username.trim(),
        'password': encoded,
        'salt': salt,
        'platform': '3',
        'authorization': 'Token ',
        'version': DeviceProfile.effectiveVersion,
        'source': DeviceProfile.source,
        'region': DeviceProfile.region,
        'webp': DeviceProfile.webp,
        'userAgent': DeviceProfile.effectiveUserAgent,
        'isGoogle': DeviceProfile.isGoogle,
        'pseudoID': DeviceProfile.pseudoId,
        'dt': DeviceProfile.dtBody,
        'tapString': DeviceProfile.tapString,
        'umString': DeviceProfile.umString,
        'buildTime': DeviceProfile.buildTime,
        'versionCode': DeviceProfile.effectiveVersionCode,
        'androidId': DeviceProfile.androidId,
        'referer': DeviceProfile.effectiveReferer,
        'deviceInfo': DeviceProfile.deviceInfo,
      },
    );
    if (results is! Map) throw const ApiException('登录响应为空');
    final map = Map<String, dynamic>.from(results);
    final token = (map['token'] ?? '').toString().trim();
    if (token.isEmpty) throw const ApiException('登录响应缺少 token');
    final rawUser = map['user'];
    final user = rawUser is Map
        ? AuthUser.fromJson(Map<String, dynamic>.from(rawUser))
        : AuthUser.fromJson(map);
    await _settings.saveSession(token, user);
    return user;
  }

  /// 注册，密码变换与登录一致；成功后不写登录态
  Future<void> register({
    required String username,
    required String password,
    String inviteCode = '',
  }) async {
    final salt = (100 + Random().nextInt(900)).toString();
    final encoded = base64Encode(utf8.encode('${password.trim()}-$salt'));
    final invite = inviteCode.trim();
    await _client.postForm(
      ApiEndpoints.register,
      timeout: const Duration(seconds: 25),
      fields: {
        'username': username.trim(),
        'password': encoded,
        'salt': salt,
        if (invite.isNotEmpty) 'invite_code': invite,
        ...DeviceProfile.formFields(),
      },
    );
  }

  /// 上传头像，multipart 字段名 file
  Future<String> uploadAvatar({
    required List<int> bytes,
    required String filename,
  }) async {
    final results = await _client.postMultipart(
      ApiEndpoints.uploadImage(1),
      field: 'file',
      bytes: bytes,
      filename: filename,
    );
    final path = results is String
        ? results.trim()
        : (results is Map
            ? (results['path'] ?? results['url'] ?? results['avatar_rp'] ?? '')
                .toString()
            : '');
    if (path.isEmpty) {
      throw const ApiException('上传成功但未返回图片路径');
    }
    return path;
  }

  /// 修改昵称 / 性别 / 头像（JSON，需登录）
  Future<AuthUser> updateProfile({
    String? nickname,
    int? gender,
    String? avatar,
  }) async {
    final current = _settings.authUser;
    if (current == null) throw const AuthExpiredException();
    final results = await _client.post(
      ApiEndpoints.memberUpdateInfo,
      body: {
        if (nickname != null) 'nickname': nickname,
        if (gender != null) 'gender': gender,
        if (avatar != null) 'avatar': avatar,
      },
    );
    if (results is Map && results['success'] == false) {
      final error = results['error'];
      throw ApiException(
          error is String && error.isNotEmpty ? error : '资料更新失败');
    }
    final updated = current.copyWith(
      nickname: nickname,
      gender: gender,
      avatar: avatar,
    );
    await _settings.updateAuthUser(updated);
    return updated;
  }

  /// 退出登录，只清本地登录态
  Future<void> logout() => _settings.clearSession();

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
