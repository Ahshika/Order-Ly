// اختبار حقيقي على Firebase (محتاج نت): ربط فرعين مؤقتين، وحساب غريب بيحاول يكسر القواعد. كل حاجة بتتمسح في الآخر.
// التشغيل:  flutter test test_cloud/branches_cloud_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/firebase_config.dart';
import 'package:orderly/src/server/api_server.dart';

class _Cafe {
  _Cafe(this.dir, this.server, this.api);
  final Directory dir;
  final OrderlyServer server;
  final ApiClient api;
  String get uid => server.db.setting('cloud_uid')!;
}

/// حساب Firebase بيكلم القاعدة مباشرة (من غير البرنامج)، زي أي حد معاه المفتاح العام.
class _Raw {
  _Raw(this.uid, this.token);
  final String uid;
  final String token;

  static Future<_Raw> signIn(String email, String password, {bool create = false}) async {
    final res = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:${create ? 'signUp' : 'signInWithPassword'}?key=$firebaseApiKey'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
    );
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw StateError('auth ${res.statusCode}: ${res.body}');
    return _Raw(j['localId'] as String, j['idToken'] as String);
  }

  Future<int> send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$rtdbUrl/$path.json').replace(queryParameters: {'auth': token}));
    if (body != null) req.body = jsonEncode(body);
    return (await http.Response.fromStream(await req.send())).statusCode;
  }

  Future<void> deleteAccount() => http.post(
        Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$firebaseApiKey'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'idToken': token}),
      );
}

