import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/download.dart';

/// DownloadStore — 下载内容的落盘布局 + 索引读写
class DownloadStore {
  DownloadStore({Directory? root}) : _rootOverride = root;

  final Directory? _rootOverride;
  Directory? _root;

  /// 索引文件格式版本：将来改结构时用来决定要不要丢弃旧索引
  static const int schemaVersion = 1;

  Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = _rootOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<File> _indexFile() async => File('${(await root()).path}/index.json');

  /// 读取索引
  Future<List<DownloadedChapter>> loadIndex() async {
    try {
      final file = await _indexFile();
      if (!await file.exists()) return const [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return const [];
      if (raw['version'] != schemaVersion) return const [];
      final list = raw['chapters'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => DownloadedChapter.fromJson(Map<String, dynamic>.from(e)))
          .where((c) => c.chapterId.isNotEmpty)
          .toList();
    } catch (error) {
      if (kDebugMode) debugPrint('[download] 读取索引失败: $error');
      return const [];
    }
  }

  Future<void> saveIndex(List<DownloadedChapter> chapters) async {
    try {
      final file = await _indexFile();
      final body = jsonEncode({
        'version': schemaVersion,
        'chapters': chapters.map((c) => c.toJson()).toList(),
      });
      // 先写临时文件再改名，避免进程被杀时留下半份索引
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: false);
      await tmp.rename(file.path);
    } catch (error) {
      if (kDebugMode) debugPrint('[download] 写索引失败: $error');
    }
  }

  /// 章节图片目录（不存在则创建）
  Future<Directory> chapterDir(String pathWord, String chapterId) async {
    final dir = Directory('${(await root()).path}/$pathWord/$chapterId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 索引里记录的是相对路径，这里还原成绝对路径
  Future<String> absoluteDir(String relative) async =>
      '${(await root()).path}/$relative';

  /// 删除一话的图片目录
  Future<void> deleteChapterDir(String relative) async {
    try {
      final dir = Directory(await absoluteDir(relative));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      if (kDebugMode) debugPrint('[download] 删除目录失败: $error');
    }
  }

  /// 删除整本漫画的目录（索引由调用方维护）
  Future<void> deleteComicDir(String pathWord) async {
    try {
      final dir = Directory('${(await root()).path}/$pathWord');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      if (kDebugMode) debugPrint('[download] 删除作品目录失败: $error');
    }
  }
}
