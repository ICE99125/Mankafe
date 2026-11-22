/// 章节目录分页：把总条数 + 当前页换算成实际要渲染的区间
library;

/// 每页章节数
const int kChapterPageSize = 100;

/// ChapterPageRange — 一次分页的结算结果
class ChapterPageRange {
  /// 第一条在完整列表里的下标（0 基）
  final int start;

  /// 条数（最后一页可能不足 [kChapterPageSize]）
  final int count;

  /// 总页数
  final int pages;

  const ChapterPageRange(this.start, this.count, this.pages);

  /// 是否需要显示分页器：只有超过一页才显示
  bool get showPager => pages > 1;

  /// 空区间（列表为空或页码越界被夹回后仍为空）
  bool get isEmpty => count == 0;
}

/// 计算 [page] 页对应的区间
ChapterPageRange chapterPageRange(
  int total,
  int page, {
  int size = kChapterPageSize,
}) {
  assert(size > 0);
  if (total <= 0) return const ChapterPageRange(0, 0, 0);
  final pages = (total + size - 1) ~/ size;
  final safePage = page.clamp(0, pages - 1);
  final start = safePage * size;
  final remain = total - start;
  return ChapterPageRange(start, remain > size ? size : remain, pages);
}
