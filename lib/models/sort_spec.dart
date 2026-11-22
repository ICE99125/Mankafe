/// SortField — 排序维度，wire 为 ordering 字段名
enum SortField {
  date('datetime_updated'),
  popular('popular');

  const SortField(this.wire);

  /// ordering 字段名，正负号由方向决定
  final String wire;
}

/// 组装 ordering 参数，desc 为 true 时加负号
String orderingParam(SortField field, {required bool desc}) =>
    desc ? '-${field.wire}' : field.wire;
