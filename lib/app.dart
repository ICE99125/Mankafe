import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'l10n/app_localizations_strings.dart';
import 'screens/bootstrap_screen.dart';
import 'services/api_client.dart';
import 'services/download_manager.dart';
import 'services/repository.dart';
import 'services/route_manager.dart';
import 'services/shelf_service.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'utils/frame_kick.dart';

/// MankafeApp — 应用根组件，注入 Provider、主题与本地化
class MankafeApp extends StatelessWidget {
  const MankafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>(create: (_) => AppState()..load()),
        ChangeNotifierProvider<RouteManager>(create: (_) => RouteManager()),
        Provider<Repository>(
          create: (ctx) => Repository(
            ApiClient(
              ctx.read<RouteManager>(),
              token: () => ctx.read<AppState>().authToken,
              onUnauthorized: () =>
                  ctx.read<AppState>().clearSession(expired: true),
            ),
            ctx.read<RouteManager>(),
            ctx.read<AppState>(),
          ),
        ),
        // 离线下载
        ChangeNotifierProvider<DownloadManager>(
          create: (ctx) =>
              DownloadManager(repo: ctx.read<Repository>())..init(),
        ),
        // 收藏：未登录写本地，已登录写云端
        ChangeNotifierProvider<ShelfService>(
          create: (ctx) => ShelfService(
            repo: ctx.read<Repository>(),
            state: ctx.read<AppState>(),
          ),
        ),
      ],
      child: Consumer<AppState>(
        builder: (context, app, _) {
          final seed = AppTheme.seedOf(app.seedIndex);
          return MaterialApp(
            onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appName,
            debugShowCheckedModeBanner: false,
            locale: app.language.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: AppTheme.light(seed),
            darkTheme: AppTheme.dark(seed),
            themeMode: app.themeMode,
            // 鼠标也能按住拖动滚动
            scrollBehavior: const AppScrollBehavior(),
            navigatorObservers: [ForceFrameObserver()],
            // 首屏是链路检测页，不是开机闪屏
            home: const BootstrapScreen(),
          );
        },
      ),
    );
  }
}
