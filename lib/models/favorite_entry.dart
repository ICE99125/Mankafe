import 'comic.dart';
import 'media_page.dart';

/// FavoriteEntry — 本地收藏条目，四个内容域共用
class FavoriteEntry {
  final String pathWord;
  final String uuid;
  final String name;
  final String? cover;
  final List<String> authors;
  final String lastChapter;
  final String updatedAt;

  /// 收藏所属内容类型，旧数据按漫画处理
  final MediaKind kind;

  /// 收藏时间（毫秒），列表按它倒序
  final int addedAt;

  const FavoriteEntry({
    required this.pathWord,
    this.uuid = '',
    this.name = '',
    this.cover,
    this.authors = const [],
    this.lastChapter = '',
    this.updatedAt = '',
    this.kind = MediaKind.comic,
    this.addedAt = 0,
  });

  factory FavoriteEntry.fromComic(
    Comic comic, {
    MediaKind kind = MediaKind.comic,
    int? addedAt,
  }) =>
      FavoriteEntry(
        pathWord: comic.pathWord,
        uuid: comic.uuid,
        name: comic.name,
        cover: comic.cover,
        authors: comic.authors,
        lastChapter: comic.lastChapter,
        updatedAt: comic.updatedAt,
        kind: kind,
        addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
      );

  /// 去重键：类型 + 标识
  String get key => '${kind.name}:$pathWord';

  /// 还原成 Comic，书架复用同一套卡片
  Comic toComic() => Comic(
        uuid: uuid,
        pathWord: pathWord,
        // 老数据没有名称时用 path_word 兜底
        name: name.isEmpty ? pathWord : name,
        cover: cover,
        authors: authors,
        lastChapter: lastChapter,
        updatedAt: updatedAt,
      );

  /// 用详情补全缺失字段，不覆盖已有非空值
  FavoriteEntry merge(Comic comic) => FavoriteEntry(
        pathWord: pathWord,
        uuid: uuid.isNotEmpty ? uuid : comic.uuid,
        name: comic.name.isNotEmpty ? comic.name : name,
        cover: comic.cover ?? cover,
        authors: comic.authors.isNotEmpty ? comic.authors : authors,
        lastChapter:
            comic.lastChapter.isNotEmpty ? comic.lastChapter : lastChapter,
        updatedAt: comic.updatedAt.isNotEmpty ? comic.updatedAt : updatedAt,
        kind: kind,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'path_word': pathWord,
        'uuid': uuid,
        'name': name,
        'cover': cover,
        'authors': authors,
        'last_chapter': lastChapter,
        'datetime_updated': updatedAt,
        'kind': kind.name,
        'added_at': addedAt,
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> json) => FavoriteEntry(
        pathWord: (json['path_word'] ?? '').toString(),
        uuid: (json['uuid'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        cover: json['cover'] is String ? json['cover'] as String : null,
        authors: json['authors'] is List
            ? (json['authors'] as List)
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList()
            : const [],
        lastChapter: (json['last_chapter'] ?? '').toString(),
        updatedAt: (json['datetime_updated'] ?? '').toString(),
        kind: _kindOf(json['kind']),
        addedAt: json['added_at'] is int ? json['added_at'] as int : 0,
      );

  static MediaKind _kindOf(dynamic raw) {
    final v = (raw ?? '').toString();
    for (final k in MediaKind.values) {
      if (k.name == v) return k;
    }
    return MediaKind.comic;
  }
}
