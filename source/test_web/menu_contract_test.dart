import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// الطرف التاني لاختبار منيو العميل (Playwright):
/// 1) سيرفر حقيقي على فولدر مؤقت بيعمل كافيه ومنيو، وبيكتب fixture.json بنفس شكل البيانات اللي على Firebase.
/// 2) Playwright بيفتح menu.html على 3 متصفحات، والطلبات اللي الصفحة بتبعتها بتتسجل في captured/.
/// 3) السيرفر بياخد الرسايل دي زي ما هي (كأنها جاية من Firebase) ويتأكد إن الطلبات والدفعات اتسجلت صح.
///
/// WEB_OUT = الفولدر المشترك. بيستنى ملف WEB_OUT/done (بيتعمل بعد ما Playwright يخلص).
void main() {
  test('menu page ⇄ real server contract', () async {
    final out = Directory(Platform.environment['WEB_OUT']!)..createSync(recursive: true);
    final dir = await Directory.systemTemp.createTemp('orderly_web');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    final api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه المتصفح', 'ownerName': 'تيست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;

    var menu = await api.get('/api/menu');
    final bar = ((menu['stations'] as List).first as Map)['id'];
    await api.post('/api/categories', {'name': 'مشروبات', 'nameEn': 'Drinks', 'stationId': bar});
    await api.post('/api/categories', {'name': 'حلويات', 'nameEn': 'Sweets', 'stationId': bar});
    menu = await api.get('/api/menu');
    String cat(String n) => ((menu['categories'] as List).firstWhere((c) => c['name'] == n) as Map)['id'] as String;
    final size = await api.post('/api/modifier-groups', {
      'name': 'الحجم', 'nameEn': 'Size', 'minSelect': 1, 'maxSelect': 1,
      'options': [
        {'name': 'وسط', 'nameEn': 'Medium', 'priceCents': 0},
        {'name': 'كبير', 'nameEn': 'Large', 'priceCents': 1500},
      ],
    });
    final extras = await api.post('/api/modifier-groups', {
      'name': 'إضافات', 'minSelect': 0, 'maxSelect': 2,
      'options': [
        {'name': 'شوت', 'priceCents': 1000},
        {'name': 'شوفان', 'priceCents': 1200},
      ],
    });
    await api.post('/api/items', {'categoryId': cat('مشروبات'), 'name': 'لاتيه', 'nameEn': 'Latte', 'priceCents': 6000, 'groupIds': [size['id'], extras['id']]});
    await api.post('/api/items', {'categoryId': cat('حلويات'), 'name': 'تشيز كيك', 'nameEn': 'Cheesecake', 'priceCents': 8500});
    // اسم صنف فيه HTML: الصفحة لازم تعرضه كنص بس
    await api.post('/api/items', {'categoryId': cat('حلويات'), 'name': '<img src=x onerror="window.__xss=1">كوكيز', 'priceCents': 3000});
    await api.post('/api/pay-methods', {'name': 'فودافون كاش', 'kind': 'wallet', 'account': '01000000000'});
    await api.post('/api/tables/bulk', {'from': 1, 'to': 3});
    await api.post('/api/register/open', {'openingCashCents': 0});

    // نفس شكل البيانات اللي CloudSync بيكتبها على Firebase (cafes/{uid}/pub, menu, tables)
    final m = await api.get('/api/menu');
    final pays = ((await api.get('/api/pay-methods'))['methods'] as List).cast<Map<String, dynamic>>().where((x) => x['showInQr'] == true);
    final shop = await api.get('/api/shop');
    final s = shop['settings'] as Map;
    final keys = {for (final t in server.db.select('SELECT qr_key, name FROM tables')) t['qr_key'] as String: {'n': t['name'], 'a': 'الصالة'}};
    keys[server.takeawayKey] = {'n': 'تيك أواي', 'tk': true};
    final fixture = {
      'cafe': 'cafe-under-test',
      'tableKey': server.db.selectOne("SELECT qr_key FROM tables WHERE name = '1'")!['qr_key'],
      'takeawayKey': server.takeawayKey,
      'pub': {
        'name': shop['name'], 'welcome': s['qrWelcome'], 'langs': s['menuLanguages'], 'open': true, 'contact': s['qrRequireContact'] != false,
        'svc': s['serviceBp'], 'tax': s['taxBp'], 'svcTk': s['serviceOnTakeaway'],
        'pay': pays.map((x) => {'id': x['id'], 'n': x['name'], 'k': x['kind'], 'acc': x['account'], 'link': x['link'], 'ins': x['instructions'], 'proof': x['needsProof']}).toList(),
      },
      'menu': {
        'v': 'v1',
        'cats': (m['categories'] as List).map((c) => {'id': c['id'], 'n': c['name'], 'ne': c['nameEn'], 'h': c['hours']}).toList(),
        'items': (m['items'] as List).where((i) => i['showInQr'] == true).map((i) => {
              'id': i['id'], 'c': i['categoryId'], 'n': i['name'], 'ne': i['nameEn'], 'p': i['priceCents'], 'pp': i['promoPriceCents'],
              'g': (i['groupIds'] as List).isEmpty ? null : i['groupIds'],
            }).toList(),
        'groups': (m['modifierGroups'] as List).map((g) => {
              'id': g['id'], 'n': g['name'], 'ne': g['nameEn'], 'min': g['minSelect'], 'max': g['maxSelect'],
              'o': (g['options'] as List).map((o) => {'id': o['id'], 'n': o['name'], 'ne': o['nameEn'], 'p': o['priceCents'], 'def': o['isDefault']}).toList(),
            }).toList(),
      },
      'tables': keys,
    };
    File('${out.path}/fixture.json').writeAsStringSync(jsonEncode(fixture));

    final done = File('${out.path}/done');
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (!done.existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('Playwright never finished');
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    // الرسايل اللي الصفحة بعتتها، بالترتيب
    final captured = Directory('${out.path}/captured').existsSync()
        ? (Directory('${out.path}/captured').listSync().whereType<File>().map((f) => jsonDecode(f.readAsStringSync()) as Map<String, dynamic>).toList())
        : <Map<String, dynamic>>[];
    final results = <Map<String, Object?>>[];
    for (final c in captured) {
      final msg = (c['inbox'] as Map).cast<String, dynamic>();
      msg['at'] = DateTime.now().millisecondsSinceEpoch; // Firebase بيحط {'.sv': 'timestamp'} = وقت الوصول
      final proofUrl = (c['proof'] as Map?)?['d'] as String?;
      final proof = proofUrl == null ? null : base64.decode(proofUrl.substring(proofUrl.indexOf(',') + 1));
      server.ingestCloudMessage(c['id'] as String, msg, proof);
      final body = jsonDecode(msg['j'] as String) as Map;
      final order = server.db.selectOne('SELECT * FROM orders WHERE cloud_id = ?', [c['id']]);
      final items = order == null ? const [] : server.db.select('SELECT qty, unit_price_cents FROM order_items WHERE order_id = ?', [order['id']]);
      final serverTotal = items.fold<int>(0, (s, i) => s + (i['qty'] as int) * (i['unit_price_cents'] as int));
      final pay = server.db.selectOne('SELECT * FROM payments WHERE cloud_id = ?', [c['id']]);
      final pageTotal = (body['pay'] as Map?)?['a'];
      final ok = order != null &&
          order['status'] == 'pending' &&
          (pageTotal == null || pageTotal == serverTotal) &&
          (proof == null || (pay != null && pay['proof_file'] != null && pay['status'] == 'pending'));
      results.add({
        'test': c['test'],
        'browser': c['browser'],
        'status': ok ? 'PASS' : 'FAIL',
        'orderStatus': order?['status'],
        'rejectReason': order?['reject_reason'],
        'pageTotalCents': pageTotal,
        'serverTotalCents': serverTotal,
        'proofKB': proof == null ? null : proof.length ~/ 1024,
        'paymentStatus': pay?['status'],
        'proofStored': pay?['proof_file'] != null,
      });
    }
    File('${out.path}/contract_results.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
    expect(captured, isNotEmpty, reason: 'the page sent no orders');
    expect(results.where((r) => r['status'] != 'PASS'), isEmpty, reason: const JsonEncoder.withIndent('  ').convert(results));
  }, timeout: Timeout.none);
}
