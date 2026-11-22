import 'comic.dart';

/// MediaKind — 四个内容域
enum MediaKind { comic, novel, photo, animation }

/// MediaKind 的中文标签
extension MediaKindX on MediaKind {
  String get label => switch (this) {
        MediaKind.comic => '漫画',
        MediaKind.novel => '轻小说',
        MediaKind.photo => '写真集',
        MediaKind.animation => '动画',
      };
}

/// CatalogKind — 底部导航的三个内容频道
enum CatalogKind { novel, photo, animation }

/// CatalogKind 的标签、搜索提示与对应 MediaKind
extension CatalogKindX on CatalogKind {
  String get label => switch (this) {
        CatalogKind.novel => '轻小说',
        CatalogKind.photo => '写真',
        CatalogKind.animation => '动画',
      };

  String get searchHint => '搜索$label标题或作者';

  MediaKind get mediaKind => switch (this) {
        CatalogKind.novel => MediaKind.novel,
        CatalogKind.photo => MediaKind.photo,
        CatalogKind.animation => MediaKind.animation,
      };
}

/// MediaPage — 一页列表数据，含 total/offset/limit
class MediaPage {
  final MediaKind kind;
  final List<Comic> items;
  final int total;
  final int offset;
  final int limit;

  const MediaPage({
    required this.kind,
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
  });

  bool get hasMore {
    if (items.isEmpty) return false;
    if (total > 0) return offset + items.length < total;
    return items.length >= limit;
  }

  factory MediaPage.fromResults(
    MediaKind kind,
    dynamic results, {
    required int offset,
    int fallbackLimit = 21,
  }) {
    final map = results is Map ? Map<String, dynamic>.from(results) : const {};
    final raw = map['list'];
    final items = raw is List
        ? raw
            .whereType<Map>()
            .map((e) {
              final m = Map<String, dynamic>.from(e);
              // 写真条目是扁平结构，uuid 当路由标识
              if (kind == MediaKind.photo) {
                // 书架会再包一层 {post: {...}}
                final inner = m['post'] ?? m['comic'];
                final p = inner is Map ? Map<String, dynamic>.from(inner) : m;
                final mannequins = p['mannequins'];
                final names = mannequins is List
                    ? mannequins
                        .whereType<Map>()
                        .map((x) => (x['name'] ?? '').toString())
                        .where((s) => s.isNotEmpty)
                        .toList()
                    : const <String>[];
                final uuid = (p['uuid'] ?? '').toString();
                return Comic(
                  uuid: uuid,
                  pathWord: uuid,
                  name: (p['name'] ?? '').toString(),
                  cover: p['cover'] is String ? p['cover'] as String : null,
                  authors: names,
                  status: 'photo',
                  popular: _int(p['popular']),
                  updatedAt: (p['datetime_updated'] ?? '').toString(),
                );
              }
              return Comic.fromEntryJson(m);
            })
            .where((c) => c.pathWord.isNotEmpty)
            .toList()
        : <Comic>[];
    final limit = _int(map['limit']);
    final total = _int(map['total']);
    return MediaPage(
      kind: kind,
      items: items,
      total: total,
      offset: offset,
      limit: limit > 0 ? limit : fallbackLimit,
    );
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
