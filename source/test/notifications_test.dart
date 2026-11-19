import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// الإشعارات اللي السيرفر بيبعتها للموبايلات والكمبيوتر: كل حدث بيطلع مرة واحدة، في الوقت الصح، للناس الصح.
void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;
  late WebSocket ws;
  final events = <Map<String, dynamic>>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_notify');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'ك', 'ownerName': 'أ', 'username': 'owner', 'password': 'owner123', 'deviceId': 'owner-device'}))['token'] as String;
    events.clear();
    ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}');
    ws.listen((m) {
      final d = jsonDecode(m as String) as Map<String, dynamic>;
      if (d['type'] == 'notify') events.add(d);
    });
  });

  tearDown(() async {
    await ws.close();
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final out = [...events];
    events.clear();
    return out;
  }

  Future<Map<String, String>> setupCafe() async {
    var m = await api.get('/api/menu');
    final bar = ((m['stations'] as List).first as Map)['id'] as String;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': bar});
    m = await api.get('/api/menu');
    final cat = ((m['categories'] as List).first as Map)['id'] as String;
    final coffee = (await api.post('/api/items', {'categoryId': cat, 'name': 'قهوة', 'priceCents': 5000}))['id'] as String;
    await api.post('/api/tables/bulk', {'from': 1, 'to': 3});
    await api.post('/api/register/open', {'openingCashCents': 0});
    await api.post('/api/pay-methods', {'name': 'InstaPay', 'kind': 'instapay', 'account': 'cafe@instapay'});
    final ipay = (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'instapay') as Map)['id'] as String;
    await settle();
    return {'bar': bar, 'coffee': coffee, 'ipay': ipay};
  }

  String key(String table) => server.db.selectOne('SELECT qr_key FROM tables WHERE name = ?', [table])!['qr_key'] as String;

  Map<String, dynamic> qr(String type, String table, String client, Map<String, Object?> body) =>
      {'t': type, 'k': key(table), 'c': client, 'at': DateTime.now().millisecondsSinceEpoch, 'j': jsonEncode(body)};

  test('QR order: floor staff get "new order"; a transfer screenshot alerts the cashiers', () async {
    final m = await setupCafe();
    server.ingestCloudMessage('n-1', qr('order', '1', 'phone-notify-1', {
      'name': 'سلمى',
      'phone': '01012345678',
      'items': [
        {'i': m['coffee'], 'q': 2},
      ],
      'pay': {'m': m['ipay']},
    }), img.encodePng(img.Image(width: 20, height: 20)));
    final got = await settle();
    final order = got.singleWhere((e) => e['kind'] == 'order_new');
    expect(order['title'], 'طلب جديد من موبايل عميل');
    expect(order['body'], allOf(contains('ترابيزة 1'), contains('2 صنف'), contains('مستني موافقتك')));
    expect((order['roles'] as List).toSet(), {'owner', 'supervisor', 'cashier', 'waiter'});
    expect(order['goTo'], 'orders');
    final pay = got.singleWhere((e) => e['kind'] == 'payment');
    expect((pay['roles'] as List).toSet(), {'owner', 'supervisor', 'cashier'}, reason: 'waiters and kitchen do not handle transfers');
    expect(got.where((e) => e['kind'] == 'kitchen_new'), isEmpty, reason: 'not accepted yet, the kitchen must not start');

    // الكاشير قبل الطلب: المطبخ ياخد إشعار
    final orderId = server.db.selectOne("SELECT id FROM orders WHERE cloud_id = 'n-1'")!['id'];
    await api.post('/api/orders/$orderId/accept');
    final kitchen = (await settle()).singleWhere((e) => e['kind'] == 'kitchen_new');
    expect(kitchen['roles'], ['kitchen']);
    expect(kitchen['body'], contains('ترابيزة 1'));
  });

  test('staff order → kitchen; all items ready → waiters; second "ready" does not repeat', () async {
    final m = await setupCafe();
    final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == '2');
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'];
    final r = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['coffee'], 'qty': 1},
      ],
    });
    expect((await settle()).map((e) => e['kind']), ['kitchen_new']);
    await api.post('/api/orders/${r['orderId']}/ready');
    final ready = (await settle()).single;
    expect(ready['kind'], 'order_ready');
    expect(ready['title'], contains('جاهز'));
    expect((ready['roles'] as List), isNot(contains('kitchen')));
    await api.post('/api/orders/${r['orderId']}/ready');
    expect(await settle(), isEmpty, reason: 'already ready: no second notification');
  });

  test('waiter call, bill request and cash payment from the table', () async {
    final m = await setupCafe();
    server.ingestCloudMessage('c-1', qr('call', '3', 'phone-notify-3', {'kind': 'waiter'}));
    var got = await settle();
    expect(got.single['kind'], 'table_call');
    expect(got.single['title'], 'ترابيزة 3 بتنادي الويتر');
    // نداء مكرر لسه مفتوح: مفيش إشعار تاني
    server.ingestCloudMessage('c-2', qr('call', '3', 'phone-notify-3', {'kind': 'waiter'}));
    expect(await settle(), isEmpty);
    server.ingestCloudMessage('c-3', qr('call', '3', 'phone-notify-3', {'kind': 'bill'}));
    expect((await settle()).single['title'], 'ترابيزة 3 عايزة الحساب');
    final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == '3');
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'];
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['coffee'], 'qty': 1},
      ],
    });
    await settle();
    final cash = (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash') as Map)['id'];
    server.ingestCloudMessage('p-1', qr('pay', '3', 'phone-notify-3', {'m': cash, 'a': 5000}));
    got = await settle();
    expect(got.single['kind'], 'table_call');
    expect(got.single['title'], contains('كاش'));
  });

  test('a failed print alerts the cashiers', () async {
    final m = await setupCafe();
    final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == '1');
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'];
    await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['coffee'], 'qty': 1},
      ],
    });
    final job = (((await api.get('/api/print/claim', query: {'stations': m['bar']!}))['jobs'] as List).single as Map)['id'];
    await settle();
    await api.post('/api/print/$job/result', {'ok': false, 'error': 'الطابعة مفصولة'});
    final got = (await settle()).single;
    expect(got['kind'], 'problem');
    expect(got['title'], 'الطباعة فشلت في البار');
    expect(got['body'], 'الطابعة مفصولة');
  });

  test('Wi-Fi blip: a phone that reconnects gets what it missed (once), a fresh start does not get old ones', () async {
    final m = await setupCafe();
    // الموبايل متصل وشاف ساعة السيرفر، وبعدين الواي فاي قطع
    final phone = await WebSocket.connect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}');
    final hello = jsonDecode(await phone.first as String) as Map;
    expect(hello['type'], 'hello');
    final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == '1');
    final checkId = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'];
    // في الثواني اللي الموبايل كان فيها مقطوع: طلب اتعمل وبقى جاهز
    final r = await api.post('/api/checks/$checkId/orders', {
      'lines': [
        {'itemId': m['coffee'], 'qty': 1},
      ],
    });
    await api.post('/api/orders/${r['orderId']}/ready');
    await settle();
    Future<List<Map>> collect(String url) async {
      final ws = await WebSocket.connect(url);
      final got = <Map>[];
      final sub = ws.listen((m) => got.add(jsonDecode(m as String) as Map));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      await ws.close();
      return got.where((e) => e['type'] == 'notify').toList();
    }

    final back = await collect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}&since=${Uri.encodeQueryComponent(hello['at'] as String)}');
    expect(back.map((e) => e['kind']), ['kitchen_new', 'order_ready'], reason: 'what happened while it was offline, in order');
    final fresh = await collect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}');
    expect(fresh, isEmpty, reason: 'opening the app must not replay old alerts');
  });

  test('a rejected QR order (cafe closed) does not alert anyone', () async {
    final m = await setupCafe();
    await api.post('/api/register/close', {'countedCashCents': 0});
    await settle();
    server.ingestCloudMessage('r-1', qr('order', '1', 'phone-notify-r', {
      'name': 'سلمى',
      'phone': '01012345678',
      'items': [
        {'i': m['coffee'], 'q': 1},
      ],
    }));
    expect(await settle(), isEmpty);
  });
}
