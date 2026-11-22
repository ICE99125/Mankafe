/// 离线下载的数据模型，索引存为一份 index.json
library;

/// DownloadedChapter — 一话已下载的章节
class DownloadedChapter {
  /// 漫画 uuid
  final String comicId;
  final String comicPathWord;
  final String comicName;

  /// 章节 uuid
  final String chapterId;
  final String chapterName;

  /// 图片张数
  final int imageCount;

  /// 章节序号，用于下载列表排序
  final int sort;

  /// 图片目录，相对下载根目录
  final String dir;

  /// 图片文件名，按页序排列
  final List<String> files;

  /// 下一话 / 上一话 uuid，离线连读用
  final String next;
  final String prev;

  /// 占用字节数
  final int bytes;

  /// 下载完成时间，ISO8601
  final String savedAt;

  const DownloadedChapter({
    required this.comicId,
    required this.comicPathWord,
    required this.comicName,
    required this.chapterId,
    required this.chapterName,
    this.imageCount = 0,
    this.sort = 0,
    required this.dir,
    this.files = const [],
    this.next = '',
    this.prev = '',
    this.bytes = 0,
    this.savedAt = '',
  });

  factory DownloadedChapter.fromJson(Map<String, dynamic> json) =>
      DownloadedChapter(
        comicId: (json['comic_id'] ?? '').toString(),
        comicPathWord: (json['comic_path_word'] ?? '').toString(),
        comicName: (json['comic_name'] ?? '').toString(),
        chapterId: (json['chapter_id'] ?? '').toString(),
        chapterName: (json['chapter_name'] ?? '').toString(),
        imageCount: _int(json['image_count']),
        sort: _int(json['sort']),
        dir: (json['dir'] ?? '').toString(),
        files: json['files'] is List
            ? (json['files'] as List).map((e) => e.toString()).toList()
            : const [],
        next: (json['next'] ?? '').toString(),
        prev: (json['prev'] ?? '').toString(),
        bytes: _int(json['bytes']),
        savedAt: (json['saved_at'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'comic_id': comicId,
        'comic_path_word': comicPathWord,
        'comic_name': comicName,
        'chapter_id': chapterId,
        'chapter_name': chapterName,
        'image_count': imageCount,
        'sort': sort,
        'dir': dir,
        'files': files,
        'next': next,
        'prev': prev,
        'bytes': bytes,
        'saved_at': savedAt,
      };

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// DownloadedComic — 我的下载里按漫画聚合的一组
class DownloadedComic {
  final String comicId;
  final String comicPathWord;
  final String comicName;
  final List<DownloadedChapter> chapters;

  const DownloadedComic({
    required this.comicId,
    required this.comicPathWord,
    required this.comicName,
    required this.chapters,
  });

  int get chapterCount => chapters.length;
  int get bytes => chapters.fold(0, (sum, c) => sum + c.bytes);

  /// 最近下载的一话，用于列表副标题
  DownloadedChapter? get latest {
    if (chapters.isEmpty) return null;
    return chapters
        .reduce((a, b) => a.savedAt.compareTo(b.savedAt) >= 0 ? a : b);
  }
}

/// 下载任务状态
enum DownloadStatus { queued, running, done, failed, canceled }

/// DownloadTask — 单个章节的下载进度
class DownloadTask {
  final String chapterId;
  final String chapterName;
  DownloadStatus status;
  int done;
  int total;
  String? error;

  DownloadTask({
    required this.chapterId,
    required this.chapterName,
    this.status = DownloadStatus.queued,
    this.done = 0,
    this.total = 0,
    this.error,
  });

  /// 0~1，总张数未知时为0
  double get progress {
    if (total <= 0) return 0;
    final value = done / total;
    return value > 1 ? 1 : value;
  }

  bool get isActive =>
      status == DownloadStatus.queued || status == DownloadStatus.running;
}
