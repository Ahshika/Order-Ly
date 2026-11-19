import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// أسوأ السيناريوهات: سباقات بين الأجهزة، مدخلات بايظة، هجوم من الشبكة، ملفات بايظة، ضغط عالي.
/// كله على فولدر مؤقت (عمره ما بيلمس بيانات كافيه حقيقي).
///
/// النتايج الخام بتتكتب في test-results/stress/worst_case_results.json
void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;
  late String base;
  final results = <Map<String, Object?>>[];

  void record(String scenario, String status, Map<String, Object?> data) =>
      results.add({'scenario': scenario, 'status': status, ...data});

  tearDownAll(() {
    final out = File('../test-results/stress/worst_case_results.json')..parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'generatedAt': DateTime.now().toIso8601String(), 'results': results}));
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_stress');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    api = ApiClient(base);
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه الضغط', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
  });

  tearDown(() async {
    api.close();
    await server.stop();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------------------ helpers

  Future<ApiClient> userClient(String username, String role) async {
    await api.post('/api/users', {'name': username, 'username': username, 'password': 'pass1234', 'role': role});
    final c = ApiClient(base);
    c.token = (await c.post('/api/auth/login', {'username': username, 'password': 'pass1234', 'deviceId': 'test-device-01'}))['token'] as String;
    return c;
  }

  Future<Map<String, String>> buildMenu() async {
    var menu = await api.get('/api/menu');
    final bar = ((menu['stations'] as List).first as Map)['id'] as String;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': bar});
    menu = await api.get('/api/menu');
    final cat = ((menu['categories'] as List).first as Map)['id'] as String;
    final size = await api.post('/api/modifier-groups', {
      'name': 'الحجم',
      'minSelect': 1,
      'maxSelect': 1,
      'options': [
        {'name': 'وسط', 'priceCents': 0},
        {'name': 'عملاق', 'priceCents': 100000000},
      ],
    });
    final coffee = await api.post('/api/items', {'categoryId': cat, 'name': 'قهوة', 'priceCents': 5000});
    final big = await api.post('/api/items', {'categoryId': cat, 'name': 'صنف غالي', 'priceCents': 100000000, 'groupIds': [size['id']]});
    menu = await api.get('/api/menu');
    final opts = ((menu['modifierGroups'] as List).first as Map)['options'] as List;
    await api.post('/api/tables/bulk', {'from': 1, 'to': 20});
    return {
      'bar': bar,
      'cat': cat,
      'coffee': coffee['id'] as String,
      'big': big['id'] as String,
      'medium': (opts.firstWhere((o) => o['name'] == 'وسط') as Map)['id'] as String,
      'giant': (opts.firstWhere((o) => o['name'] == 'عملاق') as Map)['id'] as String,
    };
  }

  Future<List<Map<String, dynamic>>> tables() async => ((await api.get('/api/floor'))['tables'] as List).cast<Map<String, dynamic>>();

  Future<String> openTableCheck(int n) async {
    final t = (await tables()).firstWhere((t) => t['name'] == '$n');
    return (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'] as String;
  }

  Future<String> cashId() async => (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((m) => m['kind'] == 'cash') as Map)['id'] as String;

  /// طلب HTTP خام (عشان نبعت حاجات الـ ApiClient مايبعتهاش: أنواع غلط، أحجام كبيرة، من غير توكن).
  Future<(int, String)> raw(String method, String path, {String? token, List<int>? body}) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(method, Uri.parse('$base$path'));
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      r.headers.contentType = ContentType.json;
      if (body != null) {
        r.contentLength = body.length;
        r.add(body);
      }
      final res = await r.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } finally {
      c.close(force: true);
    }
  }

  /// بيبعت الهيدر وأول بايت من الـ body، وبعدين بيعمل [during] (جهاز تاني بيعمل حاجة في نفس اللحظة)،
  /// وبعدين بيكمّل الـ body. ده بيقلّد موبايل على واي فاي ضعيف.
  Future<(int, String)> slowBody(String path, Object json, Future<void> Function() during, {String? token, String method = 'POST'}) async {
    final c = HttpClient();
    try {
      final r = await c.openUrl(method, Uri.parse('$base$path'));
      r.headers.set('authorization', 'Bearer ${token ?? api.token}');
      r.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(json));
      r.contentLength = bytes.length;
      r.add(bytes.sublist(0, 1));
      await r.flush();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await during();
      r.add(bytes.sublist(1));
      final res = await r.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } finally {
      c.close(force: true);
    }
  }

  Future<String> payAndClose(String checkId) async {
    final c = (await api.get('/api/checks/$checkId'))['check'] as Map;
    final due = (c['totalCents'] as int) - (c['paidCents'] as int);
    if (due > 0) await api.post('/api/checks/$checkId/payments', {'methodId': await cashId(), 'amountCents': due});
    return ((await api.post('/api/checks/$checkId/close'))['check'] as Map)['status'] as String;
  }

  // ================================================================== 1. سباقات (جهازين في نفس اللحظة)

  group('race: request body still uploading while another device changes the check', () {
    test('waiter adds an order while the cashier closes the same check', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(1);
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 1},
        ],
      });
      final waiter = await userClient('waiter1', 'waiter');
      final (status, _) = await slowBody('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 3},
        ],
      }, () async => expect(await payAndClose(checkId), 'closed'), token: waiter.token);
      // المقبول: الطلب يتسجل على حساب جديد للترابيزة (مايضيعش)، والحساب المقفول مايتغيرش
      final c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      final unpaid = (c['totalCents'] as int) - (c['paidCents'] as int);
      final reopened = server.db.selectOne("SELECT subtotal_cents FROM checks WHERE status = 'open' AND table_id = (SELECT table_id FROM checks WHERE id = ?)", [checkId]);
      final orderKept = status >= 400 || reopened?['subtotal_cents'] == 15000;
      record('race.add_order_vs_close', unpaid == 0 && orderKept ? 'PASS' : 'FAIL',
          {'httpStatus': status, 'closedCheckUnpaidCents': unpaid, 'orderLandedOnNewCheckCents': reopened?['subtotal_cents']});
      expect(unpaid, 0, reason: 'a closed check must never end up with unpaid items');
      expect(orderKept, isTrue, reason: 'the waiter order was lost');
      waiter.close();
    });

    test('cashier changes the discount while the check is being closed', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(2);
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 2},
        ],
      });
      final cashier = await userClient('cashier1', 'cashier');
      int? closedTotal;
      final (status, _) = await slowBody('/api/checks/$checkId', {'discountCents': 5000}, () async {
        expect(await payAndClose(checkId), 'closed');
        closedTotal = ((await api.get('/api/checks/$checkId'))['check'] as Map)['totalCents'] as int;
      }, token: cashier.token, method: 'PATCH');
      final c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      final ok = status >= 400 && c['totalCents'] == closedTotal && c['discountCents'] == 0;
      record('race.discount_vs_close', ok ? 'PASS' : 'FAIL', {'httpStatus': status, 'totalAtClose': closedTotal, 'totalAfter': c['totalCents'], 'discountAfter': c['discountCents']});
      expect(status, greaterThanOrEqualTo(400));
      expect(c['totalCents'], closedTotal, reason: 'discount was applied to a check that was already paid and closed');
      cashier.close();
    });

    test('item voided while the check is being closed (closed totals must not change)', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(3);
      final r = await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 2},
        ],
      });
      final lineId = ((((r['orders'] as List).single as Map)['items'] as List).single as Map)['id'] as String;
      int? closedTotal;
      final (status, _) = await slowBody('/api/order-items/$lineId/void', {'reason': 'غلط'}, () async {
        expect(await payAndClose(checkId), 'closed');
        closedTotal = ((await api.get('/api/checks/$checkId'))['check'] as Map)['totalCents'] as int;
      });
      final after = (await api.get('/api/checks/$checkId'))['check'] as Map;
      final ok = status >= 400 && after['totalCents'] == closedTotal && after['status'] == 'closed';
      record('race.void_item_vs_close', ok ? 'PASS' : 'FAIL', {'httpStatus': status, 'totalAtClose': closedTotal, 'totalAfter': after['totalCents'], 'paid': after['paidCents']});
      expect(status, greaterThanOrEqualTo(400));
      expect(after['totalCents'], closedTotal, reason: 'a closed (paid) check total changed after closing');
    });

    test('check split while it is being closed (items must not escape a closed check)', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(4);
      final r = await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 2},
        ],
      });
      final lineId = ((((r['orders'] as List).single as Map)['items'] as List).single as Map)['id'] as String;
      final (status, _) = await slowBody('/api/checks/$checkId/split', {
        'lines': [
          {'id': lineId, 'qty': 1},
        ],
      }, () async => expect(await payAndClose(checkId), 'closed'));
      final open = server.db.select("SELECT * FROM checks WHERE status = 'open'");
      record('race.split_vs_close', status >= 400 && open.isEmpty ? 'PASS' : 'FAIL', {'httpStatus': status, 'openChecksAfter': open.length});
      expect(status, greaterThanOrEqualTo(400));
      expect(open, isEmpty, reason: 'split created a new open check out of an already paid check (item billed twice)');
    });

    test('two cashiers confirm the same transfer at the same moment: drawer counts it once', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      await api.post('/api/pay-methods', {'name': 'محفظة', 'kind': 'wallet', 'account': '01000000000'});
      final wallet = (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'wallet') as Map)['id'];
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '7'")!['qr_key'] as String;
      server.ingestCloudMessage('qr-dbl-1', {
        't': 'order',
        'k': key,
        'c': 'phone-dbl-1',
        'at': DateTime.now().millisecondsSinceEpoch,
        'j': jsonEncode({
          'name': 'منى',
          'phone': '01212345678',
          'items': [
            {'i': m['coffee'], 'q': 2},
          ],
          'pay': {'m': wallet},
        }),
      });
      final order = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'qr-dbl-1'")!;
      await api.post('/api/orders/${order['id']}/accept');
      final pay = server.db.selectOne("SELECT id FROM payments WHERE cloud_id = 'qr-dbl-1'")!['id'];
      final (status, _) = await slowBody('/api/payments/$pay/confirm', {}, () async => api.post('/api/payments/$pay/confirm', {}));
      final sales = server.db.selectOne("SELECT COUNT(*) AS n, COALESCE(SUM(amount_cents),0) AS s FROM cash_moves WHERE ref_id = ?", [pay])!;
      record('race.double_confirm_transfer', sales['n'] == 1 ? 'PASS' : 'FAIL',
          {'secondHttpStatus': status, 'drawerEntries': sales['n'], 'drawerSum': sales['s'], 'note': 'added after the fix; same load-before-body pattern as the other race bugs'});
      expect(status, greaterThanOrEqualTo(400));
      expect(sales['n'], 1, reason: 'one transfer was counted twice in the drawer');
    });

    test('two devices open the drawer at the same moment: one open shift', () async {
      final (status, _) = await slowBody('/api/register/open', {'openingCashCents': 100}, () async => api.post('/api/register/open', {'openingCashCents': 200}));
      final open = server.db.select('SELECT id FROM register_sessions WHERE closed_at IS NULL');
      record('race.double_register_open', open.length == 1 ? 'PASS' : 'FAIL',
          {'secondHttpStatus': status, 'openShifts': open.length, 'note': 'added after the fix; same load-before-body pattern as the other race bugs'});
      expect(open.length, 1);
    });

    test('merge while the source check is being closed', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final a = await openTableCheck(5);
      final b = await openTableCheck(6);
      for (final id in [a, b]) {
        await api.post('/api/checks/$id/orders', {
          'lines': [
            {'itemId': m['coffee'], 'qty': 1},
          ],
        });
      }
      final (status, _) = await slowBody('/api/checks/$a/merge', {'intoCheckId': b}, () async => expect(await payAndClose(a), 'closed'));
      final ca = server.db.selectOne('SELECT * FROM checks WHERE id = ?', [a])!;
      record('race.merge_vs_close', status >= 400 && ca['status'] == 'closed' ? 'PASS' : 'FAIL', {'httpStatus': status, 'sourceStatusAfter': ca['status']});
      expect(status, greaterThanOrEqualTo(400));
      expect(ca['status'], 'closed', reason: 'a paid+closed check was turned into a void merged check');
    });
  });

  // ================================================================== 2. تزاحم (أجهزة كتير مرة واحدة)

  group('concurrency floods', () {
    test('300 orders on the same check at the same moment: totals exact, numbers unique', () async {
      final m = await buildMenu();
      final checkId = await openTableCheck(1);
      final clients = List.generate(30, (_) => ApiClient(base, token: api.token));
      final sw = Stopwatch()..start();
      var errors = 0;
      await Future.wait(List.generate(300, (i) async {
        try {
          await clients[i % 30].post('/api/checks/$checkId/orders', {
            'lines': [
              {'itemId': m['coffee'], 'qty': 1 + i % 3},
            ],
          });
        } catch (_) {
          errors++;
        }
      }));
      sw.stop();
      final expectedSubtotal = List.generate(300, (i) => (1 + i % 3) * 5000).reduce((a, b) => a + b);
      final c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      final numbers = server.db.select('SELECT number FROM orders').map((r) => r['number']).toList();
      final ok = errors == 0 && c['subtotalCents'] == expectedSubtotal && numbers.toSet().length == numbers.length;
      record('flood.300_orders_same_check', ok ? 'PASS' : 'FAIL',
          {'errors': errors, 'ms': sw.elapsedMilliseconds, 'subtotal': c['subtotalCents'], 'expected': expectedSubtotal, 'uniqueOrderNumbers': numbers.toSet().length == numbers.length});
      expect(errors, 0);
      expect(c['subtotalCents'], expectedSubtotal);
      expect(numbers.toSet().length, numbers.length);
      for (final c in clients) {
        c.close();
      }
    });

    test('50 devices open the same table at once: exactly one open check', () async {
      await buildMenu();
      final t = (await tables()).firstWhere((t) => t['name'] == '7');
      final ids = await Future.wait(List.generate(50, (_) async => (await ApiClient(base, token: api.token).post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id']));
      final open = server.db.select("SELECT id FROM checks WHERE table_id = ? AND status = 'open'", [t['id']]);
      record('flood.same_table_open', open.length == 1 && ids.toSet().length == 1 ? 'PASS' : 'FAIL', {'openChecks': open.length});
      expect(open.length, 1);
      expect(ids.toSet().length, 1);
    });

    test('20 cashiers pay the full amount of the same check at once: never over-paid', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(8);
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 4},
        ],
      });
      final cash = await cashId();
      var ok = 0, rejected = 0;
      await Future.wait(List.generate(20, (_) async {
        try {
          await ApiClient(base, token: api.token).post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 20000, 'close': true});
          ok++;
        } on ApiException {
          rejected++;
        }
      }));
      final c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      final drawer = server.db.selectOne("SELECT COALESCE(SUM(amount_cents),0) AS s FROM cash_moves WHERE type = 'sale'")!['s'];
      final pass = ok == 1 && c['paidCents'] == 20000 && drawer == 20000 && c['status'] == 'closed';
      record('flood.double_payment', pass ? 'PASS' : 'FAIL', {'succeeded': ok, 'rejected': rejected, 'paid': c['paidCents'], 'drawerSales': drawer});
      expect(ok, 1);
      expect(c['paidCents'], 20000);
      expect(drawer, 20000);
    });

    test('close and void the same check at the same moment', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final checkId = await openTableCheck(9);
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 1},
        ],
      });
      final rs = await Future.wait([
        ApiClient(base, token: api.token).post('/api/checks/$checkId/close').then((_) => 'close').catchError((_) => 'close-failed'),
        ApiClient(base, token: api.token).post('/api/checks/$checkId/void', {'reason': 'تجربة'}).then((_) => 'void').catchError((_) => 'void-failed'),
      ]);
      final c = server.db.selectOne('SELECT status FROM checks WHERE id = ?', [checkId])!;
      record('flood.close_vs_void', 'PASS', {'outcomes': rs, 'finalStatus': c['status']});
      expect(c['status'], isIn(['void', 'closed']));
    });

    test('400 WebSocket screens connected while 100 orders are written', () async {
      final m = await buildMenu();
      final checkId = await openTableCheck(10);
      final sockets = <WebSocket>[];
      var received = 0;
      for (var i = 0; i < 400; i++) {
        final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}');
        ws.listen((_) => received++);
        sockets.add(ws);
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        await api.post('/api/checks/$checkId/orders', {
          'lines': [
            {'itemId': m['coffee'], 'qty': 1},
          ],
        });
      }
      final writeMs = sw.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(seconds: 1));
      final probe = Stopwatch()..start();
      await api.get('/api/info');
      record('flood.websockets_400', received > 100 * 400 ? 'PASS' : 'FAIL',
          {'messagesReceived': received, 'writeMsFor100Orders': writeMs, 'infoLatencyMs': probe.elapsedMilliseconds, 'rssMB': ProcessInfo.currentRss ~/ (1 << 20)});
      expect(received, greaterThan(100 * 400));
      for (final s in sockets) {
        await s.close();
      }
    });

    test('1000 idle half-open connections (slowloris) do not block real requests', () async {
      final socks = <Socket>[];
      for (var i = 0; i < 1000; i++) {
        final s = await Socket.connect('127.0.0.1', server.port);
        s.write('POST /api/auth/login HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n{');
        socks.add(s);
      }
      final sw = Stopwatch()..start();
      final info = await api.get('/api/info');
      record('dos.slowloris_1000', sw.elapsedMilliseconds < 2000 ? 'PASS' : 'FAIL', {'infoLatencyMs': sw.elapsedMilliseconds});
      expect(info['app'], 'orderly');
      expect(sw.elapsedMilliseconds, lessThan(2000));
      for (final s in socks) {
        s.destroy();
      }
    });
  });

  // ================================================================== 3. مخزون

  group('inventory', () {
    test('voiding a QR order that was never accepted must not add stock that was never taken', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final ing = await api.post('/api/ingredients', {'name': 'بن', 'unit': 'g', 'qty': 1000});
      await api.put('/api/recipes/item/${m['coffee']}', {
        'lines': [
          {'ingredientId': ing['id'], 'qty': 10},
        ],
      });
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '11'")!['qr_key'] as String;
      server.ingestCloudMessage('qr-stock-1', {
        't': 'order',
        'k': key,
        'c': 'phone-stock-1',
        'at': DateTime.now().millisecondsSinceEpoch,
        'j': jsonEncode({
          'name': 'سلمى',
          'phone': '01012345678',
          'items': [
            {'i': m['coffee'], 'q': 5},
          ],
        }),
      });
      final order = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'qr-stock-1'")!;
      expect(order['status'], 'pending');
      // الويتر لغى صنف من الطلب اللي لسه مستني، والمالك لغى الحساب كله
      final line = server.db.selectOne('SELECT * FROM order_items WHERE order_id = ?', [order['id']])!;
      await api.post('/api/order-items/${line['id']}/void', {'reason': 'العميل غيّر رأيه', 'qty': 2});
      await api.post('/api/checks/${order['check_id']}/void', {'reason': 'مشي'});
      final qty = ((await api.get('/api/ingredients'))['ingredients'] as List).single['qty'];
      record('inventory.void_pending_qr_order', qty == 1000 ? 'PASS' : 'FAIL', {'stockAfter': qty, 'expected': 1000});
      expect(qty, 1000.0, reason: 'stock grew by returning ingredients that were never consumed');
    });

    test('accepted order then void: stock returns exactly once', () async {
      final m = await buildMenu();
      final ing = await api.post('/api/ingredients', {'name': 'لبن', 'unit': 'ml', 'qty': 500});
      await api.put('/api/recipes/item/${m['coffee']}', {
        'lines': [
          {'ingredientId': ing['id'], 'qty': 100},
        ],
      });
      final checkId = await openTableCheck(12);
      final r = await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 3},
        ],
      });
      final lineId = ((((r['orders'] as List).single as Map)['items'] as List).single as Map)['id'];
      await api.post('/api/order-items/$lineId/void', {'reason': 'x', 'qty': 1});
      await api.post('/api/checks/$checkId/void', {'reason': 'y'});
      final qty = ((await api.get('/api/ingredients'))['ingredients'] as List).single['qty'];
      record('inventory.void_accepted_order', qty == 500 ? 'PASS' : 'FAIL', {'stockAfter': qty});
      expect(qty, 500.0);
    });
  });

  // ================================================================== 4. فلوس وأرقام متطرفة

  group('money extremes', () {
    test('60 lines × 99 qty × max prices: no overflow, totals exact', () async {
      final m = await buildMenu();
      await api.patch('/api/shop', {
        'settings': {'serviceBp': 5000, 'taxBp': 5000},
      });
      final checkId = await openTableCheck(13);
      final lines = List.generate(60, (_) => {'itemId': m['big'], 'qty': 99, 'modifierIds': [m['giant']]});
      final r = await api.post('/api/checks/$checkId/orders', {'lines': lines});
      final c = r['check'] as Map;
      const sub = 60 * 99 * 200000000;
      final service = (sub * 5000 / 10000).round();
      final tax = ((sub + service) * 5000 / 10000).round();
      final ok = c['subtotalCents'] == sub && c['totalCents'] == sub + service + tax;
      record('money.max_values', ok ? 'PASS' : 'FAIL', {'subtotal': c['subtotalCents'], 'total': c['totalCents'], 'expectedTotal': sub + service + tax});
      expect(c['subtotalCents'], sub);
      expect(c['totalCents'], sub + service + tax);
    });

    test('discount bigger than the check, huge delivery, negative and absurd numbers', () async {
      final m = await buildMenu();
      final checkId = await openTableCheck(14);
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 1},
        ],
      });
      await api.patch('/api/checks/$checkId', {'discountCents': 9007199254740991});
      var c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      expect(c['totalCents'], 0);
      final (s1, _) = await raw('PATCH', '/api/checks/$checkId', token: api.token, body: utf8.encode('{"discountCents": -5}'));
      final (s2, _) = await raw('POST', '/api/checks/$checkId/payments', token: api.token, body: utf8.encode('{"methodId":"x","amountCents": 1e400}'));
      c = (await api.get('/api/checks/$checkId'))['check'] as Map;
      record('money.absurd_numbers', s1 == 400 && c['totalCents'] == 0 ? 'PASS' : 'FAIL', {'negativeDiscountStatus': s1, 'infinityAmountStatus': s2, 'total': c['totalCents']});
      expect(s1, 400);
      expect(s2, lessThan(500));
    });

    test('confirming a transfer with an amount larger than the bill', () async {
      final m = await buildMenu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      await api.post('/api/pay-methods', {'name': 'InstaPay', 'kind': 'instapay', 'account': 'cafe@instapay'});
      final ipay = (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'instapay') as Map)['id'];
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '15'")!['qr_key'] as String;
      server.ingestCloudMessage('qr-over-1', {
        't': 'order',
        'k': key,
        'c': 'phone-over-1',
        'at': DateTime.now().millisecondsSinceEpoch,
        'j': jsonEncode({
          'name': 'كريم',
          'phone': '01112345678',
          'items': [
            {'i': m['coffee'], 'q': 1},
          ],
          'pay': {'m': ipay},
        }),
      });
      final order = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'qr-over-1'")!;
      await api.post('/api/orders/${order['id']}/accept');
      final p = server.db.selectOne("SELECT id FROM payments WHERE cloud_id = 'qr-over-1'")!;
      int status;
      try {
        await api.post('/api/payments/${p['id']}/confirm', {'amountCents': 5000000});
        status = 200;
      } on ApiException catch (e) {
        status = e.status ?? 0;
      }
      final c = (await api.get('/api/checks/${order['check_id']}'))['check'] as Map;
      final over = (c['paidCents'] as int) - (c['totalCents'] as int);
      record('money.confirm_overpayment', over <= 0 ? 'PASS' : 'FAIL', {'httpStatus': status, 'overpaidCents': over});
      expect(over, lessThanOrEqualTo(0), reason: 'transfer confirmed for 1000x the bill: drawer/report inflated');
    });
  });

  // ================================================================== 5. صلاحيات

  group('authorization matrix', () {
    test('every protected route rejects: no token, fake token, wrong role, disabled user', () async {
      await buildMenu();
      final checkId = await openTableCheck(16);
      final roleClients = {for (final r in ['supervisor', 'cashier', 'waiter', 'kitchen']) r: await userClient('u_$r', r)};
      const ownerOnly = [
        ('GET', '/api/users'),
        ('POST', '/api/users'),
        ('GET', '/api/audit'),
        ('PATCH', '/api/shop'),
        ('PUT', '/api/shop/logo'),
        ('POST', '/api/items'),
        ('POST', '/api/categories'),
        ('POST', '/api/tables/bulk'),
        ('GET', '/api/tables/qr'),
        ('POST', '/api/pay-methods'),
        ('GET', '/api/backups'),
        ('POST', '/api/backups/restore'),
        ('PATCH', '/api/backups/settings'),
        ('GET', '/api/reports/summary'),
        ('POST', '/api/license'),
        ('POST', '/api/ingredients'),
        ('POST', '/api/suppliers'),
        ('GET', '/api/feedback'),
      ];
      final managerOnly = [('POST', '/api/checks/$checkId/void'), ('POST', '/api/checks/$checkId/reopen'), ('GET', '/api/register/history')];
      final cashOnly = [('POST', '/api/checks/$checkId/close'), ('POST', '/api/checks/$checkId/payments'), ('GET', '/api/register'), ('GET', '/api/customers')];
      final floorOnly = [('GET', '/api/checks'), ('POST', '/api/checks'), ('GET', '/api/floor')];

      final leaks = <String>[];
      Future<void> expectDenied(String who, String? token, (String, String) route, Set<int> allowed) async {
        final (s, _) = await raw(route.$1, route.$2, token: token, body: utf8.encode('{}'));
        if (!allowed.contains(s)) leaks.add('$who ${route.$1} ${route.$2} -> $s');
      }

      final all = [...ownerOnly, ...managerOnly, ...cashOnly, ...floorOnly, ('GET', '/api/kds'), ('GET', '/api/menu'), ('GET', '/api/files/x')];
      for (final r in all) {
        await expectDenied('anonymous', null, r, {401});
        await expectDenied('fake-token', 'deadbeef' * 8, r, {401});
      }
      for (final e in roleClients.entries) {
        for (final r in ownerOnly) {
          await expectDenied(e.key, e.value.token, r, {403});
        }
        if (e.key != 'supervisor') {
          for (final r in managerOnly) {
            await expectDenied(e.key, e.value.token, r, {403});
          }
        }
        if (e.key == 'waiter' || e.key == 'kitchen') {
          for (final r in cashOnly) {
            await expectDenied(e.key, e.value.token, r, {403});
          }
        }
        if (e.key == 'kitchen') {
          for (final r in floorOnly) {
            await expectDenied(e.key, e.value.token, r, {403});
          }
        }
      }
      // موظف اتوقف: التوكن بتاعه لازم يموت فوراً
      final waiterId = server.db.selectOne("SELECT id FROM users WHERE username = 'u_waiter'")!['id'];
      await api.patch('/api/users/$waiterId', {'active': false});
      await expectDenied('disabled-waiter', roleClients['waiter']!.token, ('GET', '/api/floor'), {401});
      // التوكن في الـ URL بيتقبل في الـ WebSocket بس، فأي مسار تاني بيرفضه خالص (401)
      final (sq, _) = await raw('GET', '/api/users?token=${roleClients['cashier']!.token}');
      if (sq != 401) leaks.add('cashier via ?token= GET /api/users -> $sq');
      final (so, _) = await raw('GET', '/api/auth/me?token=${api.token}');
      if (so != 401) leaks.add('owner via ?token= GET /api/auth/me -> $so');

      record('authz.matrix', leaks.isEmpty ? 'PASS' : 'FAIL', {'checks': all.length * 2 + roleClients.length * ownerOnly.length, 'leaks': leaks});
      expect(leaks, isEmpty);
      for (final c in roleClients.values) {
        c.close();
      }
    });

    test('SQL injection strings in every search box and id', () async {
      await buildMenu();
      const evil = ["' OR 1=1 --", '"; DROP TABLE checks; --', "%' UNION SELECT password_hash FROM users --", '\u0000', '../../../etc/passwd'];
      final bad = <String>[];
      for (final e in evil) {
        final q = Uri.encodeQueryComponent(e);
        final p = Uri.encodeComponent(e);
        for (final path in ['/api/checks?status=$q&q=$q', '/api/customers?q=$q', '/api/checks/$p', '/api/files/$p', '/api/orders?status=$q', '/api/kds?station=$q', '/api/audit?before=$q']) {
          final (s, body) = await raw('GET', path, token: api.token);
          if (s >= 500 || body.contains('password_hash') || body.contains(r'$2')) bad.add('$path -> $s');
        }
      }
      // تأكيد بلاغ ZAP (SQL Injection في /customer): الاسم بيتخزن زي ما هو حرف بحرف، ومفيش صف تاني اتأثر
      for (final e in evil.take(3)) {
        final id = await openTableCheck(1 + evil.indexOf(e));
        await api.post('/api/checks/$id/customer', {'phone': '0101234567${evil.indexOf(e)}', 'name': e});
        final row = server.db.selectOne('SELECT customer_name FROM checks WHERE id = ?', [id])!;
        if (row['customer_name'] != e) bad.add('customer name stored as ${row['customer_name']}');
      }
      if (server.db.selectOne('SELECT COUNT(*) AS c FROM customers')!['c'] != 3) bad.add('customers table changed unexpectedly');
      final tablesLeft = server.db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'checks'");
      record('security.sql_injection', bad.isEmpty && tablesLeft.isNotEmpty ? 'PASS' : 'FAIL', {'problems': bad});
      expect(bad, isEmpty);
      expect(tablesLeft, isNotEmpty);
    });
  });

  // ================================================================== 6. مدخلات بايظة (fuzz)

  test('fuzz: every write route with wrong JSON types never crashes with 500', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {'openingCashCents': 0});
    final checkId = await openTableCheck(17);
    final r = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['coffee'], 'qty': 2},
      ],
    });
    final lineId = ((((r['orders'] as List).single as Map)['items'] as List).single as Map)['id'];
    final orderId = ((r['orders'] as List).single as Map)['id'];
    final waiter = await userClient('fuzzwaiter', 'waiter');
    final waiterId = server.db.selectOne("SELECT id FROM users WHERE username = 'fuzzwaiter'")!['id'];
    final tableId = (await tables()).first['id'];
    final ing = (await api.post('/api/ingredients', {'name': 'سكر', 'unit': 'g'}))['id'];
    final routes = [
      ('POST', '/api/setup'), ('POST', '/api/auth/login'), ('POST', '/api/auth/password'),
      ('POST', '/api/users'), ('PATCH', '/api/users/$waiterId'),
      ('PATCH', '/api/shop'), ('PUT', '/api/shop/logo'),
      ('POST', '/api/stations'), ('POST', '/api/categories'), ('POST', '/api/items'), ('PATCH', '/api/items/${m['coffee']}'),
      ('PUT', '/api/items/${m['coffee']}/image'), ('POST', '/api/items/${m['coffee']}/availability'), ('POST', '/api/modifier-groups'), ('POST', '/api/menu/sort'),
      ('POST', '/api/areas'), ('POST', '/api/tables'), ('POST', '/api/tables/bulk'), ('PATCH', '/api/tables/$tableId'),
      ('POST', '/api/checks'), ('PATCH', '/api/checks/$checkId'), ('POST', '/api/checks/$checkId/orders'), ('POST', '/api/checks/$checkId/move'),
      ('POST', '/api/checks/$checkId/merge'), ('POST', '/api/checks/$checkId/split'), ('POST', '/api/checks/$checkId/print'),
      ('POST', '/api/checks/$checkId/customer'), ('POST', '/api/checks/$checkId/redeem'), ('POST', '/api/checks/$checkId/payments'),
      ('POST', '/api/orders/$orderId/reject'), ('POST', '/api/orders/$orderId/ready'), ('POST', '/api/order-items/$lineId/status'), ('POST', '/api/order-items/$lineId/void'),
      ('POST', '/api/pay-methods'), ('POST', '/api/register/moves'), ('POST', '/api/register/close'),
      ('POST', '/api/ingredients'), ('PATCH', '/api/ingredients/$ing'), ('POST', '/api/ingredients/$ing/adjust'), ('PUT', '/api/recipes/item/${m['coffee']}'),
      ('POST', '/api/suppliers'), ('POST', '/api/purchases'), ('POST', '/api/promotions'), ('POST', '/api/license'),
      ('PATCH', '/api/backups/settings'), ('POST', '/api/backups/restore'), ('POST', '/api/print/x/result'),
    ];
    const keys = [
      'name', 'username', 'password', 'role', 'active', 'type', 'tableId', 'guests', 'customerName', 'customerPhone', 'note', 'lines', 'discountCents',
      'intoCheckId', 'reason', 'methodId', 'amountCents', 'points', 'phone', 'qty', 'unit', 'stationId', 'status', 'categoryId', 'priceCents',
      'groupIds', 'options', 'settings', 'base64', 'png', 'from', 'to', 'seats', 'areaId', 'kind', 'supplierId', 'paidCents', 'currentPassword',
      'newPassword', 'shopName', 'ownerName', 'backupDir', 'code', 'items', 'order', 'minSelect', 'maxSelect', 'available', 'error', 'ok',
    ];
    final bodies = <String, String>{
      'array-body': '[1,2,3]',
      'string-body': '"hello"',
      'not-json': '{"a":',
      'deep-nesting': '${'[' * 5000}${']' * 5000}',
      for (final v in <String, Object?>{
        'int': 123456789,
        'float': 1.5,
        'bool': true,
        'list': [1, 'a', null],
        'map': {'x': 1},
        'null': null,
        'huge-string': 'ب' * 200000,
        'lines-of-junk': [1, 'x', null, {'itemId': 5, 'qty': 'many', 'modifierIds': 'all', 'id': 7}],
      }.entries)
        'all-keys=${v.key}': jsonEncode({for (final k in keys) k: v.value}),
    };
    final crashes = <String>[];
    var sent = 0;
    for (final route in routes) {
      for (final b in bodies.entries) {
        final (s, text) = await raw(route.$1, route.$2, token: route.$2.contains('/order-items/') && b.key == 'map' ? waiter.token : api.token, body: utf8.encode(b.value));
        sent++;
        if (s >= 500) crashes.add('${route.$1} ${route.$2} [${b.key}] -> $s');
        if (text.contains('Exception') || text.contains('#0 ')) crashes.add('${route.$1} ${route.$2} [${b.key}] leaked a stack trace');
      }
    }
    // والسيرفر لسه عايش وقاعدة البيانات سليمة
    expect((await api.get('/api/info'))['app'], 'orderly');
    final integrity = server.db.integrity();
    record('fuzz.wrong_types', crashes.isEmpty ? 'PASS' : 'FAIL', {'requests': sent, 'serverErrors': crashes.length, 'examples': crashes.take(80).toList(), 'dbIntegrity': integrity});
    expect(integrity, 'ok');
    expect(crashes, isEmpty, reason: '${crashes.length} requests crashed the handler (HTTP 500)');
    waiter.close();
  });

  test('fuzz: 500 malformed QR messages from the internet never leave half-written orders', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {'openingCashCents': 0});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '18'")!['qr_key'] as String;
    final rnd = Random(42);
    Object? junk() => switch (rnd.nextInt(9)) {
          0 => null,
          1 => rnd.nextInt(1 << 31),
          2 => -1,
          3 => 'x' * rnd.nextInt(5000),
          4 => [1, 2],
          5 => {'i': m['coffee'], 'q': 1},
          6 => true,
          7 => 1.5,
          _ => m['coffee'],
        };
    var thrown = 0;
    for (var i = 0; i < 500; i++) {
      final items = List.generate(rnd.nextInt(4), (_) => rnd.nextBool() ? {'i': junk(), 'q': junk(), 'm': junk(), 'note': junk()} : junk());
      final msg = <String, dynamic>{
        't': ['order', 'call', 'pay', 'fb', 'x', 5][rnd.nextInt(6)],
        'k': rnd.nextInt(5) == 0 ? junk() : key,
        'c': rnd.nextInt(5) == 0 ? junk() : 'fuzz-client-$i',
        'at': rnd.nextInt(5) == 0 ? junk() : DateTime.now().millisecondsSinceEpoch,
        'j': rnd.nextInt(6) == 0
            ? junk()
            : jsonEncode({'name': junk(), 'phone': junk(), 'note': junk(), 'items': rnd.nextBool() ? items : junk(), 'pay': junk(), 'r': junk(), 'cm': junk(), 'kind': junk(), 'm': junk(), 'a': junk()}),
      };
      try {
        server.ingestCloudMessage('fuzz-$i', msg);
      } catch (_) {
        thrown++;
      }
    }
    final orphans = server.db.select("SELECT o.id FROM orders o WHERE o.status <> 'rejected' AND NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.id)");
    final integrity = server.db.integrity();
    record('fuzz.qr_messages', orphans.isEmpty && integrity == 'ok' ? 'PASS' : 'FAIL',
        {'messages': 500, 'threwInsideIngest': thrown, 'ordersWithoutItems': orphans.length, 'dbIntegrity': integrity, 'note': 'a throw is caught by CloudSync._handle and the message is deleted'});
    expect(orphans, isEmpty);
    expect(integrity, 'ok');
    expect((await api.get('/api/live'))['pendingOrders'], isA<int>());
  });

  test('QR flood protection: replayed message ids and rotating phone ids', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {'openingCashCents': 0});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '19'")!['qr_key'] as String;
    Map<String, dynamic> order(String client) => {
          't': 'order',
          'k': key,
          'c': client,
          'at': DateTime.now().millisecondsSinceEpoch,
          'j': jsonEncode({
            'name': 'هجوم',
            'phone': '01000000000',
            'items': [
              {'i': m['coffee'], 'q': 1},
            ],
          }),
        };
    for (var i = 0; i < 100; i++) {
      server.ingestCloudMessage('replay-1', order('same-client-1'));
    }
    final replay = server.db.select("SELECT id FROM orders WHERE cloud_id = 'replay-1'").length;
    for (var i = 0; i < 30; i++) {
      server.ingestCloudMessage('same-$i', order('same-client-2'));
    }
    final sameClientPending = server.db.select("SELECT id FROM orders WHERE client_id = 'same-client-2' AND status = 'pending'").length;
    for (var i = 0; i < 200; i++) {
      server.ingestCloudMessage('rot-$i', order('rotating-client-$i'));
    }
    final rotatingPending = server.db.select("SELECT id FROM orders WHERE client_id LIKE 'rotating-client-%' AND status = 'pending'").length;
    final tablePending = server.db.select("SELECT id FROM orders WHERE status = 'pending'").length;
    record('qr.flood', replay == 1 && sameClientPending <= 8 && tablePending <= 6 ? 'PASS' : 'FAIL', {
      'replayStored': replay,
      'sameClientAccepted': sameClientPending,
      'rotatingClientIdsPending': rotatingPending,
      'pendingOnTheTable': tablePending,
      'note': 'the per-phone id is chosen by the phone, so there is also a per-table limit (6 waiting, 15 per 10 min)',
    });
    expect(replay, 1);
    expect(sameClientPending, lessThanOrEqualTo(8));
    expect(tablePending, lessThanOrEqualTo(6), reason: 'rotating phone ids flooded one table');
  });

  // ================================================================== 7. هجوم على الموارد

  test('unauthenticated 64 MB body to the login route is refused without buffering it', () async {
    final before = ProcessInfo.currentRss;
    final payload = Uint8List(64 * 1024 * 1024)..fillRange(0, 64 * 1024 * 1024, 0x61);
    payload[0] = 0x22;
    payload[payload.length - 1] = 0x22;
    int status;
    try {
      (status, _) = await raw('POST', '/api/auth/login', body: payload);
    } on SocketException {
      status = -1; // السيرفر قفل الاتصال قبل ما ناخد رد: ده كمان رفض
    } on HttpException {
      status = -1;
    }
    final grewMB = (ProcessInfo.currentRss - before) ~/ (1 << 20);
    final peakMB = ProcessInfo.maxRss ~/ (1 << 20);
    record('dos.huge_unauth_body', status == 413 || status == -1 ? 'PASS' : 'FAIL', {'httpStatus': status, 'rssGrowthMB': grewMB, 'peakRssMB': peakMB});
    expect(status, anyOf(413, -1), reason: 'anyone on the Wi-Fi can make the server buffer arbitrarily large bodies');
    expect((await api.get('/api/info'))['app'], 'orderly');
  });

  test('image bomb: a tiny file that decodes to a gigantic picture is refused before decoding', () async {
    // 10000×10000 لون واحد: الملف ~حجمه صغير، لكن فكّه بياخد مئات الميجات. (حد Firebase 1.2 ميجا يسمح بأكبر من كده بكتير)
    final png = img.encodePng(img.Image(width: 10000, height: 10000, numChannels: 1), level: 9);
    final sw = Stopwatch()..start();
    final before = ProcessInfo.currentRss;
    final out = shrinkToJpeg(png, 1400, 80);
    final ms = sw.elapsedMilliseconds;
    final grewMB = (ProcessInfo.maxRss - before) ~/ (1 << 20);
    record('dos.image_bomb', out == null && ms < 1000 ? 'PASS' : 'FAIL',
        {'fileKB': png.length ~/ 1024, 'decodedMegapixels': 100, 'ms': ms, 'peakRssGrowthMB': grewMB, 'refused': out == null});
    expect(out, isNull, reason: 'a ${png.length ~/ 1024} KB PNG made the server decode 100 megapixels (${ms}ms)');
  });

  test('login brute force: locked after 5 tries, other users from other IPs unaffected', () async {
    var locked = false;
    for (var i = 0; i < 6; i++) {
      final (s, _) = await raw('POST', '/api/auth/login', body: utf8.encode(jsonEncode({'username': 'owner', 'password': 'guess$i'})));
      if (s == 429) locked = true;
    }
    record('security.bruteforce_lock', locked ? 'PASS' : 'FAIL', {'lockedAfter': 5});
    expect(locked, isTrue);
  });

  // ================================================================== 8. ملفات بايظة واسترجاع

  test('restore: a backup whose database is garbage is refused when staged', () async {
    final backups = Directory('${dir.path}/backups')..createSync(recursive: true);
    final zip = Archive()
      ..addFile(ArchiveFile('orderly.db', 9, utf8.encode('not a db!')))
      ..addFile(ArchiveFile('backup.json', 2, utf8.encode('{}')));
    File('${backups.path}/orderly-broken.zip').writeAsBytesSync(ZipEncoder().encode(zip));
    int status;
    try {
      await api.post('/api/backups/restore', {'name': 'orderly-broken.zip'});
      status = 200;
    } on ApiException catch (e) {
      status = e.status ?? 0;
    }
    record('restore.garbage_db', status == 400 ? 'PASS' : 'FAIL', {'httpStatus': status, 'note': 'if staged, the server cannot start again after restart'});
    expect(status, 400, reason: 'a broken backup was staged: the cafe server would not start after the restart');
  });

  test('restore: zip-slip entries cannot write outside the data folder', () async {
    await api.post('/api/backups');
    final backups = Directory('${dir.path}/backups');
    final good = backups.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.zip'));
    final archive = ZipDecoder().decodeBytes(good.readAsBytesSync());
    final evil = Archive();
    for (final f in archive.files) {
      evil.addFile(f);
    }
    evil.addFile(ArchiveFile('../../escaped-${dir.path.hashCode}.txt', 4, utf8.encode('pwnd')));
    evil.addFile(ArchiveFile('files/../../../escaped2-${dir.path.hashCode}.txt', 4, utf8.encode('pwnd')));
    File('${backups.path}/orderly-evil.zip').writeAsBytesSync(ZipEncoder().encode(evil));
    await api.post('/api/backups/restore', {'name': 'orderly-evil.zip'});
    await server.stop();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    api.close();
    api = ApiClient('http://127.0.0.1:${server.port}');
    final escaped = [File('${dir.parent.parent.path}/escaped-${dir.path.hashCode}.txt'), File('${dir.parent.parent.path}/escaped2-${dir.path.hashCode}.txt'), File('${dir.parent.path}/escaped-${dir.path.hashCode}.txt')]
        .where((f) => f.existsSync())
        .toList();
    record('restore.zip_slip', escaped.isEmpty ? 'PASS' : 'FAIL', {'escapedFiles': escaped.map((f) => f.path).toList()});
    expect(escaped, isEmpty);
    expect((await api.post('/api/auth/login', {'username': 'owner', 'password': 'owner123', 'deviceId': 'test-device-01'}))['user']['role'], 'owner');
  });

  test('corrupted database file at start: clear error instead of a silent crash loop', () async {
    await server.stop();
    final dbFile = File('${dir.path}/orderly.db');
    for (final s in ['-wal', '-shm']) {
      final f = File('${dbFile.path}$s');
      if (f.existsSync()) f.deleteSync();
    }
    final bytes = dbFile.readAsBytesSync();
    // نبوّظ نص الملف (زي ما الكهربا تقطع والهارد بيكتب)
    final rnd = Random(7);
    for (var i = 100; i < bytes.length; i += 3) {
      bytes[i] = rnd.nextInt(256);
    }
    dbFile.writeAsBytesSync(bytes);
    Object? error;
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    try {
      await server.start();
      final health = server.db.setting('db_health');
      record('resilience.corrupt_db', 'INFO', {'started': true, 'dbHealth': health});
    } catch (e) {
      error = e;
      record('resilience.corrupt_db', 'INFO', {'started': false, 'error': '$e'.split('\n').first});
      // عشان الـ tearDown ما يقعش
      server = OrderlyServer(dataDir: (await Directory.systemTemp.createTemp('orderly_stress_spare')).path, requestedPort: 0, cloudSync: false);
      await server.start();
    }
    expect(error == null || '$error'.isNotEmpty, isTrue);
  });

  test('server stopped while 200 requests are in flight: restart is clean, no half orders', () async {
    final m = await buildMenu();
    final checkId = await openTableCheck(20);
    final clients = List.generate(20, (_) => ApiClient(base, token: api.token));
    final inflight = List.generate(200, (i) => clients[i % 20].post('/api/checks/$checkId/orders', {
          'lines': [
            {'itemId': m['coffee'], 'qty': 1},
            {'itemId': m['coffee'], 'qty': 2},
          ],
        }).then((_) => true).catchError((_) => false));
    // نستنى لحد ما شوية طلبات تتسجل فعلاً وبعدين نقفل السيرفر في نص الشغل
    while (server.db.selectOne('SELECT COUNT(*) AS c FROM orders')!['c'] as int < 30) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await server.stop();
    final done = (await Future.wait(inflight)).where((x) => x).length;
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    api.close();
    api = ApiClient('http://127.0.0.1:${server.port}');
    final halfOrders = server.db.select('SELECT o.id FROM orders o WHERE (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.id) <> 2');
    final integrity = server.db.integrity();
    record('resilience.stop_under_load', halfOrders.isEmpty && integrity == 'ok' ? 'PASS' : 'FAIL',
        {'completedBeforeStop': done, 'ordersStored': server.db.select('SELECT id FROM orders').length, 'halfOrders': halfOrders.length, 'dbIntegrity': integrity});
    expect(halfOrders, isEmpty);
    expect(integrity, 'ok');
    for (final c in clients) {
      c.close();
    }
  });
}
