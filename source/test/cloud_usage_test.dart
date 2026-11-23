// استهلاك Firebase (التنزيل اللي بيتحاسب عليه) لكافيه بيشتغل: Firebase وهمي على الجهاز بيعدّ كل بايت.
// النتيجة بتتكتب في test-results/firebase-usage/<USAGE_LABEL>.json (لو USAGE_LABEL متحدد) عشان نقارن قبل وبعد أي تعديل.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

import 'support/fake_firebase.dart';

/// صورة شبه صورة أكل حقيقية: ألوان متدرجة وشوية تفاصيل (مش ضوضاء كاملة ولا لون واحد).
List<int> _photo(int seed, {int w = 900, int h = 700}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = sqrt(pow(x - w / 2, 2) + pow(y - h / 2, 2)) / w;
      im.setPixelRgb(x, y, (180 - d * 140 + r.nextInt(18)).clamp(0, 255).toInt(), (120 - d * 60 + (x ~/ 40 % 2) * 12 + r.nextInt(18)).clamp(0, 255).toInt(),
          (70 + d * 50 + r.nextInt(18)).clamp(0, 255).toInt());
    }
  }
  return img.encodeJpg(im, quality: 90);
}

void main() {
  late Directory dir;
  late FakeFirebase fb;
  late OrderlyServer server;
  late ApiClient api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_usage');
    fb = FakeFirebase();
    await fb.start();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, firebase: fb.endpoints);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه القياس', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
  });

  tearDown(() async {
    api.close();
    await server.stop();
    await fb.stop();
    await dir.delete(recursive: true);
  });

  Future<T> waitFor<T>(T? Function() f, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final v = f();
      if (v != null) return v;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('timeout');
  }

  test('Firebase download for a working cafe: setup, 20 QR orders, the customer page', () async {
    // ---------------------------------------------------------------- كافيه فيه لوجو و12 صنف بصور و6 ترابيزات
    final logo = img.encodePng(img.copyResize(img.decodeJpg(Uint8List.fromList(_photo(99, w: 600, h: 600)))!, width: 512));
    await api.put('/api/shop/logo', {'png': base64.encode(logo)});
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    final items = <String>[];
    for (var i = 0; i < 12; i++) {
      final it = await api.post('/api/items', {'categoryId': cat, 'name': 'صنف $i', 'priceCents': 3000 + i * 500});
      items.add(it['id'] as String);
      await api.put('/api/items/${it['id']}/image', {'base64': base64.encode(_photo(i))});
    }
    await api.post('/api/tables/bulk', {'from': 1, 'to': 6});
    await api.post('/api/register/open', {'openingCashCents': 0});
    final methods = ((await api.get('/api/pay-methods'))['methods'] as List).cast<Map<String, dynamic>>();
    final cash = methods.firstWhere((m) => m['kind'] == 'cash')['id'];

    fb.resetUsage();
    await server.syncNow();
    await server.syncNow(); // باقي الصور (15 في الدورة)
    final uid = server.db.setting('cloud_uid')!;
    expect(server.cloudError, anyOf(isNull, isEmpty));
    final setup = fb.usage();

    // ---------------------------------------------------------------- 20 طلب QR من 6 ترابيزات، كل واحد يتقبل ويتقدم ويتدفع
    final keys = [for (final t in server.db.select("SELECT qr_key FROM tables WHERE active = 1 ORDER BY name")) t['qr_key'] as String];
    fb.resetUsage();
    for (var n = 0; n < 20; n++) {
      final id = 'ord${n.toString().padLeft(3, '0')}';
      fb.write('inbox/$uid/$id', {
        't': 'order',
        'k': keys[n % keys.length],
        'c': 'client-${n.toString().padLeft(8, '0')}',
        'at': DateTime.now().millisecondsSinceEpoch,
        'j': jsonEncode({'name': 'عميل $n', 'phone': '0100000${n.toString().padLeft(4, '0')}', 'items': [{'i': items[n % 12], 'q': 1 + n % 2, 'm': []}]}),
      });
      final order = await waitFor(() => server.db.selectOne('SELECT id, check_id FROM orders WHERE cloud_id = ?', [id]));
      await api.post('/api/orders/${order['id']}/accept');
      await api.post('/api/orders/${order['id']}/served');
      if (n % 3 == 2) {
        // كل 3 طلبات ترابيزة بتدفع وتقوم
        final c = await api.get('/api/checks/${order['check_id']}');
        final due = (c['check'] as Map)['totalCents'] as int;
        await api.post('/api/checks/${order['check_id']}/payments', {'methodId': cash, 'amountCents': due, 'close': true});
      }
    }
    await server.syncNow();
    await Future<void>.delayed(const Duration(seconds: 2));
    final orders = fb.usage();
    final cashierPerOrder = orders.bytes / 20;

    // ---------------------------------------------------------------- صفحة العميل: أحجام اللي بتنزله
    final pub = fb.sizeOf('cafes/$uid/pub');
    final logoNode = fb.get('cafes/$uid/logo') == null ? 0 : fb.sizeOf('cafes/$uid/logo');
    final menu = fb.sizeOf('cafes/$uid/menu');
    final imgs = (fb.get('img/$uid') as Map? ?? {}).values.map((v) => utf8.encode(jsonEncode(v)).length).toList();
    final avgImg = imgs.isEmpty ? 0 : imgs.reduce((a, b) => a + b) ~/ imgs.length;
    final trackc = (fb.get('trackc/$uid') as Map? ?? {}).values.map((v) => utf8.encode(jsonEncode(v)).length).toList();
    final avgTrackc = trackc.isEmpty ? 0 : trackc.reduce((a, b) => a + b) ~/ trackc.length;
    final trackt = (fb.get('trackt/$uid') as Map? ?? {}).values.map((v) => utf8.encode(jsonEncode(v)).length).toList();
    final avgTrackt = trackt.isEmpty ? 0 : trackt.reduce((a, b) => a + b) ~/ trackt.length;
    final pubHasLogo = (fb.get('cafes/$uid/pub') as Map).containsKey('logo');

    // عميل جديد، 10 دقايق قدام الشاشة، بيشوف 30 صورة (بنفس متوسط الصور هنا)، و5 تحديثات لحالة طلبه
    const minutes = 10, photos = 30, trackUpdates = 5;
    final newVisit = pub + logoNode + menu + photos * avgImg + minutes * pub + trackUpdates * (avgTrackc + (pubHasLogo ? avgTrackt : 0));
    final returningVisit = pub + minutes * pub + trackUpdates * (avgTrackc + (pubHasLogo ? avgTrackt : 0));

    final report = {
      'label': Platform.environment['USAGE_LABEL'] ?? 'run',
      'at': DateTime.now().toIso8601String(),
      'cashier': {
        'setupBytes': setup.bytes,
        'setupRequests': setup.requests,
        'ordersBytes': orders.bytes,
        'ordersRequests': orders.requests,
        'bytesPerOrder': cashierPerOrder.round(),
        'echoBytes': fb.requests.where((r) => r.method != 'GET').fold<int>(0, (s, r) => s + r.bytes),
      },
      'nodes': {'pub': pub, 'pubHasLogo': pubHasLogo, 'logo': logoNode, 'menu': menu, 'images': imgs.length, 'avgImage': avgImg, 'avgTrackc': avgTrackc, 'avgTrackt': avgTrackt},
      'customer': {'newVisitBytes': newVisit, 'returningVisitBytes': returningVisit, 'avgVisitBytes': (newVisit + returningVisit) ~/ 2},
      'trackcDocs': trackc.length,
    };
    // الملف بيتكتب بس لما نطلب قياس (USAGE_LABEL)، عشان التشغيل العادي مايسيبش ملفات
    if (Platform.environment['USAGE_LABEL'] != null) {
      final out = Directory('../test-results/firebase-usage')..createSync(recursive: true);
      File('${out.path}/${report['label']}.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    }
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(report));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
