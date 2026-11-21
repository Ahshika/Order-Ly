import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// الفروع من غير نت: الكود، والصلاحيات، والحالات المحفوظة، وملخص الفرع اللي بيتبعت للرئيسي.
/// الربط الحقيقي وقواعد Firebase في test_cloud/branches_cloud_test.dart.
void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;
  late String base;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_branches');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    api = ApiClient(base);
    api.token = (await api.post('/api/setup', {
      'shopName': 'كافيه',
      'branchName': 'المعادي',
      'ownerName': 'أحمد',
      'username': 'owner',
      'password': 'owner123',
      'deviceId': 'owner-device-1',
    }))['token'] as String;
  });

  tearDown(() async {
    api.close();
    await server.stop();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> expectStatus(Future<Object?> f, int status) async {
    try {
      await f;
      fail('expected $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
    }
  }

  test('link codes: dashes, spaces and small letters are fine; wrong length or letters are not', () {
    expect(normalizeChainCode('abcd-efgh-jk23'), 'ABCDEFGHJK23');
    expect(normalizeChainCode(' ABCD EFGH JK23 '), 'ABCDEFGHJK23');
    expect(normalizeChainCode('ABCD-EFGH-JK2'), isNull);
    expect(normalizeChainCode('ABCD-EFGH-JK234'), isNull);
    // I و O و 0 و 1 مش في الحروف (عشان مايتلخبطوش في بعض)
    expect(normalizeChainCode('ABCD-EFGH-JKI0'), isNull);
    expect(normalizeChainCode('ABCD-EFGH-JK10'), isNull);
    expect(normalizeChainCode('../../evil/xx'), isNull);
    expect(formatChainCode('ABCDEFGHJK23'), 'ABCD-EFGH-JK23');
  });

  test('only the owner sees and changes branches; without internet sync it says so', () async {
    final s = await api.get('/api/branches');
    expect(s['role'], 'none');
    expect(s['cloud'], false);
    await expectStatus(api.post('/api/branches/create'), 503);
    await expectStatus(api.post('/api/branches/join', {'code': 'ABCD-EFGH-JK23'}), 503);

    for (final role in ['supervisor', 'cashier', 'waiter', 'kitchen']) {
      await api.post('/api/users', {'name': role, 'username': 'u$role', 'password': 'pass1234', 'role': role});
      final c = ApiClient(base);
      c.token = (await c.post('/api/auth/login', {'username': 'u$role', 'password': 'pass1234', 'deviceId': 'owner-device-1'}))['token'] as String;
      await expectStatus(c.get('/api/branches'), 403);
      await expectStatus(c.post('/api/branches/create'), 403);
      await expectStatus(c.post('/api/branches/join', {'code': 'ABCD-EFGH-JK23'}), 403);
      await expectStatus(c.post('/api/branches/approve', {'uid': 'x'}), 403);
      await expectStatus(c.post('/api/branches/remove', {'uid': 'x'}), 403);
      await expectStatus(c.post('/api/branches/leave'), 403);
      c.close();
    }
    await expectStatus(ApiClient(base).get('/api/branches'), 401);
  });

  test('bad input is refused before anything goes to the internet', () async {
    // كود غلط: 400 حتى لو مفيش نت (مش 503)، عشان المستخدم يعرف إن الغلط في الكود
    for (final bad in [
      {'code': 'short'},
      {'code': 12345},
      {'code': null},
      {'code': '../../chains/ABCDEFGHJK23'},
      <String, Object?>{},
    ]) {
      await expectStatus(api.post('/api/branches/join', bad), 400);
    }
    // الفرع لازم يبقى ليه اسم عشان الرئيسي يعرفه
    server.db.execute("UPDATE branches SET name = '' WHERE is_local = 1");
    await expectStatus(api.post('/api/branches/join', {'code': 'ABCD-EFGH-JK23'}), 400);
    server.db.execute("UPDATE branches SET name = 'المعادي' WHERE is_local = 1");
    await expectStatus(api.post('/api/branches/join', {'code': 'ABCD-EFGH-JK23'}), 503);
    expect((await api.get('/api/branches'))['role'], 'none', reason: 'a failed join must not leave the device waiting');

    await expectStatus(api.post('/api/branches/approve', {'uid': '../x'}), 400);
    await expectStatus(api.post('/api/branches/remove', {'uid': 42}), 400);
    await expectStatus(api.post('/api/branches/approve', {'uid': 'abc'}), 400); // مش الفرع الرئيسي
  });

  test('saved states: waiting for approval, linked, rejected', () async {
    server.db.setSetting('chain_role', 'pending');
    server.db.setSetting('chain_id', 'ABCDEFGHJK23');
    var s = await api.get('/api/branches');
    expect([s['role'], s['code']], ['pending', 'ABCD-EFGH-JK23']);
    await expectStatus(api.post('/api/branches/create'), 400);
    await expectStatus(api.post('/api/branches/join', {'code': 'ABCD-EFGH-JK23'}), 400);

    server.db.setSetting('chain_role', 'member');
    server.db.setSetting('chain_main_name', 'الفرع الرئيسي');
    s = await api.get('/api/branches');
    expect([s['role'], s['mainName']], ['member', 'الفرع الرئيسي']);

    server.db.setSetting('chain_role', '');
    server.db.setSetting('chain_rejected', '1');
    s = await api.get('/api/branches');
    expect([s['role'], s['rejected'], s['removed']], ['none', true, false]);
  });

  test('the trial allows two branches', () async {
    expect((await api.get('/api/license'))['branches'], 2);
  });

  test('branch summary: sales, open checks, register, QR waiting, top items, and size limit', () async {
    var s = await server.branchSummaryForTests();
    expect([s['name'], s['branch']], ['كافيه', 'المعادي']);
    expect(s['today'], {'n': 0, 't': 0});
    expect(s['reg'], isNull);
    expect((s['days'] as List).length, 7);

    var m = await api.get('/api/menu');
    final bar = ((m['stations'] as List).first as Map)['id'] as String;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': bar});
    m = await api.get('/api/menu');
    final cat = ((m['categories'] as List).first as Map)['id'] as String;
    final coffee = (await api.post('/api/items', {'categoryId': cat, 'name': 'قهوة', 'priceCents': 5000}))['id'];
    final tea = (await api.post('/api/items', {'categoryId': cat, 'name': 'شاي', 'priceCents': 2000}))['id'];
    await api.post('/api/tables/bulk', {'from': 1, 'to': 4});
    final tables = (await api.get('/api/floor'))['tables'] as List;
    await api.post('/api/register/open', {'openingCashCents': 10000});
    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];

    // حساب اتدفع واتقفل، وحساب لسه مفتوح
    final paid = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': tables[0]['id']}))['check']['id'];
    await api.post('/api/checks/$paid/orders', {
      'lines': [
        {'itemId': coffee, 'qty': 3},
        {'itemId': tea, 'qty': 1},
      ],
    });
    await api.post('/api/checks/$paid/payments', {'methodId': cash, 'amountCents': 17000, 'close': true});
    final open = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': tables[1]['id']}))['check']['id'];
    await api.post('/api/checks/$open/orders', {
      'lines': [
        {'itemId': tea, 'qty': 2},
      ],
    });

    s = await server.branchSummaryForTests();
    expect(s['today'], {'n': 1, 't': 17000});
    expect(s['month'], {'n': 1, 't': 17000});
    expect(s['yesterday'], {'n': 0, 't': 0});
    expect((s['days'] as List).last, 17000);
    expect(s['open'], {'n': 1, 't': 4000, 'busy': 1, 'tables': 4});
    expect((s['reg'] as Map)['cash'], 10000 + 17000);
    expect((s['reg'] as Map)['by'], 'أحمد');
    expect((s['top'] as List).first, {'n': 'قهوة', 'q': 3});
    expect((s['devs'] as int), greaterThanOrEqualTo(1));
    expect((s['lic'] as Map)['s'], 'trial');

    // أسماء طويلة جداً: الملخص لازم يفضل أصغر من حد Firebase (20 ألف حرف)
    server.db.execute('UPDATE shop SET name = ?', ['ك' * 5000]);
    server.db.execute("UPDATE order_items SET name = ? WHERE item_id = ?", ['ق' * 5000, coffee]);
    s = await server.branchSummaryForTests();
    expect((s['name'] as String).length, 80);
    expect(((s['top'] as List).first as Map)['n'], hasLength(60));
    expect(jsonEncode(s).length, lessThan(20000));
  });
}
