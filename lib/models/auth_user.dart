/// AuthUser — 登录返回的账号信息
class AuthUser {
  final String userId;
  final String userName;
  final String nickname;
  final String avatar;
  final bool isAuthenticated;

  /// 性别编码：0 未知 / 1 男 / 2 女
  final int gender;

  const AuthUser({
    this.userId = '',
    this.userName = '',
    this.nickname = '',
    this.avatar = '',
    this.isAuthenticated = false,
    this.gender = 0,
  });

  String get displayName {
    if (nickname.trim().isNotEmpty) return nickname;
    if (userName.trim().isNotEmpty) return userName;
    return userId;
  }

  AuthUser copyWith({
    String? nickname,
    int? gender,
    String? avatar,
  }) =>
      AuthUser(
        userId: userId,
        userName: userName,
        nickname: nickname ?? this.nickname,
        avatar: avatar ?? this.avatar,
        isAuthenticated: isAuthenticated,
        gender: gender ?? this.gender,
      );

  static int _intOf(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final name =
        (json['nickname'] ?? json['username'] ?? json['user_name'] ?? '')
            .toString();
    return AuthUser(
      userId: (json['user_id'] ?? '').toString(),
      userName: (json['username'] ?? json['user_name'] ?? '').toString(),
      nickname: name,
      avatar: (json['avatar'] ?? '').toString(),
      isAuthenticated: json['is_authenticated'] == true ||
          (json['user_id'] ?? '').toString().isNotEmpty,
      gender: _intOf(json['gender']),
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'username': userName,
        'nickname': nickname,
        'avatar': avatar,
        'is_authenticated': isAuthenticated,
        'gender': gender,
      };
}
