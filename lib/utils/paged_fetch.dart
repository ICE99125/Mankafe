/// PageResult — 一次分页请求的返回：本页条目 + 上游声明的总数
class PageResult<T> {
  final List<T> items;
  final int total;

  const PageResult(this.items, this.total);
}

/// 按上游 `total` 循环翻页，把全量条目拉回来
Future<List<T>> fetchAllPages<T>({
  required Future<PageResult<T>> Function(int offset) fetchPage,
  required String Function(T item) keyOf,
  int pageSize = 100,
  int maxPages = 200,
}) async {
  final out = <T>[];
  final seen = <String>{};
  var offset = 0;

  for (var page = 0; page < maxPages; page++) {
    final result = await fetchPage(offset);

    var added = 0;
    for (final item in result.items) {
      final key = keyOf(item);
      // 空 key 无法判重，直接收下（总数上限仍由 maxPages 控制）
      if (key.isNotEmpty && !seen.add(key)) continue;
      out.add(item);
      added++;
    }

    if (result.items.isEmpty || added == 0 || out.length >= result.total) break;
    offset += pageSize;
  }

  return out;
}
