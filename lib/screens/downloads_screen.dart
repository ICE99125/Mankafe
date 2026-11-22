import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/download.dart';
import '../services/download_manager.dart';
import '../widgets/ui.dart';
import 'reader_screen.dart';

/// DownloadsScreen — 我的下载，进行中任务与已离线章节
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final downloads = context.watch<DownloadManager>();
    final comics = downloads.comics();
    final tasks = downloads.activeTasks();

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(t.downloadsTitle),
        actions: [
          if (comics.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  formatBytes(downloads.totalBytes),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
      body: !downloads.ready
          ? const Center(child: CircularProgressIndicator())
          : comics.isEmpty && tasks.isEmpty
              ? EmptyState(
                  icon: Icons.download_for_offline_outlined,
                  title: t.downloadEmpty,
                  message: t.downloadEmptyHint,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (tasks.isNotEmpty) ...[
                      _SectionLabel(t.downloadingSection),
                      for (final task in tasks) ...[
                        _ActiveTaskCard(task: task),
                        const SizedBox(height: 10),
                      ],
                    ],
                    if (comics.isNotEmpty) ...[
                      if (tasks.isNotEmpty) _SectionLabel(t.downloadDone),
                      for (var i = 0; i < comics.length; i++) ...[
                        _ComicDownloadCard(comic: comics[i]),
                        if (i < comics.length - 1) const SizedBox(height: 10),
                      ],
                    ],
                  ],
                ),
    );
  }
}

/// _SectionLabel — 列表分组标题
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// _ActiveTaskCard — 排队或下载中的一话，进度条与取消
class _ActiveTaskCard extends StatelessWidget {
  final DownloadTask task;

  const _ActiveTaskCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final manager = context.read<DownloadManager>();
    final running = task.status == DownloadStatus.running && task.total > 0;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      radius: const BorderRadius.all(Radius.circular(18)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.chapterName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                if (running) ...[
                  LinearProgressIndicator(value: task.progress, minHeight: 4),
                  const SizedBox(height: 6),
                  Text(
                    t.downloadingProgress(task.done, task.total),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ] else
                  Text(
                    t.downloadQueuedStatus,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: t.cancelDownload,
            icon: Icon(Icons.close_rounded,
                size: 20, color: scheme.onSurfaceVariant),
            onPressed: () => manager.cancel(task.chapterId),
          ),
        ],
      ),
    );
  }
}

/// 字节数格式化为 B/KB/MB/GB，保留一位小数
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// _ComicDownloadCard — 按漫画聚合的已下载章节卡
class _ComicDownloadCard extends StatelessWidget {
  final DownloadedComic comic;

  const _ComicDownloadCard({required this.comic});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);

    return SurfaceCard(
      padding: EdgeInsets.zero,
      radius: const BorderRadius.all(Radius.circular(18)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
            child: Row(
              children: [
                Icon(Icons.collections_bookmark_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        comic.comicName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${t.downloadedChapters(comic.chapterCount)} · '
                        '${formatBytes(comic.bytes)}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: t.downloadDeleteComic,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 20, color: scheme.onSurfaceVariant),
                  onPressed: () => _confirmDelete(context, t),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final chapter in comic.chapters)
            _ChapterRow(chapter: chapter, last: chapter == comic.chapters.last),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AppLocalizations t) async {
    final manager = context.read<DownloadManager>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.downloadDeleteComic),
        content: Text(t.downloadDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.delete),
          ),
        ],
      ),
    );
    if (ok == true) await manager.deleteComic(comic.comicId);
  }
}

/// _ChapterRow — 已下载章节行
class _ChapterRow extends StatelessWidget {
  final DownloadedChapter chapter;
  final bool last;

  const _ChapterRow({required this.chapter, this.last = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppLocalizations.of(context);
    final manager = context.read<DownloadManager>();

    return ListTile(
      dense: true,
      shape: last
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)))
          : null,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading:
          Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary),
      title: Text(
        chapter.chapterName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        '${chapter.imageCount} 页 · ${formatBytes(chapter.bytes)}',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: t.deleteDownload,
        icon:
            Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
        onPressed: () => manager.deleteChapter(chapter.chapterId),
      ),
      // 本地图片优先，断网可读
      onTap: () => openReader(
        context,
        pathWord: chapter.comicPathWord,
        chapterUuid: chapter.chapterId,
      ),
    );
  }
}
