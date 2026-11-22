import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

export 'app_localizations_strings.dart' show AppLocalizationsStrings;

/// AppLanguage — 界面语言偏好，system 表示跟随系统
enum AppLanguage { system, zh, en }

/// AppLanguage 对应的 Locale
extension AppLanguageX on AppLanguage {
  /// null 时使用系统语言
  Locale? get locale => switch (this) {
        AppLanguage.system => null,
        AppLanguage.zh => const Locale('zh', 'CN'),
        AppLanguage.en => const Locale('en'),
      };
}

/// AppLocalizations — 自有本地化，文案来自 assets/i18n/*.json
class AppLocalizations {
  const AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) =>
      AppLocalizations(Localizations.localeOf(context));

  /// 支持的语言
  static const supportedLocales = <Locale>[Locale('zh', 'CN'), Locale('en')];

  bool get isZh => locale.languageCode == 'zh';

  /// 启动时读取 assets/i18n/ 下所有 JSON，单个文件失败不阻断启动
  static Future<void> load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest
          .listAssets()
          .where((key) => key.startsWith(_assetPrefix) && key.endsWith('.json'));
      for (final key in assets) {
        final parts = key.substring(_assetPrefix.length).split('/');
        if (parts.length != 2) continue;
        try {
          addJson(parts[0], await rootBundle.loadString(key));
        } catch (error, stack) {
          debugPrint('i18n: 读取 $key 失败：$error\n$stack');
        }
      }
    } catch (error, stack) {
      debugPrint('i18n: 资源清单不可用：$error\n$stack');
    }
  }

  static const String _assetPrefix = 'assets/i18n/';

  static final Map<String, Map<String, String>> _tables =
      <String, Map<String, String>>{};

  /// 合并一份文案 JSON，key 到文案
  static void addJson(String languageCode, String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      debugPrint('i18n: $languageCode 的文案不是 JSON 对象');
      return;
    }
    final table = _tables.putIfAbsent(languageCode, () => <String, String>{});
    decoded.forEach((key, value) {
      if (value is String) {
        table[key] = value;
      }
    });
  }

  /// 取一条文案，{name} 占位符按 args 替换，缺失时回退到 key
  String s(String key, [Map<String, Object?> args = const <String, Object?>{}]) {
    final text = _tables[locale.languageCode]?[key] ??
        _tables['en']?[key] ??
        _tables['zh']?[key] ??
        key;
    if (args.isEmpty) return text;
    return text.replaceAllMapped(_placeholder, (match) {
      final name = match.group(1)!;
      return (args[name] ?? match.group(0)!).toString();
    });
  }

  static final RegExp _placeholder = RegExp(r'{(\w+)}');

  /// 主题种子色的名字，index 超出0..5 时用 seedFallback
  String seedLabel(int index) =>
      index >= 0 && index < 6 ? s('seed$index') : s('seedFallback');

  String genderLabel(int value) => switch (value) {
        1 => s('genderMale'),
        2 => s('genderFemale'),
        _ => s('genderUnknown'),
      };

  /// 按当前 locale 格式化日期
  String formatDate(DateTime date) =>
      DateFormat.yMd(locale.toLanguageTag()).format(date);
}