void main() {
  final cafes = <_Cafe>[];
  _Raw? stranger;

  Future<_Cafe> cafe(String shop, String branch) async {
    final dir = await Directory.systemTemp.createTemp('orderly_branch');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: 0);
    await server.start();
    final api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {
      'shopName': shop,
      'branchName': branch,
      'ownerName': 'تست',
      'username': 'owner',
      'password': 'owner123',
      'deviceId': 'test-device-${cafes.length}',
    }))['token'] as String;
    await server.syncNow();
    final c = _Cafe(dir, server, api);
    cafes.add(c);
    return c;
  }

  tearDown(() async {
    for (final c in cafes) {
      await c.server.cleanupCloudForTests();
      c.api.close();
      await c.server.stop();
      try {
        await c.dir.delete(recursive: true);
      } catch (_) {}
    }
    cafes.clear();
    await stranger?.deleteAccount();
  });

  Future<void> expectStatus(Future<Object?> f, int status, [String? text]) async {
    try {
      await f;
      fail('expected $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
      if (text != null) expect(e.message, contains(text));
    }
  }

  Future<Map<String, dynamic>> branches(_Cafe c) => c.api.send('GET', '/api/branches', query: {'fresh': '1'}, timeout: const Duration(seconds: 40));
  Future<Map<String, dynamic>> post(_Cafe c, String path, [Map<String, Object?>? body]) =>
      c.api.send('POST', path, body: body ?? const {}, timeout: const Duration(seconds: 40));

  Future<void> sell(_Cafe c, int cents) async {
    var m = await c.api.get('/api/menu');
    await c.api.post('/api/categories', {'name': 'مشروبات', 'stationId': ((m['stations'] as List).first as Map)['id']});
    m = await c.api.get('/api/menu');
    final item = await c.api.post('/api/items', {'categoryId': ((m['categories'] as List).first as Map)['id'], 'name': 'لاتيه', 'priceCents': cents});
    await c.api.post('/api/register/open', {'openingCashCents': 0});
    final cash = ((await c.api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    final check = (await c.api.post('/api/checks', {'type': 'takeaway'}))['check']['id'];
    await c.api.post('/api/checks/$check/orders', {
      'lines': [
        {'itemId': item['id'], 'qty': 1},
      ],
    });
    await c.api.post('/api/checks/$check/payments', {'methodId': cash, 'amountCents': cents, 'close': true});
  }

  test('main branch links a branch, sees its sales, and the rules keep everyone else out', () async {
    final main = await cafe('كافيه الربط', 'الرئيسي');
    final branch = await cafe('كافيه الربط', 'فرع مدينة نصر');
    expect(main.server.cloudError, anyOf(isNull, isEmpty));

    // الرئيسي بيعمل كود
    var s = await post(main, '/api/branches/create');
    expect(s['role'], 'main');
    final code = s['code'] as String;
    final cid = normalizeChainCode(code)!;
    expect(s['used'], 1);
    expect(s['limit'], 2);
    expect((s['branches'] as List).single['me'], true);
    await expectStatus(post(main, '/api/branches/join', {'code': code}), 400, 'مربوط');

    // كود صحيح الشكل بس مش موجود
    await expectStatus(post(branch, '/api/branches/join', {'code': 'ZZZZ-ZZZZ-ZZ22'}), 400, 'مش صحيح');
    expect((await branches(branch))['role'], 'none');

    // الفرع بيطلب الربط
    s = await post(branch, '/api/branches/join', {'code': code.toLowerCase()});
    expect(s['role'], 'pending');
    s = await branches(main);
    final req = (s['requests'] as List).single as Map;
    expect([req['uid'], req['branch'], req['name']], [branch.uid, 'فرع مدينة نصر', 'كافيه الربط']);

    // ------------------------------------------------------------ حساب غريب معاه الكود
    stranger = await _Raw.signIn('branch-test-${DateTime.now().microsecondsSinceEpoch}@test.orderly.app', 'Test-${DateTime.now().millisecondsSinceEpoch}', create: true);
    final x = stranger!;
    expect(await x.send('GET', 'chains/$cid'), 401, reason: 'only the main branch reads the chain');
    expect(await x.send('GET', 'chains/$cid/b'), 401);
    expect(await x.send('GET', 'chains/$cid/req/${branch.uid}'), 401, reason: "another branch's request");
    expect(await x.send('PUT', 'chains/$cid/owner', x.uid), 401, reason: 'taking over the chain');
    expect(await x.send('PUT', 'chains/$cid/members/${x.uid}', {'at': 1}), 401, reason: 'approving itself');
    expect(await x.send('PUT', 'chains/$cid/b/${x.uid}', {'j': '{}', 'at': {'.sv': 'timestamp'}}), 401, reason: 'writing a summary without approval');
    expect(await x.send('PUT', 'chains/$cid/req/${branch.uid}', {'name': 'x', 'branch': 'x', 'at': {'.sv': 'timestamp'}}), 401, reason: "replacing another branch's request");
    expect(await x.send('DELETE', 'chains/$cid/req/${branch.uid}'), 401);
    expect(await x.send('PUT', 'chains/$cid/req/${x.uid}', {'name': 'x', 'branch': 'x', 'at': 5}), 401, reason: 'fake time');
    expect(await x.send('PUT', 'chains/$cid/req/${x.uid}', {'name': 'x', 'branch': 'x' * 81, 'at': {'.sv': 'timestamp'}}), 401, reason: 'too long');
    expect(await x.send('PUT', 'chains/$cid/req/${x.uid}', {'name': 'x', 'branch': 'x', 'at': {'.sv': 'timestamp'}, 'extra': 1}), 401, reason: 'extra field');
    expect(await x.send('PUT', 'chains/$cid/junk', 1), 401);
    expect(await x.send('PUT', 'chains/abc/owner', x.uid), 401, reason: 'bad code format');
    expect(await x.send('PUT', 'chains/ZZZZZZZZZZ22/req/${x.uid}', {'name': 'x', 'branch': 'x', 'at': {'.sv': 'timestamp'}}), 401, reason: 'chain does not exist');
    // أي حد معاه الكود يقدر يطلب بس (والرئيسي هو اللي يقرر)
    expect(await x.send('PUT', 'chains/$cid/req/${x.uid}', {'name': 'غريب', 'branch': 'غريب', 'at': {'.sv': 'timestamp'}}), 200);

    // الفرع نفسه (بحسابه) مايقدرش يقرا الربط ولا يوافق على نفسه
    final b = await _Raw.signIn(branch.server.db.setting('cloud_email')!, branch.server.db.setting('cloud_password')!);
    expect(await b.send('GET', 'chains/$cid'), 401);
    expect(await b.send('GET', 'chains/$cid/req/${branch.uid}'), 200, reason: 'a branch can see its own request');
    expect(await b.send('PUT', 'chains/$cid/members/${branch.uid}', {'at': 1}), 401);

    // ------------------------------------------------------------ الموافقة وحد الاشتراك
    s = await branches(main);
    expect((s['requests'] as List).length, 2);
    s = await post(main, '/api/branches/approve', {'uid': branch.uid});
    expect(s['used'], 2);
    // التجربة بتسمح بفرعين بس
    await expectStatus(post(main, '/api/branches/approve', {'uid': x.uid}), 402, 'فروع');
    s = await post(main, '/api/branches/reject', {'uid': x.uid});
    expect(s['requests'], isEmpty);
    await expectStatus(post(main, '/api/branches/approve', {'uid': x.uid}), 404);

    // الفرع بيعرف إنه اتوافق عليه وبيبعت ملخصه
    await sell(branch, 4500);
    await branch.server.syncNow();
    s = await branches(branch);
    expect([s['role'], s['mainName']], ['member', 'كافيه الربط']);
    expect(s['lastPush'], isNotNull, reason: 'summary was not sent: ${s['error']}');

    s = await branches(main);
    final other = (s['branches'] as List).cast<Map>().firstWhere((b) => b['me'] != true);
    expect(other['online'], true);
    expect(other['branch'], 'فرع مدينة نصر');
    expect(other['summary']['today'], {'n': 1, 't': 4500});
    expect(other['summary']['branch'], 'فرع مدينة نصر');

    // الفرع المربوط: ملخصه بس، وبحجم معقول، وبوقت السيرفر
    expect(await b.send('PUT', 'chains/$cid/b/${branch.uid}', {'j': 'x' * 20001, 'at': {'.sv': 'timestamp'}}), 401);
    expect(await b.send('PUT', 'chains/$cid/b/${branch.uid}', {'j': '{}', 'at': 1}), 401);
    expect(await b.send('PUT', 'chains/$cid/b/${x.uid}', {'j': '{}', 'at': {'.sv': 'timestamp'}}), 401);
    expect(await b.send('PUT', 'chains/$cid/members/${branch.uid}/main', 'تلاعب'), 401);
    expect(await b.send('GET', 'chains/$cid/b'), 401);

    // ------------------------------------------------------------ الفصل
    s = await post(main, '/api/branches/remove', {'uid': branch.uid});
    expect(s['used'], 1);
    expect(await b.send('PUT', 'chains/$cid/b/${branch.uid}', {'j': '{}', 'at': {'.sv': 'timestamp'}}), 401, reason: 'removed branch can still write');
    await branch.server.syncNow();
    s = await branches(branch);
    expect([s['role'], s['removed']], ['none', true]);

    // يرجع يتربط، والرئيسي يمسح الربط كله: الفرع بيفصل لوحده
    await post(branch, '/api/branches/join', {'code': code});
    await post(main, '/api/branches/approve', {'uid': branch.uid});
    await branch.server.syncNow();
    expect((await branches(branch))['role'], 'member');
    s = await post(main, '/api/branches/leave');
    expect(s['role'], 'none');
    expect(await x.send('PUT', 'chains/$cid/req/${x.uid}', {'name': 'x', 'branch': 'x', 'at': {'.sv': 'timestamp'}}), 401, reason: 'deleted chain still accepts requests');
    await branch.server.syncNow();
    expect((await branches(branch))['role'], 'none');
    // الكود القديم مابقاش شغال
    await expectStatus(post(branch, '/api/branches/join', {'code': code}), 400, 'مش صحيح');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
