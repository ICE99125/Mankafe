import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'net_image.dart';
import '../services/image_url.dart';

/// UserAvatar — 圆形头像，无 URL 或加载失败时回退首字母 / 人形图标
class UserAvatar extends StatelessWidget {
  /// 接口返回的原始头像字段，可能是相对路径或完整 URL
  final String avatar;

  /// 图片主机，用于拼接相对路径
  final String? host;
  final String fallbackText;
  final double size;
  final Color backgroundColor;
  final Color foregroundColor;

  const UserAvatar({
    super.key,
    required this.avatar,
    this.host,
    this.fallbackText = '',
    this.size = 60,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final raw = avatar.trim();
    final url = resolveImageUrl(raw, host: host);
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: url == null
            ? _fallback()
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                headers: imageHeaders,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _loading(),
                errorBuilder: (context, error, stackTrace) {
                  if (kDebugMode) {
                    debugPrint('[avatar] 加载失败 url=$url error=$error');
                  }
                  return _fallback();
                },
              ),
      ),
    );
  }

  /// 加载中：只显示底色，不冒充加载失败
  Widget _loading() => Container(color: backgroundColor);

  Widget _fallback() {
    final letter = fallbackText.trim();
    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: letter.isEmpty
          ? Icon(Icons.person_rounded,
              size: size * 0.55, color: foregroundColor)
          : Text(
              letter.characters.first.toUpperCase(),
              style: TextStyle(
                color: foregroundColor,
                fontSize: size * 0.4,
                fontWeight: FontWeight.w500,
              ),
            ),
    );
  }
}
