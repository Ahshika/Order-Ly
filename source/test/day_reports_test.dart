// يوم الشغل حسب ساعات الكافيه، وتقرير كل يوم وكل وردية، وإنهم بيتبعتوا للمالك على Firebase (وهمي).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/business_day.dart';
import 'package:orderly/src/server/api_server.dart';

import 'support/fake_firebase.dart';

void main() {
  late Directory dir;
  late FakeFirebase fb;
  late OrderlyServer server;
  late ApiClient api;
  late String itemId;
  late String cash;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_days');
    fb = FakeFirebase();
    await fb.start();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, firebase: fb.endpoints);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه السهرة', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    itemId = (await api.post('/api/items', {'categoryId': cat, 'name': 'شاي', 'priceCents': 2000}))['id'] as String;
    cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((m) => m['kind'] == 'cash')['id'] as String;
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
      fail('expected ApiException $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
    }
  }

  /// حساب تيك أواي بـ [qty] شاي، اتدفع كاش واتقفل، وبعدين وقت قفله بيتغير لـ [closedAt] (بالساعة المحلية).
  Future<String> sale(int qty, DateTime closedAt) async {
    final id = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    final c = (await api.post('/api/checks/$id/orders', {
      'lines': [
        {'itemId': itemId, 'qty': qty},
      ],
    }))['check'];
    await api.post('/api/checks/$id/payments', {'methodId': cash, 'amountCents': c['totalCents'], 'close': true});
    final at = closedAt.toUtc().toIso8601String();
    server.db.execute('UPDATE checks SET opened_at = ?, closed_at = ? WHERE id = ?', [at, at, id]);
    server.db.execute('UPDATE payments SET created_at = ? WHERE check_id = ?', [at, id]);
    return id;
  }

  test('working hours: saved, validated, and only the owner reads the day report', () async {
    await expectApiError(api.patch('/api/shop', {'settings': {'dayOpen': '25:00'}}), 400);
    final shop = await api.patch('/api/shop', {'settings': {'dayOpen': '21:00', 'dayClose': '03:00'}});
    expect((shop['settings'] as Map)['dayOpen'], '21:00');
    final bd = BusinessDay.fromSettings('21:00', '03:00');
    expect(shop['businessDate'], BusinessDay.keyOf(bd.dateOf(DateTime.now())));

    await api.post('/api/users', {'name': 'سوبر', 'username': 'sup', 'password': 'sup12345', 'role': 'supervisor'});
    final sup = ApiClient('http://127.0.0.1:${server.port}');
    sup.token = (await sup.post('/api/auth/login', {'username': 'sup', 'password': 'sup12345', 'deviceId': 'test-device-01'}))['token'] as String;
    await expectApiError(sup.get('/api/reports/day'), 403);
    sup.close();
  });

  test('night cafe 21:00-03:00: sales after midnight belong to the evening they started in', () async {
    await api.patch('/api/shop', {'settings': {'dayOpen': '21:00', 'dayClose': '03:00'}});
    await api.post('/api/register/open', {'openingCashCents': 0});
    await sale(1, DateTime(2026, 11, 20, 22, 0)); // سهرة 20
    await sale(2, DateTime(2026, 11, 21, 2, 30)); // لسه سهرة 20
    await sale(4, DateTime(2026, 11, 21, 21, 15)); // سهرة 21

    final d20 = await api.get('/api/reports/day', query: {'date': '2026-11-20'});
    expect((d20['sales'] as Map)['checks'], 2);
    expect((d20['sales'] as Map)['totalCents'], 6000);
    expect(d20['final'], isTrue);
    expect((d20['byMethod'] as List).single['amountCents'], 6000);
    expect((d20['hours'] as Map)['open'], '21:00');
    final d21 = await api.get('/api/reports/day', query: {'date': '2026-11-21'});
    expect((d21['sales'] as Map)['totalCents'], 8000);

    // شاشة التقارير بتبعت تاريخ من غير ساعة: بيتحسب يوم شغل
    final summary = await api.get('/api/reports/summary', query: {'from': DateTime(2026, 11, 20).toIso8601String(), 'to': DateTime(2026, 11, 21).toIso8601String()});
    expect(summary['totalCents'], 6000);
    expect(summary['checks'], 2);
  });

  test('default hours (00:00-00:00) keep the old midnight day', () async {
    await api.post('/api/register/open', {'openingCashCents': 0});
    await sale(1, DateTime(2026, 11, 20, 23, 30));
    await sale(1, DateTime(2026, 11, 21, 0, 30));
    expect(((await api.get('/api/reports/day', query: {'date': '2026-11-20'}))['sales'] as Map)['checks'], 1);
    expect(((await api.get('/api/reports/day', query: {'date': '2026-11-21'}))['sales'] as Map)['checks'], 1);
  });

  test('shift report: sales, expenses, counted cash and the difference', () async {
    await api.post('/api/register/open', {'openingCashCents': 10000});
    final id = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$id/orders', {
      'lines': [
        {'itemId': itemId, 'qty': 3},
      ],
    });
    await api.post('/api/checks/$id/payments', {'methodId': cash, 'amountCents': 6000, 'close': true});
    await api.post('/api/register/moves', {'type': 'expense', 'amountCents': 1500, 'category': 'تلج', 'note': 'كيس تلج'});
    final closed = (await api.post('/api/register/close', {'countedCashCents': 14000}))['closed'] as Map;
    final r = await api.get('/api/reports/shift/${closed['id']}');
    expect(r['salesCents'], 6000);
    expect(r['expectedCashCents'], 10000 + 6000 - 1500);
    expect(r['diffCents'], 14000 - 14500);
    expect((r['expenses'] as List).single['category'], 'تلج');
    expect((r['top'] as List).single['qty'], 3);
    expect(r['date'], BusinessDay.keyOf(const BusinessDay().dateOf(DateTime.now())));

    final day = await api.get('/api/reports/day');
    expect((day['shifts'] as List).single['diffCents'], -500);
    expect((day['expenses'] as Map)['totalCents'], 1500);
    expect(day['final'], isFalse);
  });

  test('reports reach Firebase: shift on close, today, yesterday, and days missed while the PC was off', () async {
    await api.post('/api/register/open', {'openingCashCents': 0});
    final id = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$id/orders', {
      'lines': [
        {'itemId': itemId, 'qty': 1},
      ],
    });
    await api.post('/api/checks/$id/payments', {'methodId': cash, 'amountCents': 2000, 'close': true});
    final closed = (await api.post('/api/register/close', {'countedCashCents': 2000}))['closed'] as Map;
    await server.syncNow();
    final uid = server.db.setting('cloud_uid')!;
    const bd = BusinessDay();
    final today = bd.dateOf(DateTime.now());
    String key(int back) => BusinessDay.keyOf(DateTime(today.year, today.month, today.day - back));

    Map<String, dynamic> read(String path) => jsonDecode((fb.get(path) as Map)['j'] as String) as Map<String, dynamic>;
    expect((read('rep/$uid/${key(0)}/day')['sales'] as Map)['totalCents'], 2000);
    expect(read('rep/$uid/${key(0)}/shifts/${closed['id']}')['salesCents'], 2000);
    expect(read('rep/$uid/${key(1)}/day')['final'], isTrue);
    expect(fb.requests.where((r) => r.method != 'GET').every((r) => r.silent), isTrue);

    // الكمبيوتر كان مقفول 4 أيام: الأيام اللي فاتت بتتبعت
    server.db.setSetting('report_last_day', key(5));
    fb.write('rep/$uid', null);
    await server.syncNow();
    for (final back in [1, 2, 3, 4, 5]) {
      expect(fb.get('rep/$uid/${key(back)}/day'), isNotNull, reason: key(back));
    }
    expect(server.db.setting('report_last_day'), key(0));
  });
}
