import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_page.dart';
import '../services/repository.dart';
import '../widgets/brand_header.dart';
import '../widgets/paged_media.dart';
import 'comic_detail_screen.dart';
import 'content_detail_screen.dart';
import 'topic_detail_screen.dart';

/// CatalogMoreScreen — 「更多 / 筛选结果」整页，数据由调用方传入的分页 load 提供
class CatalogMoreScreen extends StatelessWidget {
  final String title;
  final MediaKind kind;
  final String? subtitle;
  final Future<MediaPage> Function(int offset) load;

  const CatalogMoreScreen({
    super.key,
    required this.title,
    required this.kind,
    required this.load,
    this.subtitle,
  });

  /// 打开题材 / 作者 / 改编 / 标签 / 完结筛选结果页
  static void openFilter(
    BuildContext context, {
    required MediaKind kind,
    required String title,
    String theme = '',
    String author = '',
    String parody = '',
    String tag = '',
    String company = '',
    String mannequin = '',
    String top = '',
    String ordering = '-datetime_updated',
  }) {
    final repo = context.read<Repository>();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CatalogMoreScreen(
        title: title,
        kind: kind,
        subtitle: '${kind.label} · 线上筛选结果',
        load: (offset) => repo.filteredPage(
          kind,
          theme: theme,
          author: author,
          parody: parody,
          tag: tag,
          company: company,
          mannequin: mannequin,
          top: top,
          ordering: ordering,
          offset: offset,
        ),
      ),
    ));
  }

  /// 打开榜单页，[dateType] 取 day / week / month / total
  static void openRanks(
    BuildContext context, {
    required String dateType,
    required String title,
  }) {
    final repo = context.read<Repository>();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CatalogMoreScreen(
        title: title,
        kind: MediaKind.comic,
        subtitle: '榜单 · $dateType',
        load: (offset) => repo.rankPage(dateType: dateType, offset: offset),
      ),
    ));
  }

  /// 打开专题内容列表，[kind] 决定详情页走漫画还是动画 / 写真接口
  static void openTopicContents(
    BuildContext context, {
    required String pathWord,
    required String title,
    MediaKind kind = MediaKind.comic,
  }) {
    TopicDetailScreen.open(
      context,
      pathWord: pathWord,
      title: title,
      kind: kind,
    );
  }

  /// 用任意分页数据源打开列表页
  static void openLoader(
    BuildContext context, {
    required String title,
    required MediaKind kind,
    required Future<MediaPage> Function(int offset) load,
    String? subtitle,
  }) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CatalogMoreScreen(
        title: title,
        kind: kind,
        subtitle: subtitle,
        load: load,
      ),
    ));
  }

  void _openItem(BuildContext context, String pathWord) {
    if (kind == MediaKind.comic) {
      openComicDetail(context, pathWord);
    } else {
      openContentDetail(context, kind, pathWord);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    return Scaffold(
      body: Column(
        children: [
          BrandBar(
            leading: BrandBackButton(
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: BrandTitle(name: title),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          Expanded(
            child: PagedMediaList(
              load: load,
              emptyTitle: '暂时没有内容',
              emptyMessage: '换个筛选条件，或稍后重新请求线上接口',
              itemBuilder: (context, comic) => MediaEntryCard(
                comic: comic,
                host: host,
                badge: comic.statusLabel,
                onTap: () => _openItem(context, comic.pathWord),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
