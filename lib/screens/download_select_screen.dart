import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/chapter.dart';
import '../models/download.dart';
import '../services/download_manager.dart';
import 'downloads_screen.dart';

void openDownloadSelect(
  BuildContext context, {
  required String comicId,
  required String comicPathWord,
  required String comicName,
  required List<Chapter> chapters,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DownloadSelectScreen(
        comicId: comicId,
        comicPathWord: comicPathWord,
        comicName: comicName,
        chapters: chapters,
      ),
    ),
  );
}

/// DownloadSelectScreen — 章节多选下载页，底部批量入队
class DownloadSelectScreen extends StatefulWidget {
  final String comicId;
  final String comicPathWord;
  final String comicName;
  final List<Chapter> chapters;

  const DownloadSelectScreen({
    super.key,
    required this.comicId,
    required this.comicPathWord,
    required this.comicName,
    required this.chapters,
  });

  @override
  State<DownloadSelectScreen> createState() => _DownloadSelectScreenState();
}

class _DownloadSelectScreenState extends State<DownloadSelectScreen> {
  final Set<String> _selected = {};

  void _toggle(String chapterId) {
    setState(() {
      if (!_selected.remove(chapterId)) _selected.add(chapterId);
    });
  }

  void _selectAll() {
    final downloads = context.read<DownloadManager>();
    setState(() {
      for (final c in widget.chapters) {
        if (downloads.isDownloaded(c.uuid)) continue;
        if (downloads.taskOf(c.uuid)?.isActive ?? false) continue;
        _selected.add(c.uuid);
      }
    });
  }

  void _start() {
    final chapters =
        widget.chapters.where((c) => _selected.contains(c.uuid)).toList();
    if (chapters.isEmpty) return;
    final t = AppLocalizations.of(context);
    context.read<DownloadManager>().downloadAll(
          comicId: widget.comicId,
          comicPathWord: widget.comicPathWord,
          comicName: widget.comicName,
          chapters: chapters,
        );
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.downloadQueued)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloads = context.watch<DownloadManager>();

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(t.downloadSelectTitle),
        actions: [
          IconButton(
            tooltip: t.downloadsTitle,
            icon: const Icon(Icons.download_done_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.comicName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                TextButton(
                  onPressed: _selectAll,
                  child: Text(t.downloadSelectAll),
                ),
                TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => setState(_selected.clear),
                  child: Text(t.downloadSelectNone),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: widget.chapters.length,
              itemBuilder: (context, i) =>
                  _chapterRow(widget.chapters[i], downloads, t, theme),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.downloadSelectedCount(
                      _selected.length, widget.chapters.length),
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              FilledButton.icon(
                onPressed: _selected.isEmpty ? null : _start,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(t.downloadStart(_selected.length)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapterRow(
    Chapter chapter,
    DownloadManager downloads,
    AppLocalizations t,
    ThemeData theme,
  ) {
    final scheme = theme.colorScheme;
    final downloaded = downloads.isDownloaded(chapter.uuid);
    final task = downloads.taskOf(chapter.uuid);
    final active = task?.isActive ?? false;

    if (downloaded) {
      return ListTile(
        dense: true,
        leading:
            Icon(Icons.download_done_rounded, size: 20, color: scheme.primary),
        title: Text(
          chapter.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        trailing: Text(
          t.downloadDone,
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
        ),
      );
    }

    if (active) {
      final running = task!.status == DownloadStatus.running && task.total > 0;
      return ListTile(
        dense: true,
        leading: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(
          chapter.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          running
              ? t.downloadingProgress(task.done, task.total)
              : t.downloadQueuedStatus,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        trailing: IconButton(
          tooltip: t.cancelDownload,
          icon: Icon(Icons.close_rounded,
              size: 18, color: scheme.onSurfaceVariant),
          onPressed: () => downloads.cancel(chapter.uuid),
        ),
      );
    }

    final selected = _selected.contains(chapter.uuid);
    return ListTile(
      dense: true,
      onTap: () => _toggle(chapter.uuid),
      leading: Checkbox(
        value: selected,
        onChanged: (_) => _toggle(chapter.uuid),
      ),
      title: Text(
        chapter.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
    );
  }
}
