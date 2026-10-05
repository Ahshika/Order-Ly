// بيشغّل البرنامج الحقيقي على ويندوز (سيرفر حقيقي في Isolate على فولدر مؤقت) ويجرب صور الأصناف واللوجو وعرض الصورة،
// وبيقيس أطول وقت الشاشة وقفت فيه. عمره ما بيلمس بيانات حقيقية.
// التشغيل:  flutter test integration_test -d windows
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/app_config.dart';
import 'package:orderly/src/core/cafe_models.dart';
import 'package:orderly/src/core/models.dart';
import 'package:orderly/src/core/session.dart';
import 'package:orderly/src/core/theme.dart';
import 'package:orderly/src/features/menu/item_editor.dart';
import 'package:orderly/src/features/settings/cafe_settings_screen.dart';
import 'package:orderly/src/server/server_host.dart';
import 'package:orderly/src/widgets/server_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Session extends SessionController {
  _Session(this.api, this.info);
  final ApiClient api;
  final ServerInfo info;

  @override
  Future<Session> build() async => Session(SessionStatus.ready,
      api: api, info: info, user: AppUser(id: 'u', name: 'أحمد', username: 'owner', role: Role.owner, active: true));
}

class _Picker extends FileSelectorPlatform {
  _Picker(this.path);
  final String path;
  @override
  Future<XFile?> openFile({List<XTypeGroup>? acceptedTypeGroups, String? initialDirectory, String? confirmButtonText}) async => XFile(path);
}

/// صورة موبايل كبيرة (12 ميجابكسل) فيها تفاصيل كتير زي الصور الحقيقية.
Uint8List _bigPhoto() {
  final im = img.Image(width: 4000, height: 3000);
  for (final p in im) {
    p.setRgb((p.x * 7 + p.y * 3) % 256, (p.x * p.y) % 256, (p.y * 11) % 256);
  }
  return img.encodeJpg(im, quality: 92);
}

/// أطول فترة الـ isolate بتاع الشاشة كان واقف فيها.
class _Gaps {
  final _sw = Stopwatch()..start();
  int _last = 0;
  int worst = 0;
  late final Timer _t = Timer.periodic(const Duration(milliseconds: 50), (_) {
    final now = _sw.elapsedMilliseconds;
    if (now - _last > worst) worst = now - _last;
    _last = now;
  });
  void reset() {
    _t;
    _last = _sw.elapsedMilliseconds;
    worst = 0;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('صور الأصناف واللوجو وعرض الصورة ما بيوقفوش الشاشة', (tester) async {
    final dir = await Directory.systemTemp.createTemp('orderly_img');
    final port = await ServerHost.start(dir.path, port: 18771);
    final api = ApiClient('http://127.0.0.1:$port');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه تجربة', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    var menu = await api.get('/api/menu');
    final bar = ((menu['stations'] as List).first as Map)['id'];
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': bar});
    menu = await api.get('/api/menu');
    final cat = ((menu['categories'] as List).first as Map)['id'];
    await api.post('/api/items', {'categoryId': cat, 'name': 'لاتيه', 'priceCents': 6000});
    final data = MenuData(await api.get('/api/menu', query: {'all': '1'}));

    final photo = File('${dir.path}/photo.jpg')..writeAsBytesSync(await Isolate.run(_bigPhoto));
    debugPrint('PHOTO ${photo.lengthSync() ~/ 1024} KB');
    FileSelectorPlatform.instance = _Picker(photo.path);

    SharedPreferences.setMockInitialValues({});
    final config = await AppConfig.load();
    final info = ServerInfo.fromJson(await api.get('/api/info'));
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      retry: (_, _) => null,
      overrides: [appConfigProvider.overrideWithValue(config), sessionProvider.overrideWith(() => _Session(api, info))],
      child: MaterialApp(
        navigatorKey: nav,
        locale: const Locale('ar', 'EG'),
        supportedLocales: const [Locale('ar', 'EG')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(Brightness.light),
        home: Consumer(builder: (context, ref, _) => ref.watch(sessionProvider).hasValue ? ItemEditor(menu: data, item: data.items.first) : const SizedBox()),
      ),
    ));
    final gaps = _Gaps()..reset();

    Future<void> waitFor(bool Function() done, String what) async {
      final sw = Stopwatch()..start();
      while (!done()) {
        if (sw.elapsed > const Duration(seconds: 90)) fail('$what خد أكتر من دقيقة ونص (أسوأ وقفة ${gaps.worst} ms)');
        if (sw.elapsed.inSeconds % 5 == 0 && sw.elapsedMilliseconds % 5000 < 100) debugPrint('  ...$what ${sw.elapsed.inSeconds}s worst ${gaps.worst} ms snack=${find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).toList()} busy=${find.byType(CircularProgressIndicator).evaluate().length}');
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('$what: ${sw.elapsedMilliseconds} ms, worst UI stall ${gaps.worst} ms');
    }

    // 1) صورة الصنف
    await tester.pump(const Duration(milliseconds: 500));
    gaps.reset();
    await tester.tap(find.text('صورة الصنف'));
    await waitFor(() => find.byType(ServerImage).evaluate().isNotEmpty, 'ITEM IMAGE upload');
    final imageId = (await api.get('/api/menu', query: {'all': '1'}))['items'][0]['imageId'] as String;
    await tester.pump(const Duration(seconds: 2));
    debugPrint('ITEM IMAGE shown, worst UI stall ${gaps.worst} ms');
    expect(gaps.worst, lessThan(1500));

    // 2) عرض الصورة كبيرة
    gaps.reset();
    unawaited(showImageViewer(nav.currentContext!, imageId));
    await tester.pump(const Duration(seconds: 3));
    debugPrint('VIEWER worst UI stall ${gaps.worst} ms');
    expect(gaps.worst, lessThan(1500));
    nav.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 500));

    // 3) لوجو الكافيه
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const CafeSettingsScreen())));
    await waitFor(() => find.text('اللوجو').evaluate().isNotEmpty, 'SETTINGS open');
    gaps.reset();
    await tester.tap(find.text('اللوجو'));
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 30) && (await api.get('/api/shop'))['logoBase64'] == null) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(seconds: 2));
    debugPrint('LOGO done in ${sw.elapsedMilliseconds} ms, worst UI stall ${gaps.worst} ms, err=${tester.takeException()}');
    expect(gaps.worst, lessThan(1500));

    final serverLog = File('${dir.path}/logs/server.log').readAsStringSync();
    debugPrint('SERVER LOG ERRORS: ${'[ERROR]'.allMatches(serverLog).length}');
    expect(serverLog, isNot(contains('hijacked')));
    api.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
