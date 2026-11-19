import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// مقارنة A/B في نفس اللحظة: تكلفة "إضافة طلب" على قاعدة بيانات كبيرة (زي آخر اختبار الضغط) بالفهارس الجديدة ومن غيرها.
void main() {
  test('order cost with and without the new indexes', () async {
    final dir = await Directory.systemTemp.createTemp('orderly_ab');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    final base = 'http://127.0.0.1:${server.port}';
    final api = ApiClient(base);
    api.token = (await api.post('/api/setup', {'shopName': 'ك', 'ownerName': 'أ', 'username': 'owner', 'password': 'owner123', 'deviceId': 'bench-device'}))['token'] as String;
    var menu = await api.get('/api/menu');
    final bar = ((menu['stations'] as List).first as Map)['id'];
    await api.post('/api/categories', {'name': 'قسم', 'stationId': bar});
    menu = await api.get('/api/menu');
    final cat = ((menu['categories'] as List).first as Map)['id'];
    final item = (await api.post('/api/items', {'categoryId': cat, 'name': 'صنف', 'priceCents': 3000}))['id'];
    await api.post('/api/tables/bulk', {'from': 1, 'to': 200});
    final tables = ((await api.get('/api/floor'))['tables'] as List).map((t) => t['id']).toList();
    final checks = [for (final t in tables) (await api.post('/api/checks', {'type': 'dine_in', 'tableId': t}))['check']['id'] as String];

    final client = HttpClient();
    var n = 0;
    Future<void> order() async {
      final r = await client.openUrl('POST', Uri.parse('$base/api/checks/${checks[n++ % checks.length]}/orders'));
      r.headers.set('authorization', 'Bearer ${api.token}');
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode({
        'lines': [
          {'itemId': item, 'qty': 1},
        ],
      }));
      final res = await r.close();
      await res.drain<void>();
    }

    // قاعدة بيانات كبيرة: 20,000 طلب
    for (var i = 0; i < 20000; i++) {
      await order();
    }
    Future<double> measure() async {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 1500; i++) {
        await order();
      }
      return sw.elapsedMicroseconds / 1500 / 1000;
    }

    final results = <String, double>{};
    for (var round = 0; round < 2; round++) {
      results['with new indexes #$round'] = await measure();
      server.db.execute('DROP INDEX idx_orders_client; DROP INDEX idx_orders_table_status;');
      results['without #$round'] = await measure();
      server.db.execute('CREATE INDEX idx_orders_client ON orders(client_id, created_at); CREATE INDEX idx_orders_table_status ON orders(table_id, status);');
    }
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(results.map((k, v) => MapEntry(k, v.toStringAsFixed(3)))));
    File('../test-results/stress/order_cost_ab.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    client.close(force: true);
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  }, timeout: Timeout.none);
}
