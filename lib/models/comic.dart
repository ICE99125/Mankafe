/// Comic — 漫画实体，对应接口 results 单条
class Comic {
  final String uuid;
  final String pathWord;
  final String name;
  final String alias;
  final String? cover;
  final List<String> authors;
  final List<String> themes;

  /// 与 themes/authors 逐项对应的 path_word，空串表示该项不可点击
  final List<String> themeWords;
  final List<String> authorWords;
  final String status;
  final String region;
  final int popular;
  final String updatedAt;
  final String lastChapter;
  final String brief;
  final int chapterCount;
  final int sort;
  final int riseSort;

  /// 最新章节 id 与上次阅读章节 id，不一致视为有更新
  final String lastChapterId;
  final String browseChapterId;

  /// 上次看到哪一话的展示名，空串表示服务端没给
  final String browseChapterName;

  const Comic({
    required this.uuid,
    required this.pathWord,
    required this.name,
    this.alias = '',
    this.cover,
    this.authors = const [],
    this.themes = const [],
    this.themeWords = const [],
    this.authorWords = const [],
    this.status = 'ongoing',
    this.region = 'jp',
    this.popular = 0,
    this.updatedAt = '',
    this.lastChapter = '',
    this.brief = '',
    this.chapterCount = 0,
    this.sort = 0,
    this.riseSort = 0,
    this.lastChapterId = '',
    this.browseChapterId = '',
    this.browseChapterName = '',
  });

  factory Comic.fromJson(Map<String, dynamic> json) {
    final last = json['last_chapter'];
    final browse = json['browse'];
    return Comic(
      uuid: _str(json['uuid']),
      pathWord: _str(json['path_word']),
      name: _str(json['name'], fallback: '未命名漫画'),
      alias: _str(json['alias']),
      cover: json['cover'] is String ? json['cover'] as String : null,
      authors: _names(json['author']),
      themes: _names(json['theme']),
      themeWords: _pathWords(json['theme']),
      authorWords: _pathWords(json['author']),
      // comic2 的 status 是对象，只取 display
      status: _status(json['status']),
      region: _str(json['region']),
      popular: _int(json['popular']),
      updatedAt: _str(json['datetime_updated']),
      lastChapter: last is Map ? _str(last['name']) : _str(last),
      brief: _str(json['brief']),
      sort: _int(json['sort']),
      riseSort: _int(json['rise_sort']),
      lastChapterId: _str(json['last_chapter_id']),
      browseChapterId: browse is Map ? _str(browse['chapter_uuid']) : '',
      browseChapterName: browse is Map ? _str(browse['chapter_name']) : '',
    );
  }

  /// 解析外层包裹的列表条目（comic/book/cartoon/post）
  factory Comic.fromEntryJson(Map<String, dynamic> json) {
    final inner =
        json['comic'] ?? json['book'] ?? json['cartoon'] ?? json['post'];
    final base = inner is Map
        ? Comic.fromJson(Map<String, dynamic>.from(inner))
        : Comic.fromJson(json);
    final outerPopular = _int(json['popular']);
    final outerChapter = _str(json['name']);
    // 外层 last_browse 与内层 browse 取其一，内层优先
    final lastBrowse = json['last_browse'];
    var browseId = base.browseChapterId;
    var browseName = base.browseChapterName;
    if (lastBrowse is Map) {
      if (browseId.isEmpty) browseId = _str(lastBrowse['last_browse_id']);
      if (browseName.isEmpty) browseName = _str(lastBrowse['last_browse_name']);
    }
    return Comic(
      uuid: base.uuid,
      pathWord: base.pathWord,
      name: base.name,
      alias: base.alias,
      cover: base.cover,
      authors: base.authors,
      themes: base.themes,
      themeWords: base.themeWords,
      authorWords: base.authorWords,
      status: base.status,
      region: base.region,
      popular: outerPopular > base.popular ? outerPopular : base.popular,
      updatedAt: base.updatedAt.isNotEmpty
          ? base.updatedAt
          : _str(json['datetime_updated']),
      lastChapter:
          base.lastChapter.isNotEmpty ? base.lastChapter : outerChapter,
      brief: base.brief,
      chapterCount: base.chapterCount,
      sort: _int(json['sort']),
      riseSort: _int(json['rise_sort']),
      lastChapterId: base.lastChapterId,
      browseChapterId: browseId,
      browseChapterName: browseName,
    );
  }

  /// 最新章节与上次阅读章节不一致
  bool get hasUpdate =>
      lastChapterId.isNotEmpty &&
      browseChapterId.isNotEmpty &&
      lastChapterId != browseChapterId;

  String get statusLabel => switch (status) {
        'completed' || 'end' => '已完结',
        'photo' => '写真',
        _ => '连载中',
      };

  String get regionLabel => switch (region) {
        'jp' => '日漫',
        'cn' || 'zh' => '国漫',
        'kr' => '韩漫',
        'en' || 'us' => '欧美',
        _ => '其他',
      };

  String get popularLabel => formatPopular(popular);

  String get authorLabel => authors.isEmpty ? '佚名' : authors.join(' · ');

  /// 卡片日期行，只取日期部分，空值返回空串
  String get updatedDateLabel {
    final raw = updatedAt.trim();
    if (raw.isEmpty) return '';
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  String get themeLabel => themes.isEmpty ? '综合' : themes.join(' / ');

  static String _str(dynamic v, {String fallback = ''}) =>
      v == null ? fallback : v.toString();

  /// status 可能是对象或字符串，对象只认 display
  static String _status(dynamic v) {
    if (v is Map) {
      final display = _str(v['display']);
      return display.contains('完結') || display.contains('完结')
          ? 'completed'
          : 'ongoing';
    }
    final s = _str(v);
    return s.isEmpty ? 'ongoing' : s;
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static List<String> _names(dynamic v) {
    if (v is! List) return const [];
    return v
        .map((e) => e is Map ? _str(e['name']) : _str(e))
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 与 _names 同序的 path_word 列表
  static List<String> _pathWords(dynamic v) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      final name = e is Map ? _str(e['name']) : _str(e);
      if (name.isEmpty) continue;
      out.add(e is Map ? _str(e['path_word']) : '');
    }
    return out;
  }
}

/// 热度按万/亿折算，0 或负数返回空串
String formatPopular(int value) {
  if (value <= 0) return '';
  if (value >= 100000000) {
    final v = value / 100000000;
    return '${_trimZero(v)} 亿';
  }
  if (value >= 10000) {
    return '${_trimZero(value / 10000)} 万';
  }
  return '$value';
}

/// 1 位小数并去掉多余的 .0
String _trimZero(double v) {
  final text = v.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// RecommendGroup — /api/v3/recs 的推荐分组
class RecommendGroup {
  final String title;
  final int type;
  final List<Comic> comics;

  const RecommendGroup({
    required this.title,
    this.type = 1,
    required this.comics,
  });

  factory RecommendGroup.fromJson(Map<String, dynamic> json) {
    final list = json['comics'];
    return RecommendGroup(
      title: (json['title'] ?? '推荐').toString(),
      type: json['type'] is int ? json['type'] as int : 1,
      comics: list is List
          ? list
              .whereType<Map>()
              .map((e) => Comic.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}
