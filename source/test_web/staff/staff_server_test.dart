// سيرفر حقيقي مؤقت بيقدّم نسخة الويب (build/web) عشان Playwright يفتحها كأيفون وأندرويد (staff.spec.js).
// بيكتب staff-fixture.json (العنوان والدخول) وبيستنى لحد ما Playwright يخلص (ملف staff-done).
// التشغيل: run.ps1 في نفس الفولدر (بعد flutter build web).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

void main() {
  test('serve the staff web app for Playwright', () async {
    final out = Directory(Platform.environment['WEB_OUT']!);
    final dir = await Directory.systemTemp.createTemp('orderly_staffweb');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false, webDir: '${Directory.current.path}/build/web');
    await server.start();
    final base = 'http://127.0.0.1:${server.port}';
    final api = ApiClient(base);
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه الويب', 'ownerName': 'المالك', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
    await api.post('/api/users', {'name': 'سارة', 'username': 'sara', 'password': 'sara1234', 'role': 'waiter'});
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    await api.post('/api/items', {'categoryId': cat, 'name': 'لاتيه', 'priceCents': 6000});
    await api.post('/api/tables/bulk', {'from': 1, 'to': 4});
    File('${out.path}/staff-fixture.json').writeAsStringSync(jsonEncode({'base': base, 'user': 'sara', 'pass': 'sara1234'}));

    final done = File('${out.path}/staff-done');
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (!done.existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('Playwright never finished');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    // الدخول من المتصفح وصل للسيرفر فعلاً (واسم الجهاز بيقول إنه ويب)
    final sessions = server.db.select("SELECT s.device_name FROM sessions s JOIN users u ON u.id = s.user_id WHERE u.username = 'sara'");
    File('${out.path}/staff-sessions.json').writeAsStringSync(jsonEncode([for (final s in sessions) s['device_name']]));
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
