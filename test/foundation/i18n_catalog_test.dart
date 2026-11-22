import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mankafe/l10n/app_localizations.dart';

/// 文案表的一致性检查：各语言 key 齐全、占位符对得上、没有空值。
/// 译者改完 JSON 后 `flutter test test/i18n_catalog_test.dart` 就能自证没改坏。
void main() {
  final i18n = Directory('assets/i18n');
  const sourceLocale = 'zh';

  final locales = i18n
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .toList()
    ..sort();

  Map<String, String> load(String locale, String file) {
    final path = '${i18n.path}${Platform.pathSeparator}$locale'
        '${Platform.pathSeparator}$file';
    return (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as String));
  }

  List<String> filesOf(String locale) {
    final dir = Directory('${i18n.path}${Platform.pathSeparator}$locale');
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .where((n) => n.endsWith('.json'))
        .toList()
      ..sort();
  }

  List<String> placeholders(String text) {
    final out = <String>[];
    for (final m in RegExp(r'{(\w+)}').allMatches(text)) {
      if (!out.contains(m.group(1))) out.add(m.group(1)!);
    }
    return out;
  }

  test('至少包含源语言目录', () {
    expect(Directory('${i18n.path}${Platform.pathSeparator}$sourceLocale').existsSync(),
        isTrue, reason: '缺少 i18n/$sourceLocale');
  });

  test('启动时能真的把 assets 里的文案读进来', () async {
    // 走生产环境那条路径（rootBundle + AssetManifest），顺便验证
    // pubspec.yaml 里每个语言目录都登记了资源。
    await AppLocalizations.load();
    for (final locale in AppLocalizations.supportedLocales) {
      final t = AppLocalizations(locale);
      expect(t.s('cancel'), isNot('cancel'),
          reason: '${locale.languageCode} 的 common.json 没被加载，'
              '检查 pubspec.yaml 的 assets 列表');
    }
  });

  for (final locale in locales) {
    test('$locale 与 $sourceLocale 的文件清单一致', () {
      expect(filesOf(locale), filesOf(sourceLocale));
    });
  }

  for (final locale in locales) {
    test('$locale 的 key、占位符与 $sourceLocale 对得上', () {
      for (final file in filesOf(sourceLocale)) {
        final src = load(sourceLocale, file);
        final dst = load(locale, file);
        final missing = src.keys.where((k) => !dst.containsKey(k)).toList();
        final extra = dst.keys.where((k) => !src.containsKey(k)).toList();
        expect(missing, isEmpty, reason: '$locale/$file 缺 key: $missing');
        expect(extra, isEmpty, reason: '$locale/$file 多 key: $extra');

        for (final key in src.keys) {
          final translated = dst[key] ?? '';
          expect(translated.trim(), isNotEmpty,
              reason: '$locale/$file 的 "$key" 是空文案');
          final want = placeholders(src[key]!);
          final got = placeholders(translated);
          // 复数单数形式允许把数字写成字面量（英文习惯写 "1 reply"）
          final lenient = key.endsWith('.one');
          expect(got.where((p) => !want.contains(p)), isEmpty,
              reason: '$locale/$file 的 "$key" 多出了源语言没有的占位符');
          if (!lenient) {
            expect(want.where((p) => !got.contains(p)), isEmpty,
                reason: '$locale/$file 的 "$key" 占位符不一致：'
                    '$sourceLocale=$want, $locale=$got');
          }
        }
      }
    });
  }
}
