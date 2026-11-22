import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/download.dart';
import 'download_store.dart';
import 'image_store.dart';
import 'repository.dart';

/// _Job — 一次下载任务的内部记录
class _Job {
  final String comicId;
  final String comicPathWord;
  final String comicName;
  final Chapter chapter;
  bool canceled = false;

  _Job({
    required this.comicId,
    required this.comicPathWord,
    required this.comicName,
    required this.chapter,
  });
}

/// DownloadManager — 离线下载管理器：串行队列 + 逐话进度 + 本地索引
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.repo,
    DownloadStore? store,
    Future<Uint8List> Function(String url)? fetchBytes,
  })  : store = store ?? DownloadStore(),
        _fetchBytes = fetchBytes;

  final Repository repo;
  final DownloadStore store;
  final Future<Uint8List> Function(String url)? _fetchBytes;

  final Map<String, DownloadedChapter> _byChapter = {};
  final Map<String, DownloadTask> _tasks = {};
  final List<_Job> _queue = [];

  String? _rootPath;
  bool _ready = false;
  bool _pumping = false;

  /// 当前正在下载的任务（已出队），cancel 靠它把取消标记送进运行中的循环
  _Job? _running;

  /// 索引是否已从磁盘读出来
  bool get ready => _ready;

  bool get isBusy => _pumping || _queue.isNotEmpty;

  /// 正在排队或下载中的话数
  int get activeCount => _tasks.values.where((t) => t.isActive).length;

  int get totalBytes => _byChapter.values.fold(0, (sum, c) => sum + c.bytes);

  Future<void> init() async {
    final loaded = await store.loadIndex();
    _rootPath = (await store.root()).path;
    _byChapter
      ..clear()
      ..addEntries(loaded.map((c) => MapEntry(c.chapterId, c)));
    _ready = true;
    notifyListeners();
  }

  bool isDownloaded(String chapterId) => _byChapter.containsKey(chapterId);

  DownloadedChapter? chapterOf(String chapterId) => _byChapter[chapterId];

  DownloadTask? taskOf(String chapterId) => _tasks[chapterId];

  /// 排队中 / 下载中的任务，按入队顺序（正在下的那一话排在最前）
  List<DownloadTask> activeTasks() =>
      _tasks.values.where((t) => t.isActive).toList(growable: false);

  /// 本地图片文件
  File? localFile(String chapterId, int index) {
    final root = _rootPath;
    final entry = _byChapter[chapterId];
    if (root == null || entry == null) return null;
    if (index < 0 || index >= entry.files.length) return null;
    return File('$root/${entry.dir}/${entry.files[index]}');
  }

  /// 按漫画聚合，最近下载的排前面
  List<DownloadedComic> comics() {
    final grouped = <String, List<DownloadedChapter>>{};
    for (final c in _byChapter.values) {
      grouped.putIfAbsent(c.comicId, () => []).add(c);
    }
    final list = grouped.entries.map((e) {
      final chapters = e.value..sort((a, b) => a.sort.compareTo(b.sort));
      return DownloadedComic(
        comicId: e.key,
        comicPathWord: chapters.first.comicPathWord,
        comicName: chapters.first.comicName,
        chapters: chapters,
      );
    }).toList();
    list.sort((a, b) {
      final at = a.latest?.savedAt ?? '';
      final bt = b.latest?.savedAt ?? '';
      return bt.compareTo(at);
    });
    return list;
  }

  /// 把一话加入下载队列
  void downloadChapter({
    required String comicId,
    required String comicPathWord,
    required String comicName,
    required Chapter chapter,
  }) {
    if (_byChapter.containsKey(chapter.uuid)) return;
    final existing = _tasks[chapter.uuid];
    if (existing != null && existing.isActive) return;
    _tasks[chapter.uuid] = DownloadTask(
      chapterId: chapter.uuid,
      chapterName: chapter.name,
    );
    _queue.add(_Job(
      comicId: comicId,
      comicPathWord: comicPathWord,
      comicName: comicName,
      chapter: chapter,
    ));
    notifyListeners();
    unawaited(_pump());
  }

  /// 批量下载：已在队列 / 已下载的自动跳过
  void downloadAll({
    required String comicId,
    required String comicPathWord,
    required String comicName,
    required List<Chapter> chapters,
  }) {
    for (final chapter in chapters) {
      downloadChapter(
        comicId: comicId,
        comicPathWord: comicPathWord,
        comicName: comicName,
        chapter: chapter,
      );
    }
  }

  /// 取消排队中 / 下载中的一话
  void cancel(String chapterId) {
    final task = _tasks[chapterId];
    if (task == null || !task.isActive) return;
    // 正在下的那一话已出队，_queue 里找不到，必须单独标记，否则它会继续下完并写回索引
    final running = _running;
    if (running != null && running.chapter.uuid == chapterId) {
      running.canceled = true;
    }
    for (final job in _queue) {
      if (job.chapter.uuid == chapterId) job.canceled = true;
    }
    _queue.removeWhere((j) => j.chapter.uuid == chapterId && j.canceled);
    task
      ..status = DownloadStatus.canceled
      ..error = null;
    notifyListeners();
  }

  /// 删除一话的本地文件与索引记录
  Future<void> deleteChapter(String chapterId) async {
    final entry = _byChapter.remove(chapterId);
    _tasks.remove(chapterId);
    if (entry != null) await store.deleteChapterDir(entry.dir);
    await _persist();
    notifyListeners();
  }

  /// 删除整本漫画的下载
  Future<void> deleteComic(String comicId) async {
    final entries = _byChapter.values
        .where((c) => c.comicId == comicId)
        .toList(growable: false);
    if (entries.isEmpty) return;
    for (final e in entries) {
      _byChapter.remove(e.chapterId);
      _tasks.remove(e.chapterId);
    }
    await store.deleteComicDir(entries.first.comicPathWord);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() =>
      store.saveIndex(_byChapter.values.toList(growable: false));

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    notifyListeners();
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        if (job.canceled) continue;
        _running = job;
        await _run(job);
        _running = null;
      }
    } finally {
      _pumping = false;
      notifyListeners();
    }
  }

  Future<void> _run(_Job job) async {
    final chapterId = job.chapter.uuid;
    final task = _tasks[chapterId];
    if (task == null) return;
    task
      ..status = DownloadStatus.running
      ..done = 0
      ..error = null;
    notifyListeners();

    try {
      final content = await repo.chapterContent(
        job.comicPathWord,
        chapterId,
        const [],
      );
      final images = content.images;
      task.total = images.length;
      notifyListeners();

      final dir = await store.chapterDir(job.comicPathWord, chapterId);
      final relative = '${job.comicPathWord}/$chapterId';
      final files = <String>[];
      var bytes = 0;

      for (var i = 0; i < images.length; i++) {
        if (job.canceled) {
          task.status = DownloadStatus.canceled;
          notifyListeners();
          return;
        }
        final url = images[i].url;
        final name = '${i.toString().padLeft(3, '0')}.jpg';
        final file = File('${dir.path}/$name');
        // 断点续传：已存在且非空的页直接计入，不再打图床
        if (await file.exists() && await file.length() > 0) {
          files.add(name);
          bytes += await file.length();
          task.done = i + 1;
          notifyListeners();
          continue;
        }
        if (url == null || url.isEmpty) {
          task.done = i + 1;
          notifyListeners();
          continue;
        }
        final data = await _download(url);
        await file.writeAsBytes(data, flush: false);
        files.add(name);
        bytes += data.length;
        task.done = i + 1;
        notifyListeners();
      }

      if (files.isEmpty) {
        task
          ..status = DownloadStatus.failed
          ..error = '该话没有可下载的图片';
        notifyListeners();
        return;
      }

      // 最后一页与写索引之间也可能收到取消，这里再查一次
      if (job.canceled) {
        task.status = DownloadStatus.canceled;
        notifyListeners();
        return;
      }

      _byChapter[chapterId] = DownloadedChapter(
        comicId: job.comicId,
        comicPathWord: job.comicPathWord,
        comicName: job.comicName,
        chapterId: chapterId,
        chapterName: job.chapter.name,
        imageCount: files.length,
        sort: job.chapter.index,
        dir: relative,
        files: files,
        next: content.next ?? '',
        prev: content.prev ?? '',
        bytes: bytes,
        savedAt: DateTime.now().toIso8601String(),
      );
      await _persist();
      task
        ..status = DownloadStatus.done
        ..done = files.length
        ..total = files.length;
      notifyListeners();
    } catch (error) {
      if (kDebugMode) debugPrint('[download] $chapterId 失败: $error');
      task
        ..status = DownloadStatus.failed
        ..error = error.toString();
      notifyListeners();
    }
  }

  Future<Uint8List> _download(String url) {
    final custom = _fetchBytes;
    if (custom != null) return custom(url);
    // 复用 ImageStore 的请求头与超时策略：图床按 referer 判来源，裸请求会被拒
    return ImageStore.instance.fetch(url);
  }
}
