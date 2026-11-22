import 'auth_signature.dart';
import 'device_profile.dart';

/// ApiEndpoints — 业务接口路径
class ApiEndpoints {
  ApiEndpoints._();

  // 系统 / 配置 / 线路
  static const String network2 = '/api/v3/system/network2';
  static const String systemConfig = '/api/v3/system/config/2020/3';
  static const String commentConfig = '/api/v3/comment/config';

  /// 应用自更新探测，返回各渠道版本信息，由客户端自行比较
  static const String appVersionLast = '/api/v3/system/appVersion/last';

  // 首页 / 聚合
  static const String homeIndex = '/api/v3/h5/homeIndex2';
  static const String cartoonIndex = '/api/v3/h5/cartoonIndex';
  static const String postIndex = '/api/v3/h5/postIndex';

  // 内容列表 / 榜单
  static const String comics = '/api/v3/comics';
  static const String books = '/api/v3/books';
  static const String cartoons = '/api/v3/cartoons';
  static const String posts = '/api/v3/posts';
  static const String recs = '/api/v3/recs';
  static const String ranks = '/api/v3/ranks';
  static const String updatesNewest = '/api/v3/update/newest';
  static const String updatesPostNewest = '/api/v3/update/post/newest';
  static const String topics = '/api/v3/topics';

  // 题材 / 标签，筛选值必须用 path_word
  static const String themeComicCount = '/api/v3/theme/comic/count';
  static const String themeBookCount = '/api/v3/theme/book/count';
  static const String themeCartoonCount = '/api/v3/theme/cartoon/count';
  static const String tagPostCount = '/api/v3/tag/post/count';

  // 专题
  static String topicDetail(String pathWord) => '/api/v3/topic/$pathWord';
  static String topicContents(String pathWord) =>
      '/api/v3/topic/$pathWord/contents';

  // 收藏列表（需登录）
  static const String collectComics = '/api/v3/member/collect/comics';
  static const String collectBooks = '/api/v3/member/collect/books';
  static const String collectPosts = '/api/v3/member/collect/posts';
  static const String collectCartoons = '/api/v3/member/collect/cartoons';

  // 浏览记录（需登录），四个分段各一个列表
  static const String browseComics = '/api/v3/member/browse/comics';
  static const String browseBooks = '/api/v3/member/browse/books';
  static const String browsePosts = '/api/v3/member/browse/posts';
  static const String browseCartoons = '/api/v3/member/browse/cartoons';

  // 收藏 / 取消收藏（需登录，POST），靠 is_collect=1/0 区分
  static const String collectComic = '/api/v3/member/collect/comic';
  static const String collectBook = '/api/v3/member/collect/book';
  static const String collectPost = '/api/v3/member/collect/post';
  static const String collectCartoon = '/api/v3/member/collect/cartoon';

  // 漫画详情 / 章节 / 图片
  static String comicDetail(String pathWord) => '/api/v3/comic2/$pathWord';
  static String chapters(String pathWord, String groupPathWord) =>
      '/api/v3/comic/$pathWord/group/$groupPathWord/chapters';
  static String chapterImages(String pathWord, String chapterUuid) =>
      '/api/v3/comic/$pathWord/chapter2/$chapterUuid';

  // 轻小说详情 / 卷 / 正文
  /// 详情内容在 results.book，卷列表为 {list,total,limit,offset}
  static String bookDetail(String pathWord) => '/api/v3/book/$pathWord';
  static String bookVolumes(String pathWord) =>
      '/api/v3/book/$pathWord/volumes';

  /// 卷正文在 results.volume.contents，txt_addr 为可选原文地址
  static String bookVolume(String pathWord, String volumeId) =>
      '/api/v3/book/$pathWord/volume/$volumeId';

  // 动画详情 / 剧集 / 播放
  static String cartoonDetail(String pathWord) => '/api/v3/cartoon/$pathWord';
  static String cartoonChapters(String pathWord) =>
      '/api/v3/cartoon/$pathWord/chapters';

  /// 播放地址在 results.chapter.video（HLS m3u8），line 选线路，需登录
  static String cartoonChapter(String pathWord, String chapterUuid) =>
      '/api/v3/cartoon/$pathWord/chapter/$chapterUuid';

  // 写真详情 / 章节 / 图片
  static String postDetail(String uuid) => '/api/v3/post/$uuid';
  static String postChapters(String uuid) => '/api/v3/post/$uuid/chapters';

  /// 图片列表在 results.chapter.contents，形如 [{url: "https://..."}]
  static String postChapter(String uuid, String chapterId) =>
      '/api/v3/post/$uuid/chapter/$chapterId';

  // 搜索 / 评论（只读）
  static const String searchComic = '/api/v3/search/comic';
  static const String searchBooks = '/api/v3/search/books';
  static const String searchCartoons = '/api/v3/search/cartoons';
  static const String searchPosts = '/api/v3/search/posts';
  static const String comments = '/api/v3/comments';
  static const String bookComments = '/api/v3/bookcomments';

  /// 章节吐槽，按 chapter_id（值为章节 uuid）做章节级聚合
  static const String roasts = '/api/v3/roasts';

  /// 发表评论（需登录）
  static const String memberComment = '/api/v3/member/comment';
  static const String memberBookComment = '/api/v3/member/bookcomment';

  /// 发表吐槽（需登录），正文 chapter_id（章节 uuid）+ roast + reply_id
  static const String memberRoast = '/api/v3/member/roast';

  // 登录 / 账号
  static const String login = '/api/v3/login';

  /// 注册（需未登录），字段与登录同源，另带可选 invite_code
  static const String register = '/api/v3/register';
  static const String memberInfo = '/api/v3/member/info';
  static const String memberUpdateInfo = '/api/v3/member/update/info';

  /// 图片上传（multipart，字段名 file），imgType 1 为头像
  static String uploadImage(int imgType) => '/api/v3/upload/image/$imgType';
}

/// 通用请求头，键名与取值对齐原版客户端
Map<String, String> apiHeaders({String? token}) {
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'user-agent': DeviceProfile.effectiveUserAgent,
    'accept': 'application/json',
    'content-type': 'application/x-www-form-urlencoded',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'source': DeviceProfile.source,
    'platform': '3',
    'version': DeviceProfile.effectiveVersion,
    'versionCode': DeviceProfile.effectiveVersionCode,
    'region': DeviceProfile.region,
    'webp': DeviceProfile.webp,
    'referer': DeviceProfile.effectiveReferer,
    'device': DeviceProfile.androidId,
    'deviceInfo': DeviceProfile.deviceInfo,
    'pseudoID': DeviceProfile.pseudoId,
    'umString': DeviceProfile.umString,
    'dt': DeviceProfile.dtHeader,
    'X-Auth-Timestamp': '$ts',
    'X-Auth-Signature': authSignature(
      tapString: DeviceProfile.tapString,
      timestampSeconds: ts,
    ),
    'authorization': 'Token ${token ?? ''}',
  };
}

/// 拼装完整 URL，容忍 baseUrl 末尾多写的 /
Uri apiUri(String baseUrl, String path, [Map<String, String>? query]) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final p = path.startsWith('/') ? path : '/$path';
  final uri = Uri.parse('$base$p');
  if (query == null || query.isEmpty) return uri;
  return uri.replace(queryParameters: {
    ...uri.queryParameters,
    ...query,
  });
}
