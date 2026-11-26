// اختبار حقيقي على Firebase (محتاج نت): ربط المالك من بره بالقواعد المرفوعة. كافيه مؤقت، ومالك، وحساب غريب.
// كل حاجة بتتمسح في الآخر (البيانات والحسابات).
// التشغيل:  flutter test test_cloud/owner_cloud_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/firebase_config.dart';
import 'package:orderly/src/server/api_server.dart';

/// حساب Firebase بيكلم القاعدة مباشرة، زي أبلكيشن المالك أو أي حد معاه المفتاح العام.
class _Raw {
  _Raw(this.uid, this.token);
  final String uid;
  final String token;

  static Future<_Raw> create(String tag) async {
    final email = 'owner-test-${DateTime.now().microsecondsSinceEpoch}-$tag@test.orderly.app';
    final res = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$firebaseApiKey'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': 'Test-${Random().nextInt(1 << 30)}x', 'returnSecureToken': true}),
    );
    if (res.statusCode != 200) throw StateError('auth ${res.statusCode}: ${res.body}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return _Raw(j['localId'] as String, j['idToken'] as String);
  }

  Future<(int, Object?)> send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$rtdbUrl/$path.json').replace(queryParameters: {'auth': token}));
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send());
    return (res.statusCode, res.statusCode == 200 ? jsonDecode(res.body) : null);
  }

  Future<int> status(String method, String path, [Object? body]) async => (await send(method, path, body)).$1;

  Future<void> deleteAccount() => http.post(
        Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$firebaseApiKey'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'idToken': token}),
      );
}

void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;
  final raws = <_Raw>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_owner_live');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, pushSender: (sub, msg, vapid) async => throw StateError('no real push in this test'));
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'اختبار المالك', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    await server.syncNow();
  });

  tearDown(() async {
    for (final r in raws) {
      // أي حاجة الحساب ده كتبها باسمه (لو الاختبار وقف في النص)
      await r.status('DELETE', 'cafes/${r.uid}');
      await r.deleteAccount();
    }
    raws.clear();
    await server.cleanupCloudForTests();
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  test('owner links with the one-time code and reads reports; everyone else is refused', () async {
    final main = server.db.setting('cloud_uid')!;
    final owner = await _Raw.create('owner');
    final stranger = await _Raw.create('stranger');
    raws.addAll([owner, stranger]);
    final code = ((await api.post('/api/owner/code'))['code'] as Map)['code'] as String;

    // كود غلط: مرفوض. الكود نفسه محدش يقراه
    expect(await owner.status('PUT', 'own/$main/claim/${owner.uid}', {'c': 'ZZZZ2222', 'name': 'x', 'email': 'x', 'at': {'.sv': 'timestamp'}}), 401);
    expect(await stranger.status('GET', 'own/$main/code'), 401);
    // حد بيكتب طلب باسم حد تاني: مرفوض
    expect(await stranger.status('PUT', 'own/$main/claim/${owner.uid}', {'c': code, 'name': 'x', 'email': 'x', 'at': {'.sv': 'timestamp'}}), 401);
    // طلب صح
    expect(await owner.status('PUT', 'own/$main/claim/${owner.uid}', {'c': code, 'name': 'المالك', 'email': 'o@test', 'at': {'.sv': 'timestamp'}}), 200);
    // قبل الموافقة: مايقراش حاجة
    expect(await owner.status('GET', 'own/$main/shops'), 401);

    await server.syncNow();
    expect((await owner.send('GET', 'own/$main/ok/${owner.uid}')).$2, isA<Map>());
    // الكود اتستخدم: الغريب مايقدرش يستخدمه بعد كده
    expect(await stranger.status('PUT', 'own/$main/claim/${stranger.uid}', {'c': code, 'name': 'x', 'email': 'x', 'at': {'.sv': 'timestamp'}}), 401);

    // المالك: الفروع والمفتاح العام آه، المفتاح الخاص لأ
    expect(((await owner.send('GET', 'own/$main/shops')).$2 as Map).containsKey(main), isTrue);
    expect((await owner.send('GET', 'own/$main/vapid/pub')).$2, isA<String>());
    expect(await owner.status('GET', 'own/$main/vapid/priv'), 401);
    expect(await owner.status('GET', 'own/$main/ok'), 401, reason: 'no list of other owners');

    // تقرير وردية: المالك يقراه، والغريب لأ
    await api.post('/api/register/open', {'openingCashCents': 0});
    await api.post('/api/register/close', {'countedCashCents': 0});
    await server.syncNow();
    final (st, days) = await owner.send('GET', 'rep/$main');
    expect(st, 200);
    expect((days as Map).isNotEmpty, isTrue);
    expect(await stranger.status('GET', 'rep/$main'), 401);
    // الفرع وهو شغال: المالك يقراه، والغريب لأ، والمالك مايكتبش فيه
    expect((await owner.send('GET', 'live/$main')).$2, isA<Map>());
    expect(await stranger.status('GET', 'live/$main'), 401);
    expect(await owner.status('PUT', 'live/$main', {'j': '{}', 'at': {'.sv': 'timestamp'}}), 401);
    // ومايكتبش في التقارير
    expect(await owner.status('PUT', 'rep/$main/2026-01-01/day', {'j': '{}', 'at': {'.sv': 'timestamp'}}), 401);

    // اشتراك إشعارات: المالك المربوط بس، وفي مكانه هو بس
    final sub = {'s': '{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"a","auth":"b"}}', 'at': {'.sv': 'timestamp'}};
    expect(await owner.status('PUT', 'own/$main/push/${owner.uid}/dev1', sub), 200);
    expect(await stranger.status('PUT', 'own/$main/push/${stranger.uid}/dev1', sub), 401);
    expect(await owner.status('PUT', 'own/$main/push/${stranger.uid}/dev1', sub), 401);
    expect(await owner.status('GET', 'own/$main/push'), 401, reason: 'only the shop PCs read the phones list');

    // كافيه غريب بيدّعي إنه تبع الرئيسي ده: مايقراش المفتاح الخاص ولا الاشتراكات
    expect(await stranger.status('PUT', 'cafes/${stranger.uid}/main', main), 200);
    expect(await stranger.status('GET', 'own/$main/vapid/priv'), 401);
    expect(await stranger.status('GET', 'own/$main/push'), 401);
    expect(await stranger.status('DELETE', 'cafes/${stranger.uid}/main'), 200);

    // الرئيسي شال المالك: مابقاش يقرا
    await api.post('/api/owner/remove', {'uid': owner.uid});
    expect(await owner.status('GET', 'rep/$main'), 401);
    expect(await owner.status('GET', 'own/$main/shops'), 401);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
