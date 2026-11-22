import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/comic.dart';
import '../services/image_url.dart';
import '../services/repository.dart';
import '../widgets/browse_widgets.dart';
import '../widgets/paged_media.dart';
import 'comic_detail_screen.dart';

/// RecommendationsScreen — 漫画推荐更多页，滑到底自动续页
class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({super.key});

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    final repo = context.read<Repository>();
    final host = repo.imageHost;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: Text(t.recommendationsTitle)),
      body: PagedMediaList(
        load: (offset) => repo.comicPage(offset: offset),
        emptyTitle: t.recommendationsEmpty,
        emptyMessage: t.emptyUpdatesMessage,
        itemBuilder: (context, comic) => _RecommendationCard(
          comic: comic,
          host: host,
          onTap: () => openComicDetail(context, comic.pathWord),
        ),
      ),
    );
  }
}

/// _RecommendationCard — 推荐列表封面卡
class _RecommendationCard extends StatelessWidget {
  final Comic comic;
  final String? host;
  final VoidCallback onTap;

  const _RecommendationCard({
    required this.comic,
    required this.onTap,
    this.host,
  });

  @override
  Widget build(BuildContext context) {
    return RichGridCard(
      title: comic.name,
      author: comic.authorLabel,
      coverUrl: resolveImageUrl(comic.cover ?? '', host: host),
      popular: comic.popularLabel,
      onTap: onTap,
    );
  }
}
