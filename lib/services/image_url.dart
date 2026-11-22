import 'package:flutter/foundation.dart';

import 'device_profile.dart';

/// 把图片路径拼成完整 URL，已是完整地址则原样返回，主机未知时返回 null
String? resolveImageUrl(String path, {String? host}) {
  final p = path.trim();
  if (p.isEmpty) return null;
  if (p.startsWith('http://') || p.startsWith('https://')) return p;

  var base = (host ?? '').trim();
  if (base.isEmpty) base = DeviceProfile.fallbackImageHost;
  if (base.isEmpty) {
    if (kDebugMode) {
      debugPrint('[avatar] 无法拼接图片 URL：path=$p，图片主机为空');
    }
    return null;
  }
  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = 'https://$base';
  }
  if (base.endsWith('/')) base = base.substring(0, base.length - 1);
  final rel = p.startsWith('/') ? p.substring(1) : p;
  return '$base/$rel';
}

/// 从 URL 的 .宽x高.jpg 后缀读出宽高比，没有后缀时退回 fallback
double imageAspect(String url, {double fallback = 2.5}) {
  final m = RegExp(r'\.(\d+)x(\d+)\.(?:jpg|jpeg|png|webp)$').firstMatch(url);
  final w = int.tryParse(m?.group(1) ?? '');
  final h = int.tryParse(m?.group(2) ?? '');
  if (w != null && h != null && w > 0 && h > 0) return w / h;
  return fallback;
}
