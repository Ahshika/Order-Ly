import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';
import 'package:path/path.dart' as p;

/// مواعيد النسخ الاحتياطي، والرجوع لوحده لو قاعدة البيانات باظت، والصلاحيات، ومنع الطلب المكرر، وحد طلبات الـ QR لكل ترابيزة.
void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;
  late String base;

  Future<void> boot() async {
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    api = ApiClient(base);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_hardening');
    await boot();
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123', 'deviceId': 'owner-device-1'}))['token'] as String;
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

  Future<ApiClient> user(String username, String role, {String? device}) async {
    await api.post('/api/users', {'name': username, 'username': username, 'password': 'pass1234', 'role': role});
    final c = ApiClient(base);
    c.token = (await c.post('/api/auth/login', {'username': username, 'password': 'pass1234', 'deviceId': device ?? 'device-$username'}))['token'] as String;
    return c;
  }

  Future<Map<String, String>> menu() async {
    var m = await api.get('/api/menu');
    final bar = ((m['stations'] as List).first as Map)['id'] as String;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': bar});
    m = await api.get('/api/menu');
    final cat = ((m['categories'] as List).first as Map)['id'] as String;
    final coffee = await api.post('/api/items', {'categoryId': cat, 'name': 'قهوة', 'priceCents': 5000});
    await api.post('/api/tables/bulk', {'from': 1, 'to': 5});
    return {'bar': bar, 'coffee': coffee['id'] as String};
  }

  Future<String> tableCheck(String name) async {
    final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == name);
    return (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t['id']}))['check']['id'] as String;
  }

  List<File> zips() => Directory(p.join(dir.path, 'backups')).listSync().whereType<File>().where((f) => f.path.endsWith('.zip')).toList();

  // ------------------------------------------------------------------ النسخ الاحتياطي

  group('backup schedule', () {
    test('defaults, valid and invalid choices, and the second folder is not wiped by other changes', () async {
      var b = await api.get('/api/backups');
      expect([b['everyHours'], b['keep'], b['onShiftClose']], [24, 14, false]);
      final extra = await Directory.systemTemp.createTemp('orderly_extra');
      await api.patch('/api/backups/settings', {'backupDir': extra.path});
      b = await api.patch('/api/backups/settings', {'everyHours': 6, 'keep': 7, 'onShiftClose': true});
      expect([b['everyHours'], b['keep'], b['onShiftClose']], [6, 7, true]);
      expect(b['backupDir'], extra.path, reason: 'changing the schedule used to clear the second folder');
      for (final bad in [
        {'everyHours': 5},
        {'everyHours': '6'},
        {'keep': 1000},
        {'keep': -1},
        {'onShiftClose': 'yes'},
      ]) {
        await expectStatus(api.patch('/api/backups/settings', bad), 400);
      }
      final waiter = await user('user_w1', 'waiter');
      await expectStatus(waiter.patch('/api/backups/settings', {'everyHours': 1}), 403);
      waiter.close();
      await extra.delete(recursive: true);
    });

    test('keeps exactly the chosen number of backups', () async {
      final folder = Directory(p.join(dir.path, 'backups'))..createSync(recursive: true);
      for (var i = 1; i <= 10; i++) {
        File(p.join(folder.path, 'orderly-2020-01-${i.toString().padLeft(2, '0')}-000000.zip')).writeAsStringSync('old');
      }
      await api.patch('/api/backups/settings', {'keep': 7});
      await api.post('/api/backups');
      expect(zips().length, 7);
      expect(zips().where((f) => p.basename(f.path).startsWith('orderly-2020-01-01')), isEmpty, reason: 'the oldest ones go first');
    });

    test('scheduled check makes a backup only when the chosen interval passed', () async {
      await api.patch('/api/backups/settings', {'everyHours': 6});
      server.db.setSetting('last_backup_at', DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String());
      await server.runBackupCheckNow();
      expect(zips(), isEmpty);
      server.db.setSetting('last_backup_at', DateTime.now().toUtc().subtract(const Duration(hours: 7)).toIso8601String());
      await server.runBackupCheckNow();
      expect(zips().length, 1);
      // كل ساعة: بعد ساعة إلا 3 دقايق يعتبر جه وقتها (الكشف كل 10 دقايق)
      await api.patch('/api/backups/settings', {'everyHours': 1});
      server.db.setSetting('last_backup_at', DateTime.now().toUtc().subtract(const Duration(minutes: 57)).toIso8601String());
      await Future<void>.delayed(const Duration(seconds: 1));
      await server.runBackupCheckNow();
      expect(zips().length, 2);
    });

    test('backup after closing the shift, and parallel backups do not clash', () async {
      await api.patch('/api/backups/settings', {'onShiftClose': true});
      await api.post('/api/register/open', {'openingCashCents': 0});
      await api.post('/api/register/close', {'countedCashCents': 0});
      for (var i = 0; i < 50 && zips().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(zips(), isNotEmpty, reason: 'no backup after the shift was closed');
      final results = await Future.wait(List.generate(3, (_) => api.post('/api/backups').then((_) => true, onError: (_) => false)));
      expect(results, everyElement(isTrue));
    });
  });

  // ------------------------------------------------------------------ الرجوع لوحده

  group('corrupted database at start', () {
    test('restores the latest good backup, keeps the broken file, tells the owner', () async {
      await api.post('/api/backups');
      final good = zips().single;
      // شغل بعد النسخة (هيضيع، والمالك لازم يعرف)
      await api.post('/api/users', {'name': 'بعد النسخة', 'username': 'after', 'password': 'pass1234', 'role': 'waiter'});
      // نسخة أحدث بس بايظة: لازم يتخطاها
      File(p.join(dir.path, 'backups', 'orderly-2999-01-01-000000.zip')).writeAsStringSync('broken');
      File(p.join(dir.path, 'backups', 'orderly-2999-01-01-000000.zip')).setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));
      api.close();
      await server.stop();
      final dbFile = File(p.join(dir.path, 'orderly.db'));
      for (final s in ['-wal', '-shm']) {
        final f = File('${dbFile.path}$s');
        if (f.existsSync()) f.deleteSync();
      }
      dbFile.writeAsBytesSync(List.filled(dbFile.lengthSync(), 0x5A)); // الهارد كتب زبالة
      await boot();
      api.token = (await api.post('/api/auth/login', {'username': 'owner', 'password': 'owner123', 'deviceId': 'owner-device-1'}))['token'] as String;
      final users = ((await api.get('/api/users'))['users'] as List).map((u) => u['username']);
      expect(users, contains('owner'));
      expect(users, isNot(contains('after')), reason: 'the data came from the backup');
      final rec = (await api.get('/api/shop'))['dbRecovery'] as Map;
      expect(rec['backup'], p.basename(good.path));
      expect(File(p.join(rec['corruptFolder'] as String, 'orderly.db')).existsSync(), isTrue, reason: 'the broken file must be kept');
      await api.patch('/api/backups/settings', {'dismissRecovery': true});
      expect((await api.get('/api/shop'))['dbRecovery'], isNull);
    });

    test('no usable backup: clear error, broken file kept, nothing invented', () async {
      api.close();
      await server.stop();
      final dbFile = File(p.join(dir.path, 'orderly.db'));
      for (final s in ['-wal', '-shm']) {
        final f = File('${dbFile.path}$s');
        if (f.existsSync()) f.deleteSync();
      }
      dbFile.writeAsBytesSync(List.filled(8192, 0x5A));
      server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
      Object? error;
      try {
        await server.start();
      } catch (e) {
        error = e;
      }
      expect('$error', contains('مفيش نسخة احتياطية سليمة'));
      expect(Directory(dir.path).listSync().whereType<Directory>().where((d) => p.basename(d.path).startsWith('corrupt-')), isNotEmpty);
      // عشان الـ tearDown
      dir = await Directory.systemTemp.createTemp('orderly_hardening_spare');
      await boot();
    });
  });

  // ------------------------------------------------------------------ الصلاحيات

  group('permissions', () {
    test('transfer screenshots: cashier yes, waiter/kitchen no; menu photos: everyone', () async {
      final m = await menu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      await api.post('/api/pay-methods', {'name': 'محفظة', 'kind': 'wallet', 'account': '01000000000'});
      final wallet = (((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'wallet') as Map)['id'];
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '1'")!['qr_key'] as String;
      final png = img.encodePng(img.Image(width: 40, height: 40));
      server.ingestCloudMessage('proof-1', {
        't': 'order', 'k': key, 'c': 'client-proof-1', 'at': DateTime.now().millisecondsSinceEpoch,
        'j': jsonEncode({'name': 'منى', 'phone': '01012345678', 'items': [{'i': m['coffee'], 'q': 1}], 'pay': {'m': wallet}}),
      }, png);
      final proofId = server.db.selectOne("SELECT proof_file FROM payments WHERE cloud_id = 'proof-1'")!['proof_file'] as String;
      await api.put('/api/items/${m['coffee']}/image', {'base64': base64.encode(png)});
      final menuImg = server.db.selectOne('SELECT image_id FROM items WHERE id = ?', [m['coffee']])!['image_id'] as String;

      Future<int> fetch(ApiClient c, String id) async {
        final r = await HttpClient().getUrl(Uri.parse('$base/api/files/$id')).then((q) {
          q.headers.set('authorization', 'Bearer ${c.token}');
          return q.close();
        });
        await r.drain<void>();
        return r.statusCode;
      }

      // التجربة 3 أجهزة بس: الموظفين التلاتة على نفس التابلت
      final waiter = await user('user_w2', 'waiter', device: 'shared-tablet'), kitchen = await user('user_k2', 'kitchen', device: 'shared-tablet'), cashier = await user('user_c2', 'cashier', device: 'shared-tablet');
      expect([await fetch(waiter, proofId), await fetch(kitchen, proofId), await fetch(cashier, proofId), await fetch(api, proofId)], [403, 403, 200, 200]);
      expect([await fetch(waiter, menuImg), await fetch(kitchen, menuImg)], [200, 200]);
      for (final c in [waiter, kitchen, cashier]) {
        c.close();
      }
    });

    test('token in the URL works for the live connection only', () async {
      final r = await HttpClient().getUrl(Uri.parse('$base/api/auth/me?token=${api.token}')).then((q) => q.close());
      await r.drain<void>();
      expect(r.statusCode, 401);
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/api/ws?token=${api.token}');
      expect(ws.readyState, WebSocket.open);
      await ws.close();
    });

    test('devices are counted by their unique id, not their name', () async {
      await api.post('/api/users', {'name': 'w', 'username': 'user_w3', 'password': 'pass1234', 'role': 'waiter'});
      final c = ApiClient(base);
      await expectStatus(c.post('/api/auth/login', {'username': 'user_w3', 'password': 'pass1234', 'deviceName': 'Android - localhost'}), 400);
      // التجربة: 3 أجهزة. الجهاز بتاع المالك (setup) + اتنين، وبعدهم الرابع يترفض حتى لو بنفس الاسم
      for (final id in ['phone-0001', 'phone-0002']) {
        await c.post('/api/auth/login', {'username': 'user_w3', 'password': 'pass1234', 'deviceName': 'Android - localhost', 'deviceId': id});
      }
      await expectStatus(c.post('/api/auth/login', {'username': 'user_w3', 'password': 'pass1234', 'deviceName': 'Android - localhost', 'deviceId': 'phone-0003'}), 402);
      // جهاز معروف يقدر يدخل تاني
      await c.post('/api/auth/login', {'username': 'user_w3', 'password': 'pass1234', 'deviceId': 'phone-0001'});
      c.close();
    });

    test('only the printer that took a job can report it printed', () async {
      final m = await menu();
      final checkId = await tableCheck('2');
      await api.post('/api/checks/$checkId/orders', {
        'lines': [
          {'itemId': m['coffee'], 'qty': 1},
        ],
      });
      final printer = await user('bar1', 'kitchen', device: 'bar-tablet-1');
      final waiter = await user('user_w4', 'waiter');
      final jobs = (await printer.get('/api/print/claim', query: {'stations': m['bar']!}))['jobs'] as List;
      final job = (jobs.single as Map)['id'];
      expect(server.db.selectOne('SELECT claimed_by FROM print_jobs WHERE id = ?', [job])!['claimed_by'], 'bar-tablet-1');
      await expectStatus(waiter.post('/api/print/$job/result', {'ok': true}), 403);
      await printer.post('/api/print/$job/result', {'ok': true});
      expect(server.db.selectOne('SELECT status FROM print_jobs WHERE id = ?', [job])!['status'], 'done');
      printer.close();
      waiter.close();
    });
  });

  // ------------------------------------------------------------------ الطلب المكرر

  group('no duplicate staff orders', () {
    test('same request id sent again (reply lost): stored once, same answer', () async {
      final m = await menu();
      final checkId = await tableCheck('3');
      final body = {
        'lines': [
          {'itemId': m['coffee'], 'qty': 2},
        ],
        'requestId': 'req-0000-0001',
      };
      final first = await api.post('/api/checks/$checkId/orders', body);
      final again = await api.post('/api/checks/$checkId/orders', body);
      expect(again['orderId'], first['orderId']);
      expect(again['repeated'], isTrue);
      // 10 مرات في نفس اللحظة
      final burst = {...body, 'requestId': 'req-0000-0002'};
      final ids = await Future.wait(List.generate(10, (_) => ApiClient(base, token: api.token).post('/api/checks/$checkId/orders', burst).then((r) => r['orderId'])));
      expect(ids.toSet().length, 1);
      expect(server.db.select('SELECT id FROM orders').length, 2);
      expect(server.db.select("SELECT id FROM print_jobs WHERE kind = 'ticket'").length, 2, reason: 'the kitchen must not get a second ticket');
      expect(((await api.get('/api/checks/$checkId'))['check'] as Map)['subtotalCents'], 20000);
      await expectStatus(api.post('/api/checks/$checkId/orders', {...body, 'requestId': 'x'}), 400);
    });
  });

  // ------------------------------------------------------------------ إغراق الـ QR

  group('QR flood per table', () {
    Map<String, dynamic> qr(String key, String client, String coffee) => {
          't': 'order', 'k': key, 'c': client, 'at': DateTime.now().millisecondsSinceEpoch,
          'j': jsonEncode({'name': 'هجوم', 'phone': '01000000000', 'items': [{'i': coffee, 'q': 1}]}),
        };

    test('rotating phone ids cannot flood one table', () async {
      final m = await menu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '4'")!['qr_key'] as String;
      for (var i = 0; i < 30; i++) {
        server.ingestCloudMessage('flood-$i', qr(key, 'rotating-phone-$i', m['coffee']!));
      }
      final pending = server.db.select("SELECT id FROM orders WHERE status = 'pending'").length;
      final rejected = server.db.selectOne("SELECT reject_reason FROM orders WHERE status = 'rejected' LIMIT 1");
      expect(pending, 6);
      expect(rejected!['reject_reason'], contains('كتير'));
      // ترابيزة تانية مش متأثرة
      final other = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '5'")!['qr_key'] as String;
      server.ingestCloudMessage('other-1', qr(other, 'normal-phone-1', m['coffee']!));
      expect(server.db.selectOne("SELECT status FROM orders WHERE cloud_id = 'other-1'")!['status'], 'pending');
    });

    test('auto-accept table: at most 15 QR orders in 10 minutes', () async {
      final m = await menu();
      await api.post('/api/register/open', {'openingCashCents': 0});
      final t = ((await api.get('/api/floor'))['tables'] as List).firstWhere((t) => t['name'] == '4');
      await api.patch('/api/tables/${t['id']}', {'autoAccept': true});
      final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '4'")!['qr_key'] as String;
      for (var i = 0; i < 25; i++) {
        server.ingestCloudMessage('auto-$i', qr(key, 'auto-phone-$i', m['coffee']!));
      }
      expect(server.db.select("SELECT id FROM orders WHERE status = 'accepted'").length, 15);
    });
  });
}
