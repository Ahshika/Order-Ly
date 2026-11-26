// ربط المالك من بره وإشعاراته (على Firebase وهمي، والإشعارات بتتمسك بدل ما تتبعت).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';
import 'package:orderly/src/server/web_push.dart';

import 'support/fake_firebase.dart';

void main() {
  late Directory dir;
  late FakeFirebase fb;
  late OrderlyServer server;
  late ApiClient api;
  late String uid;
  final pushed = <(String, Map<String, Object?>)>[];
  var nextResult = PushResult.sent;

  setUp(() async {
    pushed.clear();
    nextResult = PushResult.sent;
    dir = await Directory.systemTemp.createTemp('orderly_owner');
    fb = FakeFirebase();
    await fb.start();
    server = OrderlyServer(
      dataDir: dir.path,
      requestedPort: 0,
      firebase: fb.endpoints,
      pushSender: (sub, msg, vapid) async {
        pushed.add((sub.endpoint, msg));
        return nextResult;
      },
    );
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه المالك', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    await api.patch('/api/shop', {'branchName': 'فرع المعادي'});
    await server.syncNow();
    uid = server.db.setting('cloud_uid')!;
  });

  tearDown(() async {
    api.close();
    await server.stop();
    await fb.stop();
    await dir.delete(recursive: true);
  });

  Future<void> expectApiError(Future<Object?> f, int status) async {
    try {
      await f;
      fail('expected $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
    }
  }

  test('one-time code: right code is approved, wrong code is not, then the code is gone', () async {
    final status = await api.post('/api/owner/code');
    final code = (status['code'] as Map)['code'] as String;
    final link = Uri.parse((status['code'] as Map)['link'] as String);
    expect(link.path, '/owner/');
    expect(link.queryParameters['c'], code);
    expect(link.queryParameters['m'], uid);
    expect(link.queryParameters['k'], 'fake');
    expect((fb.get('own/$uid/code') as Map)['c'], code);

    fb.write('own/$uid/claim/ownerBAD', {'c': 'WRONGCOD', 'name': 'حد تاني', 'email': 'x@y.z', 'at': 1});
    fb.write('own/$uid/claim/ownerA', {'c': code, 'name': 'أحمد', 'email': 'a@b.c', 'at': 1});
    await server.syncNow();
    expect((fb.get('own/$uid/ok/ownerA') as Map)['name'], 'أحمد');
    expect(fb.get('own/$uid/ok/ownerBAD'), isNull);
    expect(fb.get('own/$uid/claim'), isNull, reason: 'claims are cleared');
    expect(fb.get('own/$uid/code'), isNull, reason: 'the code works once');

    final s = await api.get('/api/owner');
    expect((s['owners'] as List).single['email'], 'a@b.c');
    expect(s['code'], isNull);
  });

  test('shops, the main pointer and the notification keys are published', () async {
    await api.post('/api/owner/code');
    expect(fb.get('cafes/$uid/main'), uid);
    expect(((fb.get('own/$uid/shops') as Map)[uid] as Map)['branch'], 'فرع المعادي');
    final vapid = fb.get('own/$uid/vapid') as Map;
    expect(P256Keys.fromPrivate(unb64url(vapid['priv'] as String)).publicKey, unb64url(vapid['pub'] as String));
    // المفتاح بيفضل هو هو (الموبايلات اشتركت بيه)
    await api.post('/api/owner/code');
    expect((fb.get('own/$uid/vapid') as Map)['pub'], vapid['pub']);
  });

  test('a shift close notifies every owner phone once; a phone that unsubscribed is removed', () async {
    fb.write('own/$uid/push/ownerA/dev1', {'s': jsonEncode({'endpoint': 'https://web.push.apple.com/one', 'keys': {'p256dh': 'x', 'auth': 'y'}}), 'at': 1});
    fb.write('own/$uid/push/ownerA/dev2', {'s': jsonEncode({'endpoint': 'https://fcm.googleapis.com/fcm/send/two', 'keys': {'p256dh': 'x', 'auth': 'y'}}), 'at': 1});
    await api.post('/api/register/open', {'openingCashCents': 0});
    await api.post('/api/register/close', {'countedCashCents': 0});
    await server.syncNow();
    final shift = pushed.where((p) => '${p.$2['title']}'.startsWith('قفل وردية')).toList();
    expect(shift.map((p) => p.$1).toSet(), {'https://web.push.apple.com/one', 'https://fcm.googleapis.com/fcm/send/two'});
    expect(shift.first.$2['title'], contains('فرع المعادي'));
    expect(shift.first.$2['body'], contains('الدرج مظبوط'));
    expect('${shift.first.$2['url']}', contains('shop=$uid'));

    // مرة واحدة بس، حتى بعد مزامنة تانية
    final before = pushed.length;
    await server.syncNow();
    expect(pushed.length, before);

    // الموبايل لغى الاشتراك: بيتمسح
    nextResult = PushResult.gone;
    await api.post('/api/register/open', {'openingCashCents': 0});
    await api.post('/api/register/close', {'countedCashCents': 0});
    await server.syncNow();
    expect(fb.get('own/$uid/push'), isNull);
  });

  test('live summary: sent for the owner, at most once a minute, with the open register', () async {
    final live = fb.get('live/$uid') as Map;
    final s = jsonDecode(live['j'] as String) as Map;
    expect(s['branch'], 'فرع المعادي');
    expect(s['reg'], isNull);
    final writesBefore = fb.requests.where((r) => r.method == 'PATCH' && r.path.isEmpty).length;
    // الدرج اتفتح: الملخص الجاي بيقول كده، بس مش قبل دقيقة من آخر مرة
    await api.post('/api/register/open', {'openingCashCents': 5000});
    await server.cloudTickForTests();
    expect((jsonDecode((fb.get('live/$uid') as Map)['j'] as String) as Map)['reg'], isNull, reason: 'throttled to once a minute');
    expect(fb.requests.where((r) => r.method == 'PATCH' && r.path.isEmpty).length, greaterThanOrEqualTo(writesBefore));
    server.forgetLiveForTests();
    await server.cloudTickForTests();
    final reg = (jsonDecode((fb.get('live/$uid') as Map)['j'] as String) as Map)['reg'] as Map;
    expect(reg['cash'], 5000);
  });

  test('removing an owner deletes their access and phones; only the owner role can link', () async {
    fb.write('own/$uid/ok/ownerA', {'name': 'أحمد', 'email': 'a@b.c', 'at': 1});
    fb.write('own/$uid/push/ownerA/dev1', {'s': '{}', 'at': 1});
    await api.post('/api/owner/remove', {'uid': 'ownerA'});
    expect(fb.get('own/$uid/ok/ownerA'), isNull);
    expect(fb.get('own/$uid/push/ownerA'), isNull);

    await api.post('/api/users', {'name': 'كاشير', 'username': 'cash', 'password': 'cash1234', 'role': 'cashier'});
    final cashier = ApiClient('http://127.0.0.1:${server.port}');
    cashier.token = (await cashier.post('/api/auth/login', {'username': 'cash', 'password': 'cash1234', 'deviceId': 'test-device-02'}))['token'] as String;
    await expectApiError(cashier.post('/api/owner/code'), 403);
    cashier.close();
  });
}
