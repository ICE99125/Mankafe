import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/album_saver.dart';

/// 长按整页图 → 底部操作表 → 保存到系统相册
Future<void> showSaveToAlbumSheet(
  BuildContext context, {
  required String albumTitle,
  required int page,
  required Future<Uint8List> Function() readBytes,
}) async {
  final t = AppLocalizations.of(context);
  final theme = Theme.of(context);

  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.pageLabel(page),
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  AlbumSaver.albumName,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt_rounded),
            title: Text(t.saveToAlbum),
            subtitle: Text(t.saveToAlbumHint),
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(minutes: 1),
      content: Text(t.savingToAlbum),
    ));

  String message;
  try {
    final bytes = await readBytes();
    await AlbumSaver.instance.savePage(bytes, title: albumTitle, page: page);
    message = t.savedToAlbum;
  } on AlbumSaveException catch (error) {
    debugPrint('[album] 保存失败 ${error.reason.name}: ${error.detail}');
    message = switch (error.reason) {
      AlbumSaveFailure.permissionDenied => t.saveToAlbumPermission,
      AlbumSaveFailure.unsupported => t.saveToAlbumUnsupported,
      AlbumSaveFailure.writeFailed => t.saveToAlbumFailed,
    };
  } catch (error) {
    debugPrint('[album] 保存失败: $error');
    message = t.saveToAlbumFailed;
  }

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
