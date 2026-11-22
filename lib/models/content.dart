import 'comic.dart';
import 'home_index.dart';
import 'media_page.dart';

/// ThemeTag — 主题/标签条目，筛选需传 path_word
class ThemeTag {
  final String name;
  final String pathWord;
  final int count;

  const ThemeTag({
    required this.name,
    required this.pathWord,
    this.count = 0,
  });

  factory ThemeTag.fromJson(Map<String, dynamic> json) => ThemeTag(
        name: (json['name'] ?? '').toString(),
        pathWord: (json['path_word'] ?? '').toString(),
        count: _int(json['count']),
      );

  static List<ThemeTag> listFrom(dynamic results) {
    final raw = results is Map ? results['list'] : results;
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ThemeTag.fromJson(Map<String, dynamic>.from(e)))
        .where((t) => t.name.isNotEmpty && t.pathWord.isNotEmpty)
        .toList();
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// TopicDetail — 专题详情
class TopicDetail {
  final String title;
  final String cover;
  final String period;
  final String brief;
  final String intro;
  final String seriesName;
  final String pathWord;
  final String createdAt;

  const TopicDetail({
    required this.title,
    required this.cover,
    this.period = '',
    this.brief = '',
    this.intro = '',
    this.seriesName = '',
    this.pathWord = '',
    this.createdAt = '',
  });

