import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_page.dart';
import '../services/repository.dart';
import '../widgets/paged_media.dart';
import 'comic_detail_screen.dart';

/// MediaListScreen — 首页更多入口的分页列表页
class MediaListScreen extends StatelessWidget {
  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final Future<MediaPage> Function(int offset) load;

  const MediaListScreen({
    super.key,
    required this.title,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.load,
  });

  @override
  Widget build(BuildContext context) {
    final repo = context.read<Repository>();
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: PagedMediaList(
        load: load,
        emptyTitle: emptyTitle,
        emptyMessage: emptyMessage,
        itemBuilder: (context, comic) => MediaEntryCard(
          comic: comic,
          host: repo.imageHost,
          badge: comic.statusLabel,
          onTap: () => openComicDetail(context, comic.pathWord),
        ),
      ),
    );
  }
}
