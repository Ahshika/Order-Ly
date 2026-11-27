// المزامنة مع Firebase (على Firebase وهمي): اللي بيتكتب وشكله، والمسح، والكتابة من غير ما ترجع.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/passwords.dart';
import 'package:orderly/src/server/api_server.dart';

import 'support/fake_firebase.dart';

void main() {
  late Directory dir;
  late FakeFirebase fb;
  late OrderlyServer server;
  late ApiClient api;
  late String uid;
  late String itemId;
  late List<String> keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_sync');
    fb = FakeFirebase();
    await fb.start();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, firebase: fb.endpoints);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    final logo = img.Image(width: 400, height: 400);
    img.fill(logo, color: img.ColorRgb8(15, 118, 110));
    await api.put('/api/shop/logo', {'png': base64.encode(img.encodePng(logo))});
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    itemId = (await api.post('/api/items', {'categoryId': cat, 'name': 'لاتيه', 'priceCents': 6000}))['id'] as String;
    final photo = img.Image(width: 1200, height: 900);
    img.fill(photo, color: img.ColorRgb8(200, 120, 60));
    await api.put('/api/items/$itemId/image', {'base64': base64.encode(img.encodeJpg(photo))});
    await api.post('/api/tables/bulk', {'from': 1, 'to': 2});
    await api.post('/api/register/open', {'openingCashCents': 0});
    await server.syncNow();
    uid = server.db.setting('cloud_uid')!;
    keys = [for (final t in server.db.select('SELECT qr_key FROM tables WHERE active = 1 ORDER BY name')) t['qr_key'] as String];
  });

  tearDown(() async {
    api.close();
    await server.stop();
    await fb.stop();
    await dir.delete(recursive: true);
  });

  Future<T> waitFor<T>(T? Function() f) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final v = f();
      if (v != null) return v;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('timeout');
  }

  Future<Map<String, Object?>> order(String id, String client, String key) async {
    fb.write('inbox/$uid/$id', {
      't': 'order',
      'k': key,
      'c': client,
      'at': DateTime.now().millisecondsSinceEpoch,
      'j': jsonEncode({'name': 'سلمى', 'phone': '01012345678', 'items': [{'i': itemId, 'q': 2, 'm': []}]}),
    });
    final o = await waitFor(() => server.db.selectOne('SELECT * FROM orders WHERE cloud_id = ?', [id]));
    await api.post('/api/orders/${o['id']}/accept');
    await server.syncNow();
    return o;
  }

  test('every write is silent (Firebase does not send the data back) and sync reports no error', () async {
    fb.resetUsage();
    await order('o1', 'client-aaaaaaaaaa', keys.first);
    final writes = fb.requests.where((r) => r.method != 'GET').toList();
    expect(writes, isNotEmpty);
    expect(writes.every((r) => r.silent), isTrue, reason: writes.where((r) => !r.silent).map((r) => '${r.method} ${r.path}').join(', '));
    expect(writes.fold<int>(0, (s, r) => s + r.bytes), 0);
    expect(server.cloudError, anyOf(isNull, isEmpty));
    expect(fb.get('inbox/$uid'), isNull, reason: 'the message is deleted after it is read');
  });

  test('logo lives in its own node; pub only carries its version', () async {
    final pub = fb.get('cafes/$uid/pub') as Map;
    final logo = fb.get('cafes/$uid/logo') as String;
    expect(pub.containsKey('logo'), isFalse);
    expect(pub['lv'], sha256Hex(logo).substring(0, 12));
    expect(utf8.encode(jsonEncode(pub)).length, lessThan(2000));
    await api.delete('/api/shop/logo');
    await server.syncNow();
    expect(fb.get('cafes/$uid/logo'), isNull);
    expect((fb.get('cafes/$uid/pub') as Map).containsKey('lv'), isFalse);
  });

  test('item photos are sent at 240 px, and re-sent once when an older version had sent them bigger', () async {
    final id = (fb.get('img/$uid') as Map).keys.single as String;
    var thumb = img.decodeJpg(Uint8List.fromList(base64.decode(fb.get('img/$uid/$id') as String)))!;
    expect(thumb.width, 240);
    // كأن نسخة قديمة بعتت الصور قبل كده (مفيش cloud_img_size)
    fb.write('img/$uid/$id', 'old');
    server.db.setSetting('cloud_img_size', '');
    await api.patch('/api/items/$itemId', {'priceCents': 6500}); // أي تعديل في المنيو
    await server.syncNow();
    thumb = img.decodeJpg(Uint8List.fromList(base64.decode(fb.get('img/$uid/$id') as String)))!;
    expect(thumb.width, 240);
  });

  test('customer tracking v2 carries the table bill (one stream on the phone), and old tracking is deleted after 3 hours', () async {
    await order('o1', 'client-aaaaaaaaaa', keys.first);
    final doc = fb.get('trackc/$uid/client-aaaaaaaaaa') as Map;
    expect(doc['v'], 2);
    final tb = doc['tb'] as Map;
    expect(tb['k'], keys.first);
    expect(tb['total'], 12000);
    expect((tb['items'] as List).single['n'], 'لاتيه');
    expect(fb.get('trackt/$uid/${keys.first}'), isNotNull, reason: 'trackt stays for phones that have not ordered and old pages');

    // عميل تاني على ترابيزة تانية لسه شغال، والأول آخر طلب ليه من 4 ساعات
    await order('o2', 'client-bbbbbbbbbb', keys.last);
    final old = DateTime.now().toUtc().subtract(const Duration(hours: 4)).toIso8601String();
    server.db.execute("UPDATE orders SET created_at = ? WHERE client_id = 'client-aaaaaaaaaa'", [old]);
    await server.syncNow();
    expect(fb.get('trackc/$uid/client-aaaaaaaaaa'), isNull);
    expect(fb.get('trackc/$uid/client-bbbbbbbbbb'), isNotNull);
  });

  test('account deleted from Firebase: a new one is made by itself, everything re-sent, owner told to reprint QR', () async {
    final before = (await api.get('/api/tables/qr'))['tables'] as List;
    expect((before.first as Map)['url'], contains('/m/$uid/'));
    fb.deleteUser(uid);
    fb.root.clear(); // ومعاه بياناته
    server.db.setSetting('cloud_last_error', '');
    // التوكن الحالي لسه صالح ساعة: بنخلّي السيرفر يجدده زي ما هيحصل بعد ساعة
    server.expireCloudTokenForTests();
    await server.syncNow();
    final newUid = server.db.setting('cloud_uid')!;
    expect(newUid, isNot(uid));
    expect(fb.get('cafes/$newUid/pub'), isNotNull);
    expect(fb.get('cafes/$newUid/menu'), isNotNull);
    expect(fb.get('img/$newUid'), isNotNull);
    final qr = await api.get('/api/tables/qr');
    expect(((qr['tables'] as List).first as Map)['url'], contains('/m/$newUid/'));
    expect(qr['reprintSince'], isNotNull);
  });

  test('shop moved to another Firebase project: new account there, branch link dropped', () async {
    server.db.setSetting('chain_role', 'member');
    server.db.setSetting('chain_id', 'ABCDEFGHJKLM');
    // كأن المحل كان على مشروع تاني قبل كده
    server.db.setSetting('cloud_db', 'https://old-shop-default-rtdb.europe-west1.firebasedatabase.app');
    await server.syncNow();
    expect(server.db.setting('cloud_uid'), isNot(uid));
    expect(server.db.setting('cloud_db'), fb.endpoints.rtdb);
    expect(server.db.setting('chain_role'), isEmpty);
  });

  test('QR links carry the shop database when it is not the main project', () async {
    final qr = await api.get('/api/tables/qr');
    // الوهمي مش المشروع الأساسي، فاللينك فيه ?d=
    expect(((qr['tables'] as List).first as Map)['url'], endsWith('?d=127.0.0.1'));
  });

  test('reports refused by the rules do not stop the menu and order tracking', () async {
    fb.rejectWrite = (path) => path.startsWith('rep/');
    await order('r1', 'client-dddddddddd', keys.first);
    expect(fb.get('trackc/$uid/client-dddddddddd'), isNotNull);
    expect(server.cloudError, anyOf(isNull, isEmpty));
    expect(server.db.setting('report_last_error'), contains('401'));
    // القواعد اتصلحت: التقارير بتتبعت في الدورة الجاية
    fb.rejectWrite = null;
    await server.syncNow();
    expect(fb.get('rep/$uid'), isNotNull);
    expect(server.db.setting('report_last_error'), isEmpty);
  });

  test('a write that failed (internet dropped) is sent again on the next sync', () async {
    final o = await order('n1', 'client-eeeeeeeeee', keys.first);
    fb.failWrites = 10; // النت قطع
    await api.post('/api/orders/${o['id']}/served');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(((fb.get('trackc/$uid/client-eeeeeeeeee') as Map)['orders'] as Map).values.single['s'], 'accepted');
    fb.failWrites = 0; // النت رجع
    await server.cloudTickForTests(); // الدورة العادية كل دقيقة (مش runNow اللي بيبعت كل حاجة من الأول)
    expect(((fb.get('trackc/$uid/client-eeeeeeeeee') as Map)['orders'] as Map).values.single['s'], 'served');
  });

  test('takeaway customer: no table bill in the tracking', () async {
    await order('t1', 'client-cccccccccc', server.takeawayKey);
    final doc = fb.get('trackc/$uid/client-cccccccccc') as Map;
    expect(doc['v'], 2);
    expect(doc.containsKey('tb'), isFalse);
    expect(((doc['orders'] as Map).values.single as Map)['bill'], isNotNull);
  });
}
