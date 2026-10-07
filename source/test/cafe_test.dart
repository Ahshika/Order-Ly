import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// اختبارات الكافيه كلها على فولدر مؤقت (عمرها ما بتلمس بيانات حقيقية).
void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_cafe');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {
      'shopName': 'كافيه الندى',
      'ownerName': 'أحمد',
      'username': 'owner',
      'password': 'owner123',
    }))['token'] as String;
  });

  tearDown(() async {
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<void> expectApiError(Future<Object?> f, int status, [String? text]) async {
    try {
      await f;
      fail('expected ApiException $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
      if (text != null) expect(e.message, contains(text));
    }
  }

  /// منيو صغير: قسم مشروبات (البار) فيه لاتيه بحجمين وإضافات، وقسم حلويات (المطبخ).
  Future<Map<String, String>> buildMenu() async {
    var menu = await api.get('/api/menu');
    final stations = (menu['stations'] as List).cast<Map<String, dynamic>>();
    final bar = stations.firstWhere((s) => s['name'] == 'البار')['id'] as String;
    final kitchen = stations.firstWhere((s) => s['name'] == 'المطبخ')['id'] as String;
    await api.post('/api/categories', {'name': 'مشروبات ساخنة', 'nameEn': 'Hot drinks', 'stationId': bar});
    await api.post('/api/categories', {'name': 'حلويات', 'stationId': kitchen});
    menu = await api.get('/api/menu');
    final cats = (menu['categories'] as List).cast<Map<String, dynamic>>();
    final hot = cats.firstWhere((c) => c['name'] == 'مشروبات ساخنة')['id'] as String;
    final sweets = cats.firstWhere((c) => c['name'] == 'حلويات')['id'] as String;

    final size = await api.post('/api/modifier-groups', {
      'name': 'الحجم',
      'minSelect': 1,
      'maxSelect': 1,
      'options': [
        {'name': 'وسط', 'priceCents': 0, 'isDefault': true},
        {'name': 'كبير', 'priceCents': 1500},
      ],
    });
    final extras = await api.post('/api/modifier-groups', {
      'name': 'إضافات',
      'minSelect': 0,
      'maxSelect': 2,
      'options': [
        {'name': 'شوت إسبريسو', 'priceCents': 1000},
        {'name': 'لبن شوفان', 'priceCents': 1200},
      ],
    });
    final latte = await api.post('/api/items', {
      'categoryId': hot,
      'name': 'لاتيه',
      'priceCents': 6000,
      'groupIds': [size['id'], extras['id']],
    });
    final cake = await api.post('/api/items', {'categoryId': sweets, 'name': 'تشيز كيك', 'priceCents': 8500, 'costCents': 3000});
    menu = await api.get('/api/menu');
    final groups = (menu['modifierGroups'] as List).cast<Map<String, dynamic>>();
    String opt(String group, String name) =>
        ((groups.firstWhere((g) => g['name'] == group)['options'] as List).cast<Map<String, dynamic>>()).firstWhere((o) => o['name'] == name)['id'] as String;
    return {
      'bar': bar,
      'kitchen': kitchen,
      'hot': hot,
      'latte': latte['id'] as String,
      'cake': cake['id'] as String,
      'medium': opt('الحجم', 'وسط'),
      'large': opt('الحجم', 'كبير'),
      'shot': opt('إضافات', 'شوت إسبريسو'),
      'oat': opt('إضافات', 'لبن شوفان'),
    };
  }

  List<Map<String, Object?>> cakeLines(Map<String, String> m) => [
        {'itemId': m['cake'], 'qty': 1},
      ];

  Future<List<Map<String, dynamic>>> tables() async =>
      ((await api.get('/api/floor'))['tables'] as List).cast<Map<String, dynamic>>();

  test('setup seeds stations, an area and cash/card payment methods', () async {
    final menu = await api.get('/api/menu');
    expect((menu['stations'] as List).map((s) => s['name']), containsAll(['البار', 'المطبخ']));
    final methods = (await api.get('/api/pay-methods'))['methods'] as List;
    expect(methods.map((m) => m['kind']), containsAll(['cash', 'card']));
    final floor = await api.get('/api/floor');
    expect((floor['areas'] as List).single['name'], 'الصالة');
  });

  test('modifier rules are enforced and prices are computed on the server', () async {
    final m = await buildMenu();
    await api.post('/api/tables/bulk', {'from': 1, 'to': 5});
    expect((await tables()).length, 5);
    final t1 = (await tables()).firstWhere((t) => t['name'] == '1');
    final check = await api.post('/api/checks', {'type': 'dine_in', 'tableId': t1['id'], 'guests': 2});
    final checkId = check['check']['id'] as String;

    // الحجم إجباري
    await expectApiError(api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1},
      ],
    }), 400, 'الحجم');
    // اختيار من مجموعة مش تبع الصنف
    await expectApiError(api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1, 'modifierIds': [m['shot']]},
      ],
    }), 400);

    final res = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 2, 'modifierIds': [m['large'], m['shot']], 'note': 'سكر خفيف', 'priceCents': 1},
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    // لاتيه كبير + شوت = 60 + 15 + 10 = 85 × 2 = 170، + تشيز كيك 85 = 255
    expect(res['check']['subtotalCents'], 25500);
    expect(res['check']['totalCents'], 25500);

    // تيكت للبار وتيكت للمطبخ
    final jobs = server.db.select("SELECT * FROM print_jobs WHERE kind = 'ticket'");
    expect(jobs.map((j) => j['station_id']).toSet(), {m['bar'], m['kitchen']});
    final barTicket = jsonDecode(jobs.firstWhere((j) => j['station_id'] == m['bar'])['payload'] as String) as Map;
    expect(barTicket['tableName'], '1');
    expect((barTicket['items'] as List).single['note'], 'سكر خفيف');

    // الترابيزة بقت مشغولة
    final floor = (await tables()).firstWhere((t) => t['name'] == '1');
    expect(floor['check']['totalCents'], 25500);
  });

  test('service and tax, discount, cash payment, and closing the table', () async {
    final m = await buildMenu();
    await api.patch('/api/shop', {
      'settings': {'serviceBp': 1200, 'taxBp': 1400},
    });
    await api.post('/api/tables', {'name': 'VIP'});
    final t = (await tables()).single;
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'] as String;
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 2},
      ],
    });
    var c = (await api.patch('/api/checks/$checkId', {'discountCents': 1000, 'discountNote': 'عميل دايم'}))['check'];
    // 170 - 10 = 160؛ خدمة 12% = 19.2؛ ضريبة 14% على 179.2 = 25.09
    expect(c['subtotalCents'], 17000);
    expect(c['serviceCents'], 1920);
    expect(c['taxCents'], 2509);
    expect(c['totalCents'], 16000 + 1920 + 2509);

    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    // الدرج لازم يبقى مفتوح
    await expectApiError(api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 100}), 400, 'الدرج');
    await api.post('/api/register/open', {'openingCashCents': 50000});
    await expectApiError(api.post('/api/checks/$checkId/close'), 400, 'فاضل');
    await expectApiError(api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 999999}), 400, 'أكبر');
    await api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 10000});
    c = (await api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 10429, 'close': true}))['check'];
    expect(c['status'], 'closed');
    expect((await tables()).single['check'], isNull);

    final reg = await api.get('/api/register');
    expect(reg['session']['expectedCashCents'], 50000 + 20429);
    final closed = await api.post('/api/register/close', {'countedCashCents': 70429, 'keptCashCents': 50000});
    expect(closed['closed']['salesCents'], 20429);
  });

  test('kitchen display: bar marks its items ready, then the order is served', () async {
    final m = await buildMenu();
    final checkId = (await api.post('/api/checks', {'type': 'takeaway', 'customerName': 'منى'}))['check']['id'] as String;
    final res = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['medium']]},
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    final orderId = res['orderId'] as String;
    var kds = await api.get('/api/kds', query: {'station': m['bar']!});
    expect((kds['orders'] as List).single['items'].length, 1);
    await api.post('/api/orders/$orderId/ready', {'stationId': m['bar']});
    // المطبخ لسه
    expect(server.db.selectOne('SELECT status FROM orders WHERE id = ?', [orderId])!['status'], 'accepted');
    await api.post('/api/orders/$orderId/ready', {'stationId': m['kitchen']});
    expect(server.db.selectOne('SELECT status FROM orders WHERE id = ?', [orderId])!['status'], 'ready');
    kds = await api.get('/api/kds', query: {'station': m['bar']!});
    expect((kds['orders'] as List).single['status'], 'ready');
    await api.post('/api/orders/$orderId/served');
    expect(server.db.selectOne('SELECT status FROM orders WHERE id = ?', [orderId])!['status'], 'served');
    expect((await api.get('/api/kds'))['orders'], isEmpty);
  });

  test('kitchen display stays complete and in order with many orders, and is capped', () async {
    final m = await buildMenu();
    await api.post('/api/tables/bulk', {'from': 1, 'to': 3});
    final t1 = (await tables()).firstWhere((t) => t['name'] == '1');
    final dineIn = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t1['id']}))['check']['id'] as String;
    await api.post('/api/checks/$dineIn/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['large']]},
        {'itemId': m['cake'], 'qty': 2},
      ],
    });
    final takeaway = (await api.post('/api/checks', {'type': 'takeaway', 'customerName': 'سارة'}))['check']['id'] as String;
    await api.post('/api/checks/$takeaway/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });

    var kds = (await api.get('/api/kds'))['orders'] as List;
    expect(kds.length, 2);
    expect(kds[0]['tableName'], '1');
    expect(kds[0]['checkType'], 'dine_in');
    expect((kds[0]['items'] as List).map((i) => i['name']), ['لاتيه', 'تشيز كيك']);
    expect(kds[1]['checkType'], 'takeaway');
    expect(kds[1]['customerName'], 'سارة');
    expect(kds[1]['tableName'], isNull);
    // البار بيشوف اللاتيه بس، والطلب التيك أواي (حلويات بس) مش عنده
    kds = (await api.get('/api/kds', query: {'station': m['bar']!}))['orders'] as List;
    expect(kds.single['items'].single['name'], 'لاتيه');

    // المطبخ اتملى: الشاشة بتعرض أقدم ${kdsLimit} طلب بس
    final cakeLine = [
      {'itemId': m['cake'], 'qty': 1},
    ];
    for (var i = 0; i < kdsLimit; i++) {
      await api.post('/api/checks/$takeaway/orders', {'lines': cakeLine});
    }
    kds = (await api.get('/api/kds'))['orders'] as List;
    expect(kds.length, kdsLimit);
    expect(kds.first['tableName'], '1');
  });

  test('pay-and-close saves nothing when an order was added in the meantime', () async {
    final m = await buildMenu();
    final checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    final first = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    final shownDue = first['check']['totalCents'] as int;
    await api.post('/api/register/open', {'openingCashCents': 0});
    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    // الويتر ضاف طلب والكاشير لسه شايف المبلغ القديم
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    await expectApiError(api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': shownDue, 'close': true}), 400, 'مفيش فلوس اتسجلت');
    expect(server.db.selectOne('SELECT COUNT(*) AS n FROM payments WHERE check_id = ?', [checkId])!['n'], 0);
    var c = (await api.get('/api/checks/$checkId'))['check'];
    expect(c['status'], 'open');
    expect(c['paidCents'], 0);

    // بالمبلغ الجديد بيتدفع ويتقفل عادي
    c = (await api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': c['totalCents'], 'close': true}))['check'];
    expect(c['status'], 'closed');
    // ودفع جزء من غير قفل لسه شغال
    final other = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$other/orders', {'lines': cakeLines(m)});
    c = (await api.post('/api/checks/$other/payments', {'methodId': cash, 'amountCents': 1000}))['check'];
    expect(c['paidCents'], 1000);
    expect(c['status'], 'open');
  });

  test('recipes consume stock, sold-out items are blocked, and voids return stock', () async {
    final m = await buildMenu();
    final milk = await api.post('/api/ingredients', {'name': 'لبن', 'unit': 'ml', 'qty': 400, 'unitCost': 3.5});
    final beans = await api.post('/api/ingredients', {'name': 'بن', 'unit': 'g', 'qty': 1000, 'unitCost': 80});
    await api.put('/api/recipes/item/${m['latte']}', {
      'lines': [
        {'ingredientId': milk['id'], 'qty': 200},
        {'ingredientId': beans['id'], 'qty': 18},
      ],
    });
    // الشوت الزيادة بياخد بن كمان
    await api.put('/api/recipes/option/${m['shot']}', {
      'lines': [
        {'ingredientId': beans['id'], 'qty': 9},
      ],
    });
    var latte = ((await api.get('/api/menu'))['items'] as List).firstWhere((i) => i['id'] == m['latte']);
    expect(latte['recipeCostCents'], 200 * 3.5 + 18 * 80);

    final checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    final res = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['medium'], m['shot']]},
      ],
    });
    double qty(String id) => (server.db.selectOne('SELECT qty FROM ingredients WHERE id = ?', [id])!['qty'] as num).toDouble();
    expect(qty(milk['id'] as String), 200);
    expect(qty(beans['id'] as String), 1000 - 27);
    final line = server.db.selectOne('SELECT * FROM order_items WHERE order_id = ?', [res['orderId']])!;
    expect(line['cost_cents'], (200 * 3.5 + 27 * 80).round());

    // اللبن بقى 200 بس: لاتيه واحد كمان وبعدين يخلص
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['medium']]},
      ],
    });
    latte = ((await api.get('/api/menu'))['items'] as List).firstWhere((i) => i['id'] == m['latte']);
    expect(latte['soldOut'], true);
    await expectApiError(api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['medium']]},
      ],
    }), 409, 'خلص');

    // إلغاء صنف لسه ما اتحضرش: الخامات بترجع
    final detail = await api.get('/api/checks/$checkId');
    final lastLine = ((detail['orders'] as List).last['items'] as List).single;
    await api.post('/api/order-items/${lastLine['id']}/void', {'reason': 'العميل غيّر رأيه'});
    expect(qty(milk['id'] as String), 200);
    final c = (await api.get('/api/checks/$checkId'))['check'];
    expect(c['subtotalCents'], 7000); // الأول بس: 60 + شوت 10

    // جرد وهالك
    await api.post('/api/ingredients/${milk['id']}/adjust', {'reason': 'waste', 'qty': 50});
    expect(qty(milk['id'] as String), 150);
    await api.post('/api/ingredients/${milk['id']}/adjust', {'reason': 'count', 'qty': 1000});
    expect(qty(milk['id'] as String), 1000);
    // فاتورة شرا بتحدّث متوسط التكلفة
    await api.post('/api/purchases', {
      'lines': [
        {'ingredientId': milk['id'], 'qty': 1000, 'totalCents': 4500},
      ],
    });
    final ing = server.db.selectOne('SELECT * FROM ingredients WHERE id = ?', [milk['id']])!;
    expect(ing['qty'], 2000);
    expect((ing['unit_cost'] as num).toDouble(), closeTo((1000 * 3.5 + 4500) / 2000, 0.001));
  });

  test('move, merge and split checks', () async {
    final m = await buildMenu();
    await api.post('/api/tables/bulk', {'from': 1, 'to': 3});
    final ts = await tables();
    String tid(String n) => ts.firstWhere((t) => t['name'] == n)['id'] as String;
    final a = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': tid('1')}))['check']['id'] as String;
    final b = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': tid('2')}))['check']['id'] as String;
    // نفس الترابيزة بترجع نفس الحساب
    expect((await api.post('/api/checks', {'type': 'dine_in', 'tableId': tid('1')}))['check']['id'], a);
    await api.post('/api/checks/$a/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 3, 'guest': 'علي'},
      ],
    });
    await api.post('/api/checks/$b/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    await expectApiError(api.post('/api/checks/$a/move', {'tableId': tid('2')}), 409, 'دمج');
    await api.post('/api/checks/$a/move', {'tableId': tid('3')});
    expect((await tables()).firstWhere((t) => t['name'] == '3')['check']['id'], a);

    final merged = await api.post('/api/checks/$b/merge', {'intoCheckId': a});
    expect(merged['check']['subtotalCents'], 4 * 8500);
    expect(server.db.selectOne('SELECT status FROM checks WHERE id = ?', [b])!['status'], 'void');

    // علي هيدفع واحدة لوحده
    final line = ((merged['orders'] as List).expand((o) => o['items'] as List)).firstWhere((i) => i['qty'] == 3);
    final split = await api.post('/api/checks/$a/split', {
      'lines': [
        {'id': line['id'], 'qty': 1},
      ],
    });
    expect(split['check']['subtotalCents'], 8500);
    expect((await api.get('/api/checks/$a'))['check']['subtotalCents'], 3 * 8500);
  });

  test('QR order: manual approval, accept, and the bill shows on the table', () async {
    final m = await buildMenu();
    await api.post('/api/tables', {'name': '7'});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '7'")!['qr_key'] as String;
    Map<String, dynamic> order(String clientId, List<Map<String, Object?>> items, {Map<String, Object?>? pay}) => {
          't': 'order',
          'k': key,
          'c': clientId,
          'at': DateTime.now().millisecondsSinceEpoch,
          'j': jsonEncode({'name': 'سلمى', 'phone': '٠١٠١٢٣٤٥٦٧٨', 'items': items, if (pay != null) 'pay': pay}),
        };

    // الدرج مقفول: الطلب بيترفض بسبب واضح للعميل
    server.ingestCloudMessage('c1', order('phoneA', [
      {'i': m['cake'], 'q': 1},
    ]));
    var o = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'c1'")!;
    expect(o['status'], 'rejected');
    expect(o['reject_reason'], contains('مش بيستقبل'));

    await api.post('/api/register/open', {'openingCashCents': 0});
    server.ingestCloudMessage('c2', order('phoneA', [
      {'i': m['latte'], 'q': 1, 'm': [m['large']]},
    ]));
    o = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'c2'")!;
    expect(o['status'], 'pending');
    // الطلب المستني مش بيتحسب في الحساب ومش بيتطبع
    var t = (await tables()).single;
    expect(t['pendingOrders'], 1);
    expect(t['check']['totalCents'], 0);
    expect(server.db.select("SELECT * FROM print_jobs WHERE kind = 'ticket'"), isEmpty);
    // نفس الرسالة لو وصلت مرتين ما تتسجلش مرتين
    server.ingestCloudMessage('c2', order('phoneA', [
      {'i': m['latte'], 'q': 1, 'm': [m['large']]},
    ]));
    expect(server.db.select("SELECT * FROM orders WHERE cloud_id = 'c2'").length, 1);

    final pending = (await api.get('/api/orders'))['orders'] as List;
    expect(pending.single['tableName'], '7');
    await api.post('/api/orders/${o['id']}/accept');
    t = (await tables()).single;
    expect(t['check']['totalCents'], 7500);
    expect(server.db.select("SELECT * FROM print_jobs WHERE kind = 'ticket'").length, 1);

    // واحد تاني على نفس الترابيزة: بيتجمع في نفس الحساب
    server.ingestCloudMessage('c3', order('phoneB', [
      {'i': m['cake'], 'q': 1},
    ]));
    await api.post('/api/orders/${server.db.selectOne("SELECT id FROM orders WHERE cloud_id = 'c3'")!['id']}/accept');
    expect((await tables()).single['check']['totalCents'], 7500 + 8500);

    // السعر من العميل مالوش لازمة، وصنف مش موجود بيترفض
    server.ingestCloudMessage('c4', order('phoneB', [
      {'i': 'fake', 'q': 1},
    ]));
    expect(server.db.selectOne("SELECT status FROM orders WHERE cloud_id = 'c4'")!['status'], 'rejected');
  });

  test('QR order auto-accept per cafe setting and per table override', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {});
    await api.post('/api/tables/bulk', {'from': 1, 'to': 2});
    await api.patch('/api/shop', {
      'settings': {'qrApproval': 'auto'},
    });
    final ts = await tables();
    final t2 = ts.firstWhere((t) => t['name'] == '2');
    await api.patch('/api/tables/${t2['id']}', {'autoAccept': false});
    String key(String n) => server.db.selectOne('SELECT qr_key FROM tables WHERE name = ?', [n])!['qr_key'] as String;
    Map<String, dynamic> msg(String k) => {
          't': 'order',
          'k': k,
          'c': 'phone$k',
          'at': DateTime.now().millisecondsSinceEpoch,
          'j': jsonEncode({
            'name': 'زبون',
            'phone': '01099998888',
            'items': [
              {'i': m['cake'], 'q': 1},
            ],
          }),
        };
    server.ingestCloudMessage('a1', msg(key('1')));
    server.ingestCloudMessage('a2', msg(key('2')));
    expect(server.db.selectOne("SELECT status FROM orders WHERE cloud_id = 'a1'")!['status'], 'accepted');
    expect(server.db.selectOne("SELECT status FROM orders WHERE cloud_id = 'a2'")!['status'], 'pending');

    // كود ترابيزة غلط أو قديم: الرسالة بتتجاهل
    server.ingestCloudMessage('a3', msg('wrongKey'));
    expect(server.db.selectOne("SELECT id FROM orders WHERE cloud_id = 'a3'"), isNull);

    // طلب قديم (الكمبيوتر كان مقفول) بيترفض
    final stale = msg(key('1'))..['at'] = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    server.ingestCloudMessage('a4', stale);
    expect(server.db.selectOne("SELECT reject_reason FROM orders WHERE cloud_id = 'a4'")!['reject_reason'], contains('اتأخر'));
  });

  test('QR payment with InstaPay screenshot: pending until the cashier confirms', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {});
    await api.patch('/api/shop', {
      'settings': {'qrApproval': 'auto'},
    });
    await expectApiError(api.post('/api/pay-methods', {'name': 'InstaPay', 'kind': 'instapay'}), 400, 'InstaPay');
    final methods = await api.post('/api/pay-methods', {'name': 'InstaPay', 'kind': 'instapay', 'account': 'cafe@instapay'});
    final insta = (methods['methods'] as List).firstWhere((x) => x['kind'] == 'instapay');
    expect(insta['needsProof'], true);
    await api.post('/api/tables', {'name': '4'});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '4'")!['qr_key'] as String;

    final screenshot = img.encodePng(img.Image(width: 50, height: 80));
    server.ingestCloudMessage('p1', {
      't': 'order',
      'k': key,
      'c': 'phoneX',
      'p': true,
      'at': DateTime.now().millisecondsSinceEpoch,
      'j': jsonEncode({
        'name': 'زبون',
        'phone': '01099998888',
        'items': [
          {'i': m['cake'], 'q': 2},
        ],
        'pay': {'m': insta['id'], 'a': 17000},
      }),
    }, screenshot);
    final pay = server.db.selectOne("SELECT * FROM payments WHERE cloud_id = 'p1'")!;
    expect(pay['status'], 'pending');
    expect(pay['amount_cents'], 17000);
    expect(pay['proof_file'], isNotNull);
    // الصورة متاحة للكاشير
    final f = File('${dir.path}/files/${pay['proof_file']}');
    expect(f.existsSync(), true);

    final pending = (await api.get('/api/payments/pending'))['payments'] as List;
    expect(pending.single['tableName'], '4');
    final checkId = pending.single['checkId'] as String;
    // مايتقفلش وفيه تحويل مستني
    await expectApiError(api.post('/api/checks/$checkId/close'), 400);
    final c = await api.post('/api/payments/${pay['id']}/confirm');
    expect(c['check']['paidCents'], 17000);
    final closed = await api.post('/api/checks/$checkId/close');
    expect(closed['check']['status'], 'closed');
    expect((await api.get('/api/register'))['session']['byMethod']['instapay'], 17000);
  });

  test('rejecting a QR order with a transfer rejects the payment and frees the table', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {});
    final methods = await api.post('/api/pay-methods', {'name': 'فودافون كاش', 'kind': 'wallet', 'account': '01000000000'});
    final wallet = (methods['methods'] as List).firstWhere((x) => x['kind'] == 'wallet');
    await api.post('/api/tables', {'name': '9'});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '9'")!['qr_key'] as String;
    server.ingestCloudMessage('r1', {
      't': 'order',
      'k': key,
      'c': 'phoneZ',
      'at': DateTime.now().millisecondsSinceEpoch,
      'j': jsonEncode({
        'name': 'زبون',
        'phone': '01099998888',
        'items': [
          {'i': m['cake'], 'q': 1},
        ],
        'pay': {'m': wallet['id']},
      }),
    });
    final o = server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'r1'")!;
    expect((await tables()).single['check'], isNotNull);
    await api.post('/api/orders/${o['id']}/reject', {'reason': 'الصنف خلص'});
    expect(server.db.selectOne("SELECT status FROM payments WHERE cloud_id = 'r1'")!['status'], 'rejected');
    expect((await tables()).single['check'], isNull);
  });

  test('calling the waiter and asking for the bill from the table', () async {
    final m = await buildMenu();
    await api.post('/api/tables', {'name': '5'});
    final t = (await tables()).single;
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '5'")!['qr_key'] as String;
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'] as String;
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    Map<String, dynamic> call(String kind) => {'t': 'call', 'k': key, 'c': 'p1', 'at': DateTime.now().millisecondsSinceEpoch, 'j': jsonEncode({'kind': kind})};
    server.ingestCloudMessage('w1', call('waiter'));
    server.ingestCloudMessage('w2', call('waiter')); // مكرر
    server.ingestCloudMessage('b1', call('bill'));
    final calls = (await api.get('/api/calls'))['calls'] as List;
    expect(calls.map((c) => c['type']).toList()..sort(), ['bill', 'waiter']);
    expect((await tables()).single['check']['billRequested'], true);
    // الحساب بيتطبع لوحده على طابعة الكاشير
    expect(server.db.select("SELECT * FROM print_jobs WHERE kind = 'bill'").length, 1);
    await api.post('/api/calls/${calls.first['id']}/done');
    expect(((await api.get('/api/calls'))['calls'] as List).length, 1);
  });

  test('print queue: a station device claims only its own jobs', () async {
    final m = await buildMenu();
    final checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['medium']]},
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    await api.post('/api/checks/$checkId/print', {'kind': 'bill'});
    final bar = await api.get('/api/print/claim', query: {'stations': m['bar']!, 'device': 'bar-pc'});
    expect((bar['jobs'] as List).single['payload']['stationName'], 'البار');
    // اتاخد خلاص، محدش ياخده تاني
    expect((await api.get('/api/print/claim', query: {'stations': m['bar']!, 'device': 'x'}))['jobs'], isEmpty);
    final receipt = await api.get('/api/print/claim', query: {'stations': 'receipt', 'device': 'cashier'});
    expect((receipt['jobs'] as List).single['kind'], 'bill');
    await api.post('/api/print/${(bar['jobs'] as List).single['id']}/result', {'ok': true});
  });

  test('happy hour promotion lowers prices only inside its window', () async {
    final m = await buildMenu();
    await api.post('/api/promotions', {
      'name': 'هابي أور',
      'percentBp': 2000,
      'timeFrom': '00:00',
      'timeTo': '23:59',
      'categoryIds': [m['hot']],
    });
    final items = (await api.get('/api/menu'))['items'] as List;
    expect(items.firstWhere((i) => i['id'] == m['latte'])['promoPriceCents'], 4800);
    expect(items.firstWhere((i) => i['id'] == m['cake'])['promoPriceCents'], isNull);
    final checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    final res = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['latte'], 'qty': 1, 'modifierIds': [m['large']]},
      ],
    });
    // الخصم على السعر الأساسي بس، والإضافة بسعرها
    expect(res['check']['subtotalCents'], 4800 + 1500);
  });

  test('loyalty: earn points on close and redeem them later', () async {
    final m = await buildMenu();
    await api.patch('/api/shop', {
      'settings': {'loyaltyEnabled': true, 'loyaltyEarnCents': 1000, 'loyaltyPointValue': 10, 'loyaltyMinRedeem': 5},
    });
    await api.post('/api/register/open', {});
    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    var checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 2},
      ],
    });
    await api.post('/api/checks/$checkId/customer', {'phone': '+20 100 123 4567', 'name': 'هالة'});
    await api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': 17000, 'close': true});
    var customer = ((await api.get('/api/customers'))['customers'] as List).single;
    expect(customer['points'], 17);
    expect(customer['visits'], 1);

    checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    // نفس الرقم بصيغة تانية = نفس العميل
    await api.post('/api/checks/$checkId/customer', {'phone': '01001234567'});
    final c = await api.post('/api/checks/$checkId/redeem', {'points': 15});
    expect(c['check']['totalCents'], 8500 - 150);
    customer = ((await api.get('/api/customers'))['customers'] as List).single;
    expect(customer['points'], 2);
  });

  test('reports summarize sales, profit and menu engineering', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {});
    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    for (var i = 0; i < 2; i++) {
      final checkId = (await api.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
      final r = await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['cake'], 'qty': 1},
        ],
      });
      await api.post('/api/checks/$checkId/payments', {'methodId': cash, 'amountCents': r['check']['totalCents'], 'close': true});
    }
    await api.post('/api/register/moves', {'type': 'expense', 'amountCents': 2000, 'category': 'نضافة'});
    final s = await api.get('/api/reports/summary');
    expect(s['checks'], 2);
    expect(s['totalCents'], 17000);
    expect(s['costCents'], 6000);
    expect(s['grossProfitCents'], 11000);
    expect(s['expensesCents'], 2000);
    expect(s['netCents'], 9000);
    expect((s['items'] as List).single['qty'], 2);
    expect((s['byMethod'] as List).single['amountCents'], 17000);
  });

  test('waiter can take orders but cannot take payments or change the menu', () async {
    final m = await buildMenu();
    await api.post('/api/users', {'name': 'كريم', 'username': 'karim', 'password': 'karim123', 'role': 'waiter'});
    final waiter = ApiClient('http://127.0.0.1:${server.port}');
    waiter.token = (await waiter.post('/api/auth/login', {'username': 'karim', 'password': 'karim123'}))['token'] as String;
    await api.post('/api/tables', {'name': '1'});
    final t = (await waiter.get('/api/floor'))['tables'] as List;
    final checkId = (await waiter.post('/api/checks', {'type': 'dine_in', 'tableId': t.single['id']}))['check']['id'] as String;
    final res = await waiter.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['cake'], 'qty': 1},
      ],
    });
    expect(server.db.selectOne('SELECT source FROM orders WHERE id = ?', [res['orderId']])!['source'], 'waiter');
    await expectApiError(waiter.post('/api/checks/$checkId/close'), 403);
    await expectApiError(waiter.post('/api/items', {'name': 'x'}), 403);
    await expectApiError(waiter.patch('/api/checks/$checkId', {'discountCents': 100}), 403);
    waiter.close();
  });

  test('QR orders need name and phone; they show on the order and register the customer', () async {
    final m = await buildMenu();
    await api.post('/api/register/open', {});
    await api.post('/api/tables', {'name': '8'});
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '8'")!['qr_key'] as String;
    Map<String, dynamic> msg(Map<String, Object?> extra) => {
          't': 'order',
          'k': key,
          'c': 'phone-contact',
          'at': DateTime.now().millisecondsSinceEpoch,
          'j': jsonEncode({
            ...extra,
            'items': [
              {'i': m['cake'], 'q': 1},
            ],
          }),
        };
    server.ingestCloudMessage('n1', msg({'name': 'علا'}));
    expect(server.db.selectOne("SELECT reject_reason FROM orders WHERE cloud_id = 'n1'")!['reject_reason'], contains('موبايلك'));

    server.ingestCloudMessage('n2', msg({'name': 'علا', 'phone': '+20 101 234 5678'}));
    final pending = ((await api.get('/api/orders'))['orders'] as List).single;
    expect(pending['guestName'], 'علا');
    expect(pending['guestPhone'], '+201012345678');
    expect(pending['tableName'], '8');
    final c = await api.get('/api/checks/${pending['checkId']}');
    expect(c['check']['customerPhone'], '+201012345678');
    expect(c['customer']['name'], 'علا');

    // الكافيه يقدر يخليهم اختياري
    await api.patch('/api/shop', {
      'settings': {'qrRequireContact': false},
    });
    server.ingestCloudMessage('n3', msg({}));
    expect(server.db.selectOne("SELECT status FROM orders WHERE cloud_id = 'n3'")!['status'], 'pending');

    // التيكت المطبوع فيه الاسم والموبايل
    await api.post('/api/orders/${pending['id']}/accept');
    final ticket = jsonDecode(server.db.selectOne("SELECT payload FROM print_jobs WHERE kind = 'ticket' AND ref_id = ?", [pending['id']])!['payload'] as String);
    expect(ticket['customerName'], 'علا');
    expect(ticket['customerPhone'], '+201012345678');
    expect(ticket['tableName'], '8');
  });

  test('receiving stock adds the new quantity on top of what is there', () async {
    final cups = await api.post('/api/ingredients', {'name': 'أكواب', 'unit': 'pcs', 'qty': 4, 'unitCost': 100});
    final res = await api.post('/api/ingredients/${cups['id']}/adjust', {'reason': 'receive', 'qty': 6, 'costCents': 900});
    expect(res['qty'], 10);
    final ing = server.db.selectOne('SELECT * FROM ingredients WHERE id = ?', [cups['id']])!;
    expect(ing['qty'], 10);
    // (4 × 1 جنيه + 9 جنيه) ÷ 10 = 1.3 جنيه للكوباية
    expect((ing['unit_cost'] as num).toDouble(), closeTo(130, 0.001));
    final moves = (await api.get('/api/ingredients/${cups['id']}/moves'))['moves'] as List;
    expect(moves.first['reason'], 'receive');
    expect(moves.first['change'], 6);
    await expectApiError(api.post('/api/ingredients/${cups['id']}/adjust', {'reason': 'receive', 'qty': 0}), 400);
  });

  test('backup (written in the background) restores the data and photos', () async {
    final m = await buildMenu();
    final png = img.encodePng(img.Image(width: 900, height: 600));
    await api.put('/api/items/${m['latte']}/image', {'base64': base64.encode(png)});
    final b = await api.post('/api/backups');
    final name = ((b['backups'] as List).first as Map)['name'] as String;
    // بعد النسخة: صنف اتمسح بالغلط
    await api.patch('/api/items/${m['cake']}', {'active': false});
    await api.post('/api/backups/restore', {'name': name});
    await server.stop();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/auth/login', {'username': 'owner', 'password': 'owner123'}))['token'] as String;
    final items = (await api.get('/api/menu'))['items'] as List;
    expect(items.any((i) => i['id'] == m['cake']), true);
    final latte = items.firstWhere((i) => i['id'] == m['latte']);
    expect(File('${dir.path}/files/${latte['imageId']}').existsSync(), true);
  });
}
