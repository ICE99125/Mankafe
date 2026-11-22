/// Chapter — 章节对象，对应 group/{group}/chapters 单条
class Chapter {
  final String uuid;
  final String name;
  final int index;
  final int size;
  final String createdAt;

  const Chapter({
    required this.uuid,
    required this.name,
    this.index = 0,
    this.size = 0,
    this.createdAt = '',
  });

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        uuid: (json['uuid'] ?? '').toString(),
        name: (json['name'] ?? '未命名章节').toString(),
        index: _int(json['index']),
        size: _int(json['size']),
        createdAt: (json['datetime_created'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'name': name,
        'index': index,
        'size': size,
        'datetime_created': createdAt,
      };

  static int _int(dynamic v) => v is int
      ? v
      : v is num
          ? v.toInt()
          : int.tryParse(v?.toString() ?? '') ?? 0;
}

/// ReadingResume — 续读目标，chapterUuid 为空视为不可用
class ReadingResume {
  final String chapterUuid;
  final String chapterName;

  const ReadingResume({required this.chapterUuid, this.chapterName = ''});

  bool get isUsable => chapterUuid.isNotEmpty;
}

/// ChapterGroup — comic2 的 groups 数组元素
class ChapterGroup {
  final String pathWord;
  final String name;
  final int count;

  const ChapterGroup({
    required this.pathWord,
    required this.name,
    this.count = 0,
  });

  factory ChapterGroup.fromJson(Map<String, dynamic> json) => ChapterGroup(
        pathWord: (json['path_word'] ?? 'default').toString(),
        name: (json['name'] ?? '默认分组').toString(),
        count: json['count'] is int ? json['count'] as int : 0,
      );
}

/// ComicImage — 章节图片，对应 chapter2 的 images 元素
class ComicImage {
  final String? url;
  final int width;
  final int height;
  final int index;

  const ComicImage({
    this.url,
    this.width = 800,
    this.height = 1200,
    this.index = 0,
  });

  factory ComicImage.fromJson(Map<String, dynamic> json, int fallbackIndex) =>
      ComicImage(
        url: json['url']?.toString(),
        width: json['width'] is int ? json['width'] as int : 800,
        height: json['height'] is int ? json['height'] as int : 1200,
        index: json['index'] is int ? json['index'] as int : fallbackIndex,
      );
}

/// ChapterContent — 章节图片列表与上下话
class ChapterContent {
  final String chapterUuid;
  final String name;
  final List<ComicImage> images;
  final String? next;
  final String? prev;

  const ChapterContent({
    required this.chapterUuid,
    required this.name,
    required this.images,
    this.next,
    this.prev,
  });

  factory ChapterContent.fromJson(Map<String, dynamic> json) {
    final chapter = json['chapter'];
    final chapterMap = chapter is Map
        ? Map<String, dynamic>.from(chapter)
        : const <String, dynamic>{};
    // 图片在 results.chapter.contents
    final raw = json['images'] ?? chapterMap['contents'];
    final images = <ComicImage>[];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] is Map) {
          images.add(
              ComicImage.fromJson(Map<String, dynamic>.from(raw[i] as Map), i));
        }
      }
    }
    return ChapterContent(
      chapterUuid: chapter is Map ? (chapter['uuid'] ?? '').toString() : '',
      name: chapter is Map ? (chapter['name'] ?? '章节').toString() : '章节',
      images: images,
      next: (json['next'] ?? chapterMap['next'])?.toString(),
      prev: (json['prev'] ?? chapterMap['prev'])?.toString(),
    );
  }
}

/// ComicComment — 评论条目
class ComicComment {
  final String id;

  /// 评论作者 id，用于判断是否显示删除
  final String userId;
  final String userName;
  final String avatar;
  final String content;
  final String createdAt;

  /// 回复总数（服务端 count）
  final int replyCount;

  /// 顶层为0，回复为父评论 id
  final String parentId;

  /// 被回复者昵称，仅回复行有值
  final String replyUserName;

  const ComicComment({
    required this.id,
    required this.userName,
    required this.content,
    this.userId = '',
    this.avatar = '',
    this.createdAt = '',
    this.replyCount = 0,
    this.parentId = '0',
    this.replyUserName = '',
  });

  /// 响应字段：正文叫 comment，回复数叫 count
  factory ComicComment.fromJson(Map<String, dynamic> json) => ComicComment(
        // 吐槽用 roast_id
        id: (json['id'] ?? json['comment_id'] ?? json['roast_id'] ?? '')
            .toString(),
        userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
        userName: (json['user_name'] ?? json['userName'] ?? '读者').toString(),
        avatar: (json['user_avatar'] ?? json['avatar'] ?? '').toString(),
        content: (json['comment'] ?? json['content'] ?? '').toString(),
        createdAt: (json['create_at'] ?? json['createdAt'] ?? '').toString(),
        replyCount:
            _int(json['count'] ?? json['reply_count'] ?? json['replyCount']),
        parentId: (json['parent_id'] ?? '0').toString(),
        replyUserName:
            (json['parent_user_name'] ?? json['reply_user_name'] ?? '')
                .toString(),
      );

  ComicComment copyWith({int? replyCount}) => ComicComment(
        id: id,
        userId: userId,
        userName: userName,
        avatar: avatar,
        content: content,
        createdAt: createdAt,
        replyCount: replyCount ?? this.replyCount,
        parentId: parentId,
        replyUserName: replyUserName,
      );

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  /// 字段名与 fromJson 一致
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'user_name': userName,
        'user_avatar': avatar,
        'comment': content,
        'create_at': createdAt,
        'count': replyCount,
        'parent_id': parentId,
        'parent_user_name': replyUserName,
      };
}

/// CommentPage — 评论一页，total 为服务端总数
class CommentPage {
  final List<ComicComment> items;
  final int total;

  /// 管理员关闭评论时禁用输入栏
  final bool closeComment;

  const CommentPage({
    required this.items,
    this.total = 0,
    this.closeComment = false,
  });

  bool get hasMore => items.length < total;
}
