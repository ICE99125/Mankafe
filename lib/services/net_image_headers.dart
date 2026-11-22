import 'device_profile.dart';

/// 图片请求头，图床按 referer / user-agent 判断来源，不带会被拒绝
const Map<String, String> imageHeaders = {
  'user-agent': DeviceProfile.userAgent,
  'referer': DeviceProfile.referer,
  'accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
};