  factory TopicDetail.fromJson(Map<String, dynamic> json) {
    final series = json['series'];
    return TopicDetail(
      title: (json['title'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      period: (json['period'] ?? '').toString(),
      brief: (json['brief'] ?? '').toString(),
      intro: (json['intro'] ?? '').toString(),
      seriesName: series is Map ? (series['name'] ?? '').toString() : '',
      pathWord: (json['path_word'] ?? '').toString(),
      createdAt: (json['datetime_created'] ?? '').toString(),
    );
  }

  String get description =>
      intro.trim().isNotEmpty ? intro.trim() : brief.trim();
}

/// ContentChapter — 轻小说卷 / 动画剧集 / 写真章节的统一条目
class ContentChapter {
  final String id;
  final String name;
  final int index;
  final int count;
  final String cover;

  /// 动画剧集的播放线路，可用性以播放接口返回为准
  final List<AnimationLine> lines;

  const ContentChapter({
    required this.id,
    required this.name,
    this.index = 0,
    this.count = 0,
    this.cover = '',
    this.lines = const [],
  });

  factory ContentChapter.fromJson(Map<String, dynamic> json) {
    return ContentChapter(
      id: (json['id'] ?? json['uuid'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      index: _int(json['index'] ?? json['sort']),
      count: _int(json['count']),
      cover: (json['v_cover'] ?? json['cover'] ?? '').toString(),
      lines: AnimationLine.listFrom(json['lines']),
    );
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// ContentDetail — 三类详情页共用模型，正文容器字段随类型不同
class ContentDetail {
  final MediaKind kind;
  final Comic item;
  final Map<String, dynamic> raw;
  final List<ContentChapter> chapters;
  final int chapterTotal;

  /// 收藏状态，详情页收藏按钮的初始值
  final bool isCollect;

  const ContentDetail({
    required this.kind,
    required this.item,
    required this.raw,
    this.chapters = const [],
    this.chapterTotal = 0,
    this.isCollect = false,
  });

  String get summary {
    final brief = (raw['brief'] ?? '').toString().trim();
    if (brief.isNotEmpty) return brief;
    return (raw['intro'] ?? '').toString().trim();
  }

  /// 标签对象转 ThemeTag，兼容数组与单个对象
  List<ThemeTag> tags(String key) {
    final v = raw[key];
    final nodes = v is List
        ? v.whereType<Map>().toList()
        : v is Map
            ? <Map>[v]
            : <Map>[];
    return nodes
        .map((e) => ThemeTag(
              name: (e['name'] ?? '').toString(),
              pathWord: (e['path_word'] ?? '').toString(),
            ))
        .where((t) => t.name.isNotEmpty)
        .toList();
  }
}

/// ContentPage — 正文单元，文字段落或图片 URL
class ContentPage {
  final String text;
  final String url;

  const ContentPage({this.text = '', this.url = ''});

  bool get isImage => url.isNotEmpty;

  static List<ContentPage> fromContents(dynamic contents) {
    if (contents is! List) return const [];
    final out = <ContentPage>[];
    for (final e in contents) {
      if (e is String) {
        final s = e.trim();
        if (s.isEmpty) continue;
        // 图片 URL 单独识别
        if (s.startsWith('http://') || s.startsWith('https://')) {
          out.add(ContentPage(url: s));
        } else {
          out.add(ContentPage(text: s));
        }
      } else if (e is Map) {
        final u = (e['url'] ?? e['image'] ?? '').toString();
        final t = (e['text'] ?? e['content'] ?? '').toString();
        if (u.isNotEmpty) {
          out.add(ContentPage(url: u));
        } else if (t.isNotEmpty) {
          out.add(ContentPage(text: t));
        }
      }
    }
    return out;
  }
}

/// NovelSection — 轻小说分节标记
class NovelSection {
  final String name;
  final int startLine;
  final int endLine;

  const NovelSection({
    required this.name,
    this.startLine = 0,
    this.endLine = 0,
  });

  factory NovelSection.fromJson(Map<String, dynamic> json) => NovelSection(
        name: (json['name'] ?? '').toString(),
        startLine: _toInt(json['start_lines']),
        endLine: _toInt(json['end_lines']),
      );
}

/// NovelVolume — 轻小说卷，正文来自 txt_addr 指向的 txt
class NovelVolume {
  final String name;
  final String txtAddr;
  final String encoding;
  final List<NovelSection> sections;
  final String text;

  const NovelVolume({
    required this.name,
    required this.txtAddr,
    required this.encoding,
    this.sections = const [],
    this.text = '',
  });

  /// 按空行切段，连续空行合并
  List<String> get paragraphs {
    final out = <String>[];
    final buffer = StringBuffer();
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          out.add(buffer.toString().trim());
          buffer.clear();
        }
      } else {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.write(line.trim());
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString().trim());
    return out;
  }
}

/// MediaIndexGroup — 聚合页的一个区块
class MediaIndexGroup {
  final String key;
  final String title;
  final List<Comic> items;

  /// 信封里的 total，不代表本地数据条数
  final int total;

  const MediaIndexGroup({
    required this.key,
    required this.title,
    required this.items,
    this.total = 0,
  });
}

/// MediaIndex — h5 聚合页数据
class MediaIndex {
  final MediaKind kind;
  final List<HomeBanner> banners;
  final List<HomeTopic> topics;
  final List<ThemeTag> tags;

  /// 真实排序项，值可直接用于 ordering 参数
  final List<ThemeTag> orderings;
  final List<MediaIndexGroup> groups;

  const MediaIndex({
    required this.kind,
    this.banners = const [],
    this.topics = const [],
    this.tags = const [],
    this.orderings = const [],
    this.groups = const [],
  });

  factory MediaIndex.fromResults(Map<String, dynamic> results, MediaKind kind) {
    // 区块容器有裸数组和 {list, total} 两种
    (List<Map<String, dynamic>>, int) section(dynamic node) {
      List<dynamic> raw;
      var total = 0;
      if (node is List) {
        raw = node;
      } else if (node is Map && node['list'] is List) {
        raw = node['list'] as List;
        final t = node['total'];
        total = t is int ? t : int.tryParse(t?.toString() ?? '') ?? 0;
      } else {
        return (const <Map<String, dynamic>>[], 0);
      }
      return (
        raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
        total,
      );
    }

    List<Map<String, dynamic>> maps(dynamic node) => section(node).$1;

    final banners = maps(results['banners'])
        .map(HomeBanner.fromJson)
        .where((b) => b.cover.isNotEmpty)
        .toList();
    final topics = maps(results['topics'])
        .map(HomeTopic.fromJson)
        .where((t) => t.cover.isNotEmpty)
        .toList();
    final tags = maps(results['tags'])
        .map(ThemeTag.fromJson)
        .where((t) => t.pathWord.isNotEmpty)
        .toList();
    final orderings = maps(results['ordering'])
        .map(ThemeTag.fromJson)
        .where((t) => t.pathWord.isNotEmpty)
        .toList();

    Comic? comicOf(Map<String, dynamic> m) => comicFromEntry(m);

    const labels = <String, String>{
      'recCartoons': '动画推荐',
      'recComics': '推荐',
      'rankWeekPosts': '写真周榜',
      'rankMonthPosts': '写真月榜',
      'rankDayPosts': '写真日榜',
      'newPosts': '最新写真',
      'recPosts': '写真推荐',
    };
    const nonGroupKeys = {'banners', 'topics', 'tags', 'ordering'};
    final groups = <MediaIndexGroup>[];
    results.forEach((key, value) {
      if (nonGroupKeys.contains(key)) return;
      final (entries, total) = section(value);
      if (entries.isEmpty) return;
      final items = entries.map(comicOf).whereType<Comic>().toList();
      if (items.isEmpty) return;
      groups.add(MediaIndexGroup(
        key: key,
        title: labels[key] ?? key,
        items: items,
        total: total,
      ));
    });
    return MediaIndex(
      kind: kind,
      banners: banners,
      topics: topics,
      tags: tags,
      orderings: orderings,
      groups: groups,
    );
  }
}

/// 聚合条目统一转成 Comic
Comic? comicFromEntry(Map<String, dynamic> m) {
  final inner = m['post'] ?? m['comic'] ?? m['cartoon'] ?? m['book'] ?? m;
  final body = inner is Map ? Map<String, dynamic>.from(inner) : m;
  final pathWord = (body['path_word'] ?? '').toString();
  final uuid = (body['uuid'] ?? '').toString();
  final id = pathWord.isNotEmpty ? pathWord : uuid;
  if (id.isEmpty || (body['name'] ?? '').toString().isEmpty) return null;
  // 动画推荐卡的日期在 years 字段
  final years = (body['years'] ?? '').toString();
  return Comic.fromEntryJson({
    ...body,
    'path_word': id,
    if (m['popular'] != null) 'popular': m['popular'],
    if (m['datetime_created'] != null)
      'datetime_updated': m['datetime_created']
    else if ((body['datetime_updated'] ?? '').toString().isEmpty &&
        years.length >= 10)
      'datetime_updated': years,
  });
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// AnimationLine — 动画播放线路
class AnimationLine {
  final String name;
  final String pathWord;

  /// 服务端标记该线路已配置播放地址
  final bool configured;

  /// 服务端是否下发 config 字段
  final bool configKnown;

  const AnimationLine({
    required this.name,
    required this.pathWord,
    this.configured = false,
    this.configKnown = false,
  });

  /// 仅明确 config: false 时不可用
  bool get usable => !configKnown || configured;

  static List<AnimationLine> listFrom(dynamic node) {
    final out = <AnimationLine>[];
    if (node is List) {
      for (final e in node.whereType<Map>()) {
        final name = (e['name'] ?? '').toString();
        final pw = (e['path_word'] ?? '').toString();
        if (name.isEmpty && pw.isEmpty) continue;
        out.add(AnimationLine(
          name: name.isEmpty ? pw : name,
          pathWord: pw,
          configured: e['config'] == true,
          configKnown: e.containsKey('config'),
        ));
      }
    } else if (node is Map) {
      node.forEach((key, value) {
        if (value is! Map) return;
        final name = (value['name'] ?? '').toString();
        final pw = (value['path_word'] ?? key).toString();
        out.add(AnimationLine(
          name: name.isEmpty ? pw : name,
          pathWord: pw,
          configured: value['config'] == true,
          configKnown: value.containsKey('config'),
        ));
      });
    }
    return out;
  }
}

/// AnimationPlay — 播放结果，video 为 m3u8 地址
class AnimationPlay {
  final String chapterName;
  final String video;
  final String vid;
  final String cover;
  final int count;
  final String chapterUuid;
  final List<AnimationLine> lines;

  /// 本次请求的线路，空串表示用服务端默认线路
  final String line;

  const AnimationPlay({
    required this.chapterName,
    this.video = '',
    this.vid = '',
    this.cover = '',
    this.count = 0,
    this.chapterUuid = '',
    this.lines = const [],
    this.line = '',
  });

  bool get hasVideo => video.trim().isNotEmpty;

  /// 当前返回线路对应的线路项
  AnimationLine? get activeLine {
    for (final l in lines) {
      if (l.pathWord == line) return l;
    }
    for (final l in lines) {
      if (l.configured) return l;
    }
    return lines.isEmpty ? null : lines.first;
  }

  factory AnimationPlay.fromJson(Map<String, dynamic> json,
      {String line = ''}) {
    return AnimationPlay(
      chapterName: (json['name'] ?? '').toString(),
      video: (json['video'] ?? '').toString(),
      vid: (json['vid'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      count: _toInt(json['count']),
      chapterUuid: (json['uuid'] ?? '').toString(),
      lines: AnimationLine.listFrom(json['lines']),
      line: line,
    );
  }
}
