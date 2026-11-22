import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mankafe/services/album_saver.dart';

const MethodChannel _channel = MethodChannel(AlbumSaver.channelName);

Uint8List pngBytes() => Uint8List.fromList(
    <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1]);

Uint8List jpegBytes() =>
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);

/// 图床按 `webp: 1` 下发的 WebP 字节：`RIFF....WEBP`。
Uint8List webpBytes() => Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x20, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('文件名', () {
    test('章节名里的路径分隔符 / 非法字符换成空格，页码补零', () {
      // 章节名常见 `第01话 / A:B*C?`：斜杠在 Windows 上会被当成目录分隔符。
      expect(
        AlbumSaver.fileName(
            title: '第01话 / A:B*C?', page: 3, extension: 'jpg'),
        '第01话 A B C_003.jpg',
      );
    });

    test('空标题退回相册名，页码小于 1 按第 1 页', () {
      expect(AlbumSaver.fileName(title: '   ', page: 0, extension: 'png'),
          '${AlbumSaver.albumName}_001.png');
    });

    test('结尾的点与空格去掉（Windows 上无法创建这种文件名）', () {
      expect(AlbumSaver.sanitize('Vol.1. '), 'Vol.1');
    });

    test('超长作品名按 rune 截断，不切坏中文 / emoji', () {
      final title = '月' * 80;
      final name = AlbumSaver.fileName(title: title, page: 12, extension: 'webp');
      expect(name.endsWith('_012.webp'), isTrue);
      expect(AlbumSaver.truncate(title, AlbumSaver.maxTitleRunes).length,
          AlbumSaver.maxTitleRunes);
      expect(AlbumSaver.truncate('😀😀😀', 2), '😀😀');
    });
  });

  group('格式识别', () {
    test('按文件头判断，URL 后缀不参与', () {
      expect(ImageFormat.sniff(pngBytes()).extension, 'png');
      expect(ImageFormat.sniff(jpegBytes()).extension, 'jpg');
      expect(ImageFormat.sniff(webpBytes()).extension, 'webp');
      expect(ImageFormat.sniff(webpBytes()).mime, 'image/webp');
    });

    test('无法识别的字节按 JPEG 兜底（仍然能存下来）', () {
      expect(
          ImageFormat.sniff(Uint8List.fromList(<int>[1, 2, 3])).extension, 'jpg');
    });
  });

  group('Android 原生通道', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('把字节 / 文件名 / MIME 交给 saveImage，返回原生落盘路径', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return 'Pictures/Mankafe/碧藍之海 第01话_007.webp';
      });

      final saver = AlbumSaver(channel: _channel, onAndroid: true);
      final path = await saver.savePage(webpBytes(),
          title: '碧藍之海 第01话', page: 7);

      expect(path, 'Pictures/Mankafe/碧藍之海 第01话_007.webp');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveImage');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['name'], '碧藍之海 第01话_007.webp');
      expect(args['mime'], 'image/webp');
      expect((args['bytes'] as Uint8List).length, webpBytes().length);
    });

    test('没有写入权限时抛 permissionDenied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'permission_denied', message: '没有存储写入权限');
      });

      final saver = AlbumSaver(channel: _channel, onAndroid: true);
      await expectLater(
        saver.savePage(jpegBytes(), title: '作品', page: 1),
        throwsA(isA<AlbumSaveException>().having(
            (e) => e.reason, 'reason', AlbumSaveFailure.permissionDenied)),
      );
    });

    test('原生返回空路径算失败，不当成保存成功', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => '');

      final saver = AlbumSaver(channel: _channel, onAndroid: true);
      await expectLater(
        saver.savePage(jpegBytes(), title: '作品', page: 1),
        throwsA(isA<AlbumSaveException>().having(
            (e) => e.reason, 'reason', AlbumSaveFailure.writeFailed)),
      );
    });

    test('空字节直接失败，不发原生调用', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return 'x';
      });
      final saver = AlbumSaver(channel: _channel, onAndroid: true);
      await expectLater(
        saver.savePage(Uint8List(0), title: '作品', page: 1),
        throwsA(isA<AlbumSaveException>()),
      );
      expect(calls, isEmpty);
    });
  });

  group('桌面回落（没有系统相册）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('album_saver_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('写进相册目录：文件名带页码、扩展名跟着真实格式', () async {
      final saver = AlbumSaver(
        onAndroid: false,
        albumDirectory: () async => dir,
      );
      final path = await saver.savePage(webpBytes(),
          title: '碧藍之海 第01话', page: 2);

      expect(path.startsWith(dir.path), isTrue);
      expect(path.endsWith('碧藍之海 第01话_002.webp'), isTrue);
      final file = File(path);
      expect(await file.exists(), isTrue);
      expect((await file.readAsBytes()).length, webpBytes().length);
    });

    test('同名再存一次不覆盖，加序号', () async {
      final saver = AlbumSaver(
        onAndroid: false,
        albumDirectory: () async => dir,
      );
      final first = await saver.savePage(pngBytes(), title: '作品', page: 1);
      final second = await saver.savePage(pngBytes(), title: '作品', page: 1);

      expect(first, isNot(second));
      expect(second.endsWith('作品_001 (1).png'), isTrue);
      expect(await File(first).exists(), isTrue);
    });

    test('相册目录不可用时报 unsupported，而不是假装成功', () async {
      final saver = AlbumSaver(
        onAndroid: false,
        albumDirectory: () async => null,
      );
      await expectLater(
        saver.savePage(pngBytes(), title: '作品', page: 1),
        throwsA(isA<AlbumSaveException>().having(
            (e) => e.reason, 'reason', AlbumSaveFailure.unsupported)),
      );
    });
  });
}
