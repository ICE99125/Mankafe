import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// AlbumSaveFailure — 保存到相册失败的原因
enum AlbumSaveFailure {
  /// 系统 / 原生层没有相册写入权限（Android 9 及以下需要运行时授权）
  permissionDenied,

  /// 当前平台没有相册（例如 iOS 未接入照片库、目录不可写）
  unsupported,

  /// 其它写盘 / 原生失败
  writeFailed,
}

/// AlbumSaveException — 保存失败
class AlbumSaveException implements Exception {
  final AlbumSaveFailure reason;
  final String detail;

  const AlbumSaveException(this.reason, [this.detail = '']);

  @override
  String toString() =>
      'AlbumSaveException(${reason.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// ImageFormat — 图片真实格式：按文件头判断，不信 URL 后缀
class ImageFormat {
  final String extension;
  final String mime;

  const ImageFormat(this.extension, this.mime);

  static const ImageFormat jpeg = ImageFormat('jpg', 'image/jpeg');
  static const ImageFormat png = ImageFormat('png', 'image/png');
  static const ImageFormat gif = ImageFormat('gif', 'image/gif');
  static const ImageFormat webp = ImageFormat('webp', 'image/webp');
  static const ImageFormat bmp = ImageFormat('bmp', 'image/bmp');

  static ImageFormat sniff(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return png;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return jpeg;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return gif;
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return webp;
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return bmp;
    }
    // 兜底按 JPEG：漫画 / 写真页绝大多数是 JPEG，未知格式也仍然能存下来
    return jpeg;
  }
}

/// AlbumSaver — 把整页图存进系统相册
class AlbumSaver {
  AlbumSaver({
    MethodChannel? channel,
    bool? onAndroid,
    Future<Directory?> Function()? albumDirectory,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _onAndroid = onAndroid ?? defaultAlbumsOnAndroid,
        _albumDirectory = albumDirectory ?? defaultAlbumDirectory;

  static const String channelName = 'mankafe/album';

  /// 相册子目录名
  static const String albumName = 'Mankafe';

  static final AlbumSaver instance = AlbumSaver();

  /// 文件名里作品名最多保留的字数（按 rune 计，不按 UTF-16 code unit）
  static const int maxTitleRunes = 48;

  final MethodChannel _channel;
  final bool _onAndroid;
  final Future<Directory?> Function() _albumDirectory;

  bool get usesSystemAlbum => _onAndroid;

  static bool get defaultAlbumsOnAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 保存一页图，返回文件名
  Future<String> savePage(
    Uint8List bytes, {
    required String title,
    required int page,
  }) async {
    if (bytes.isEmpty) {
      throw const AlbumSaveException(AlbumSaveFailure.writeFailed, 'empty');
    }
    final format = ImageFormat.sniff(bytes);
    final name = fileName(title: title, page: page, extension: format.extension);
    if (_onAndroid) return _saveToAndroidAlbum(bytes, name, format.mime);
    return _saveToLocalAlbum(bytes, name);
  }

  Future<String> _saveToAndroidAlbum(
    Uint8List bytes,
    String name,
    String mime,
  ) async {
    try {
      final saved = await _channel.invokeMethod<String>('saveImage', {
        'bytes': bytes,
        'name': name,
        'mime': mime,
      });
      if (saved == null || saved.isEmpty) {
        throw const AlbumSaveException(
            AlbumSaveFailure.writeFailed, 'empty native result');
      }
      return saved;
    } on MissingPluginException catch (error) {
      // 壳里没有注册这个通道（例如跑在未改过原生代码的旧包里）
      throw AlbumSaveException(AlbumSaveFailure.unsupported, '$error');
    } on PlatformException catch (error) {
      final detail = error.message ?? error.code;
      switch (error.code) {
        case 'permission_denied':
          throw AlbumSaveException(AlbumSaveFailure.permissionDenied, detail);
        case 'unsupported':
          throw AlbumSaveException(AlbumSaveFailure.unsupported, detail);
        default:
          throw AlbumSaveException(AlbumSaveFailure.writeFailed, detail);
      }
    }
  }

  Future<String> _saveToLocalAlbum(Uint8List bytes, String name) async {
    final dir = await _albumDirectory();
    if (dir == null) {
      throw const AlbumSaveException(
          AlbumSaveFailure.unsupported, 'no album directory');
    }
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = await _uniqueFile(dir, name);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on FileSystemException catch (error) {
      throw AlbumSaveException(AlbumSaveFailure.writeFailed, '$error');
    }
  }

  /// `<Pictures>/Mankafe`
  static Future<Directory?> defaultAlbumDirectory() async {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final pictures =
          Directory('$home${Platform.pathSeparator}Pictures'
              '${Platform.pathSeparator}$albumName');
      try {
        if (!await pictures.exists()) {
          await pictures.create(recursive: true);
        }
        return pictures;
      } catch (error) {
        if (kDebugMode) debugPrint('[album] Pictures 目录不可用: $error');
      }
    }
    try {
      final documents = await getApplicationDocumentsDirectory();
      return Directory(
          '${documents.path}${Platform.pathSeparator}$albumName');
    } catch (error) {
      if (kDebugMode) debugPrint('[album] 没有可写目录: $error');
      return null;
    }
  }

  /// 生成文件名：`<作品> <章节>_<页码>.<ext>`
  static String fileName({
    required String title,
    required int page,
    required String extension,
  }) {
    final cleaned = truncate(sanitize(title), maxTitleRunes);
    final base = cleaned.isEmpty ? albumName : cleaned;
    final label = page < 1 ? 1 : page;
    return '${base}_${label.toString().padLeft(3, '0')}.$extension';
  }

  /// 清掉文件系统 / 相册不允许的字符，压掉多余空白，去掉首尾的点和空格
  static String sanitize(String raw) {
    return raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  }

  /// 按 rune 截断，避免把 emoji / 中文代理对切成半个字符
  static String truncate(String text, int maxRunes) {
    final runes = text.runes;
    if (runes.length <= maxRunes) return text;
    return runes.take(maxRunes).map(String.fromCharCode).join();
  }

  /// 同名文件已存在时加 ` (1)` / ` (2)` 后缀，绝不覆盖用户已有的图片
  static Future<File> _uniqueFile(Directory dir, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final extension = dot < 0 ? '' : name.substring(dot);
    var candidate = File('${dir.path}${Platform.pathSeparator}$name');
    var index = 1;
    while (await candidate.exists()) {
      candidate = File(
          '${dir.path}${Platform.pathSeparator}$stem ($index)$extension');
      index++;
    }
    return candidate;
  }
}
