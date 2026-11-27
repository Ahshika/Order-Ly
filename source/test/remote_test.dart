// التحكم من بعيد (أوامر المالك) على Firebase وهمي: مقفول افتراضياً، القايمة الثابتة بس، والسجل.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

import 'support/fake_firebase.dart';

void main() {
  late Directory dir;
  late FakeFirebase fb;
  late OrderlyServer server;
  late ApiClient api;
  late String uid;
  late String itemId;
  var n = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_remote');
    fb = FakeFirebase();
    await fb.start();
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, firebase: fb.endpoints);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    itemId = (await api.post('/api/items', {'categoryId': cat, 'name': 'لاتيه', 'priceCents': 6000}))['id'] as String;
    await server.syncNow();
    uid = server.db.setting('cloud_uid')!;
    await Future<void>.delayed(const Duration(seconds: 3)); // أول تشغيل للمزامنة (بعد ثانيتين) يخلص
  });

  tearDown(() async {
    api.close();
    await server.stop();
    await fb.stop();
    await dir.delete(recursive: true);
  });

  /// المالك بيكتب أمر، وبيستنى رد الكمبيوتر.
  Future<(bool, Object?)> command(String op, [Map<String, Object?> args = const {}, int? at]) async {
    final id = 'c${n++}';
    fb.write('cmd/$uid/$id', {'op': op, 'a': jsonEncode(args), 'at': at ?? DateTime.now().millisecondsSinceEpoch, 'by': 'ownerA'});
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      final r = fb.get('cmdr/$uid/$id');
      if (r is Map) {
        expect(fb.get('cmd/$uid/$id'), isNull, reason: 'the command is deleted after it runs');
        expect(r['by'], 'ownerA');
        return (r['ok'] as bool, jsonDecode(r['r'] as String));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('no reply for $op');
  }

  test('off by default: nothing is listened to', () async {
    expect((await api.get('/api/owner'))['remote'], isFalse);
    fb.write('cmd/$uid/x', {'op': 'menu.get', 'a': '{}', 'at': DateTime.now().millisecondsSinceEpoch, 'by': 'ownerA'});
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(fb.get('cmdr/$uid/x'), isNull);
  });

  test('the five commands work, are logged as from the owner app, and turning it off stops them', () async {
    await api.post('/api/owner/remote', {'on': true});
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final (ok1, menu) = await command('menu.get');
    expect(ok1, isTrue);
    expect(((menu as Map)['items'] as List).single['p'], 6000);

    expect((await command('item.price', {'id': itemId, 'p': 6500})).$1, isTrue);
    expect(server.db.selectOne('SELECT price_cents FROM items WHERE id = ?', [itemId])!['price_cents'], 6500);

    expect((await command('item.available', {'id': itemId, 'av': false})).$1, isTrue);
    expect(server.db.selectOne('SELECT available FROM items WHERE id = ?', [itemId])!['available'], 0);

    expect(((await command('checks.open')).$2 as Map)['checks'], isEmpty);

    final log = ((await command('audit.recent')).$2 as Map)['log'] as List;
    expect(log.any((l) => '${l['d']}'.contains('من أبلكيشن المالك') && '${l['d']}'.contains('65')), isTrue);

    // غلط: سعر مش صحيح، صنف مش موجود، أمر مش في القايمة، أمر قديم
    expect((await command('item.price', {'id': itemId, 'p': -5})).$1, isFalse);
    expect((await command('item.price', {'id': 'nope', 'p': 5})).$2, contains('مش موجود'));
    expect((await command('users.delete', {'id': 'x'})).$2, contains('مش مسموح'));
    expect((await command('menu.get', {}, DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch)).$2, contains('اتأخر'));

    // اتقفل: الكمبيوتر مابيسمعش خالص (مفيش اتصال مفتوح)، والأمر مالوش رد (أبلكيشن المالك بيقول افتحه من الكمبيوتر)
    await api.post('/api/owner/remote', {'on': false});
    await expectLater(command('menu.get'), throwsStateError);
    final audit = server.db.select("SELECT action FROM audit_log WHERE action LIKE 'remote.%'").map((r) => r['action']).toList();
    expect(audit, containsAll(['remote.on', 'remote.off']));
  });

  test('more than 30 commands a minute are refused', () async {
    await api.post('/api/owner/remote', {'on': true});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    var refused = 0;
    for (var i = 0; i < 33; i++) {
      if (!(await command('checks.open')).$1) refused++;
    }
    expect(refused, 3);
  });
}
