import 'dart:convert';

import 'package:crypto/crypto.dart';

/// X-Auth-Signature 算法：HMAC-SHA256(key=tapString, msg=秒级时间戳) 的小写 hex
String authSignature({
  required String tapString,
  required int timestampSeconds,
}) {
  final digest = Hmac(sha256, utf8.encode(tapString))
      .convert(utf8.encode('$timestampSeconds'));
  return lowerHex(digest.bytes);
}

String lowerHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
