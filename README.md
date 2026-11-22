# 漫咖 · Mankafe

要求 Flutter 3.27+ / Dart 3.6+

## 开启模拟器

```bash
flutter emulators
flutter emulators --launch Pixel_10_Pro_API_36
```

## 运行

```bash
flutter pub get
flutter run
```

## 打包

```bash
flutter build apk --release
```

## 代码结构

```
lib/
  ├── l10n/
  ├── models/
  ├── screens/
  ├── services/
  ├── state/
  ├── theme/
  ├── widgets/
  └── utils/
```

## 多语言

```
assets/
  └── i18n/
       ├── README.md
       ├── zh/
       └── en/
```

## 测试用例

```
integration_test/
test/
  ├── flutter_test_config.dart
  ├── foundation/
  ├── network/
  ├── services/
  ├── widgets/
  └── screens/
```

## 文档

```
docs/
  ├── api.md
  ├── md3-ui.md
  └── proxy.md
```
