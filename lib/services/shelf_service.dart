import 'package:flutter/foundation.dart';

import '../models/comic.dart';
import '../models/media_page.dart';
import '../state/app_state.dart';
import 'repository.dart';

/// ShelfService — 收藏的统一入口：未登录写本地，已登录写云端
class ShelfService extends ChangeNotifier {
  final Repository repo;
  final AppState state;

  ShelfService({required this.repo, required this.state});

  /// 收藏状态：已登录以服务端为准，未登录才看本地
  bool isFavorite(String pathWord, {MediaKind kind = MediaKind.comic}) =>
      state.isFavorite(pathWord, kind: kind);

  /// 切换收藏，返回切换后的状态
  Future<bool> toggle(
    Comic comic, {
    MediaKind kind = MediaKind.comic,
    bool? currentIsFavorite,
  }) async {
    final before =
        currentIsFavorite ?? state.isFavorite(comic.pathWord, kind: kind);
    final next = !before;
    if (!state.isLoggedIn) {
      await state.setLocalFavorite(comic, next, kind: kind);
      notifyListeners();
      return next;
    }
    await repo.setCollected(
      comic.uuid.isNotEmpty ? comic.uuid : comic.pathWord,
      collected: next,
      kind: kind,
    );
    notifyListeners();
    return next;
  }

  /// 把本地收藏补到云端
  Future<int> syncLocalToCloud() async {
    if (!state.isLoggedIn) return 0;
    final pending = List.of(state.localFavorites);
    if (pending.isEmpty) return 0;
    var done = 0;
    for (final entry in pending) {
      try {
        await repo.setCollected(
          entry.uuid.isNotEmpty ? entry.uuid : entry.pathWord,
          collected: true,
          kind: entry.kind,
        );
        done++;
      } catch (_) {
        break;
      }
    }
    if (done > 0) {
      // 只清掉已确认上传成功的那些，失败的留着下次重试
      final synced = pending.take(done).map((e) => e.key).toSet();
      final remain = state.localFavorites.where((e) => !synced.contains(e.key));
      await state.retainLocalFavorites(remain.map((e) => e.key).toSet());
      notifyListeners();
    }
    return done;
  }

  /// 书架拉到云端总数后同步给个人页统计
  void reportCloudCount(int total) => state.setCloudFavoriteCount(total);
}
