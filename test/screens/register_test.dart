import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:mankafe/l10n/app_localizations.dart';
import 'package:mankafe/screens/login_screen.dart';
import 'package:mankafe/services/api_client.dart';
import 'package:mankafe/services/http_cache.dart';
import 'package:mankafe/services/repository.dart';
import 'package:mankafe/services/route_manager.dart';
import 'package:mankafe/state/app_state.dart';
import 'package:mankafe/theme/app_theme.dart';

/// 注册页回归：校验顺序、提交表单（字段 / 密码加盐编码）、成功后的回跳。
///
/// 接口与字段来源见 `ApiEndpoints.register` 的注释：路径取自 base.apk 的
/// libapp.so，表单与登录同源，邀请码为原版的可选字段。
void main() {
  _Harness newHarness() => _Harness();

  Future<void> pumpLogin(WidgetTester tester, _Harness h) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_app(h, const LoginScreen()));
    await tester.pump();
  }

  Future<void> openRegister(WidgetTester tester) async {
    await tester.tap(find.text('还没有账号？注册'));
    await tester.pumpAndSettle();
    expect(find.text('注册账号'), findsOneWidget);
  }

  testWidgets('空用户名不发请求，直接提示', (tester) async {
    final h = newHarness();
    await pumpLogin(tester, h);
    await openRegister(tester);

    await tester.tap(find.text('注册账号'));
    await tester.pump();

    expect(find.text('请输入用户名'), findsOneWidget);
    expect(h.requests, isEmpty);
  });

  testWidgets('两次密码不一致 / 密码格式不对都在本地拦下', (tester) async {
    final h = newHarness();
    await pumpLogin(tester, h);
    await openRegister(tester);

    await tester.enterText(find.byType(TextField).at(0), 'reader');
    await tester.enterText(find.byType(TextField).at(1), 'abc12345');
    await tester.enterText(find.byType(TextField).at(2), 'abc1234');
    await tester.tap(find.text('注册账号'));
    await tester.pump();
    expect(find.text('输入的密码不一致'), findsOneWidget);
    expect(h.requests, isEmpty);

    // 格式不对优先于「不一致」：1 位密码直接撞密码规则。
    await tester.enterText(find.byType(TextField).at(1), 'a');
    await tester.enterText(find.byType(TextField).at(2), 'a');
    await tester.tap(find.text('注册账号'));
    await tester.pump();
    expect(find.text('密码格式不对：6–20 位，且不含空格'), findsOneWidget);
    expect(h.requests, isEmpty);
  });

  testWidgets('邀请码留空时不提交 invite_code', (tester) async {
    final h = newHarness();
    await pumpLogin(tester, h);
    await openRegister(tester);

    await tester.enterText(find.byType(TextField).at(0), 'reader');
    await tester.enterText(find.byType(TextField).at(1), 'abc12345');
    await tester.enterText(find.byType(TextField).at(2), 'abc12345');
    await tester.tap(find.text('注册账号'));
    await tester.pumpAndSettle();

    expect(h.requests, hasLength(1));
    expect(h.requests.single.form.containsKey('invite_code'), isFalse);
  });

  testWidgets('提交携带登录同源字段与加盐密码，成功后回登录页并回填用户名',
      (tester) async {
    final h = newHarness();
    await pumpLogin(tester, h);
    await openRegister(tester);

    await tester.enterText(find.byType(TextField).at(0), 'reader');
    await tester.enterText(find.byType(TextField).at(1), 'abc12345');
    await tester.enterText(find.byType(TextField).at(2), 'abc12345');
    await tester.enterText(find.byType(TextField).at(3), 'FRIEND01');

    await tester.tap(find.text('注册账号'));
    await tester.pumpAndSettle();

    expect(h.requests, hasLength(1));
    final request = h.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v3/register');
    expect(request.query, contains('platform=3'));

    final form = request.form;
    expect(form['username'], 'reader');
    expect(form['invite_code'], 'FRIEND01');
    expect(form['platform'], '3');
    expect(form['authorization'], 'Token ');
    expect(form['source'], 'copyApp');
    final salt = form['salt']!;
    expect(salt, matches(RegExp(r'^\d{3}$')));
    // 密码 = base64(明文 + "-" + salt)，与 Repository.login 同一变换。
    expect(utf8.decode(base64Decode(form['password']!)), 'abc12345-$salt');

    expect(find.text('注册成功'), findsOneWidget);
    await tester.tap(find.text('前往登录'));
    await tester.pumpAndSettle();

    // 回到登录页（标题与按钮都写「登录」），用户名已回填，密码没有带过去。
    expect(find.text('登录'), findsWidgets);
    final username = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(username.controller?.text, 'reader');
    final password = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(password.controller?.text, isEmpty);
  });

  testWidgets('服务端业务错误原样提示', (tester) async {
    final h = newHarness()..errorMessage = '該用戶名已被註冊';
    await pumpLogin(tester, h);
    await openRegister(tester);

    await tester.enterText(find.byType(TextField).at(0), 'reader');
    await tester.enterText(find.byType(TextField).at(1), 'abc12345');
    await tester.enterText(find.byType(TextField).at(2), 'abc12345');

    await tester.tap(find.text('注册账号'));
    await tester.pumpAndSettle();

    expect(find.text('注册失败：該用戶名已被註冊'), findsOneWidget);
    expect(find.text('注册成功'), findsNothing);
  });
}

class _Captured {
  _Captured(this.method, this.path, this.query, this.form);
  final String method;
  final String path;
  final String query;
  final Map<String, String> form;
}

class _Harness {
  late final AppState state;
  late final RouteManager routes;
  late final Repository repo;

  final List<_Captured> requests = [];
  String? errorMessage;

  _Harness() {
    state = AppState();
    routes = RouteManager()..autoFallback = false;
    final client = MockClient((request) async {
      if (request.url.path != '/api/v3/register') {
        return http.Response(
          jsonEncode({'code': 404, 'message': 'unexpected', 'results': null}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      requests.add(_Captured(
        request.method,
        request.url.path,
        request.url.query,
        Uri.splitQueryString(request.body),
      ));
      final error = errorMessage;
      return http.Response(
        jsonEncode({
          'code': error == null ? 200 : 210,
          'message': error ?? 'ok',
          'results': null,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    repo = Repository(
      ApiClient(routes, httpClient: client, cache: _NoCache()),
      routes,
      state,
    );
  }
}

Widget _app(_Harness h, Widget home) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: h.state),
        ChangeNotifierProvider<RouteManager>.value(value: h.routes),
        Provider<Repository>.value(value: h.repo),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.light(AppTheme.seedOf(0)),
        home: home,
      ),
    );

/// 测试专用缓存：一律不缓存，避开 `flutter test` 里 dart:io 的磁盘 IO。
class _NoCache extends HttpCache {
  @override
  Duration? ttlFor(String path) => null;
}
