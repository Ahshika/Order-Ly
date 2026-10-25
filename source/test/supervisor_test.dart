import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late OrderlyServer server;
  late String base;
  late ApiClient owner;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_supervisor');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    owner = ApiClient(base);
    owner.token = (await owner.post('/api/setup', {
      'shopName': 'كافيه', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123',
    }))['token'] as String;
  });

  tearDown(() async {
    owner.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<void> expectApiError(Future<Object?> f, int status) async {
    try {
      await f;
      fail('expected $status');
    } on ApiException catch (e) {
      expect(e.status, status, reason: e.message);
    }
  }

  Future<ApiClient> login(String username, String password, String role) async {
    await owner.post('/api/users', {'name': username, 'username': username, 'password': password, 'role': role});
    final c = ApiClient(base);
    c.token = (await c.post('/api/auth/login', {'username': username, 'password': password}))['token'] as String;
    return c;
  }

  test('supervisor: voids checks and sees old shifts, but no reports, menu or users', () async {
    final sup = await login('mona', 'mona1234', 'supervisor');
    final cashier = await login('sara', 'sara1234', 'cashier');

    final checkId = (await cashier.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    await expectApiError(cashier.post('/api/checks/$checkId/void', {'reason': 'غلط'}), 403);
    await sup.post('/api/checks/$checkId/void', {'reason': 'غلط'});

    await sup.post('/api/register/open', {'openingCashCents': 0});
    await sup.get('/api/register/history');
    await expectApiError(cashier.get('/api/register/history'), 403);
    await expectApiError(sup.get('/api/reports/summary'), 403);
    await expectApiError(sup.post('/api/categories', {'name': 'x'}), 403);
    await expectApiError(sup.get('/api/users'), 403);

    sup.close();
    cashier.close();
  });

  test('upgrading an old database keeps users and lets the owner add a supervisor', () async {
    final waiter = await login('ali', 'ali12345', 'waiter');
    final checkId = (await waiter.post('/api/checks', {'type': 'takeaway'}))['check']['id'] as String;
    waiter.close();
    await server.stop();

    // نرجّع الملف لنسخة ما قبل "مسؤول شفت" عشان الـ migration تتنفذ تاني على بيانات حقيقية
    final raw = sqlite3.open(p.join(dir.path, 'orderly.db'));
    raw.userVersion = 6;
    raw.close();

    server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    owner.close();
    owner = ApiClient(base);
    owner.token = (await owner.post('/api/auth/login', {'username': 'owner', 'password': 'owner123'}))['token'] as String;

    final users = (await owner.get('/api/users'))['users'] as List;
    expect(users.map((u) => u['username']), containsAll(['owner', 'ali']));
    expect((await owner.get('/api/checks/$checkId'))['check']['id'], checkId);
    final sup = await login('mona', 'mona1234', 'supervisor');
    expect((await sup.get('/api/auth/me'))['user']['role'], 'supervisor');
    sup.close();
  });
}
