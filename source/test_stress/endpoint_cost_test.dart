import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// تكلفة كل طلب على السيرفر (مللي ثانية): كافيه في نص الزحمة (310 ترابيزة، 150 حساب مفتوح، 400 طلب في المطبخ).
/// السيرفر شغال على thread واحد، فأي مللي ثانية هنا بتتضرب في عدد الأجهزة وقت الزحمة.
/// النتايج في test-results/stress/endpoint_cost.json
void main() {
  test('endpoint cost under a busy cafe', () async {
    final dir = await Directory.systemTemp.createTemp('orderly_cost');
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
    final items = [for (var i = 0; i < 40; i++) (await api.post('/api/items', {'categoryId': cat, 'name': 'صنف $i', 'priceCents': 3000 + i}))['id']];
    await api.post('/api/tables/bulk', {'from': 1, 'to': 150});
    await api.post('/api/tables/bulk', {'from': 151, 'to': 310});
    await api.post('/api/register/open', {'openingCashCents': 0});
    final tables = ((await api.get('/api/floor'))['tables'] as List).map((t) => t['id']).toList();
    final checks = <String>[];
    for (var i = 0; i < 150; i++) {
      final c = (await api.post('/api/checks', {'type': 'dine_in', 'tableId': tables[i]}))['check']['id'] as String;
      checks.add(c);
      for (var k = 0; k < 3; k++) {
        await api.post('/api/checks/$c/orders', {
          'lines': [
            {'itemId': items[(i + k) % 40], 'qty': 1},
            {'itemId': items[(i * 3 + k) % 40], 'qty': 2},
          ],
        });
      }
    }

    final client = HttpClient();
    Future<void> call(String method, String path, [Object? body]) async {
      final r = await client.openUrl(method, Uri.parse('$base$path'));
      r.headers.set('authorization', 'Bearer ${api.token}');
      r.headers.set('accept-encoding', 'gzip');
      if (body != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(body));
      }
      final res = await r.close();
      await res.drain<void>();
      if (res.statusCode != 200) throw StateError('$path ${res.statusCode}');
    }

    Future<double> cost(String name, Future<void> Function(int i) f, {int n = 150}) async {
      for (var i = 0; i < 10; i++) {
        await f(i);
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        await f(i);
      }
      return sw.elapsedMicroseconds / n / 1000;
    }

    var o = 0;
    final results = <String, double>{
      'GET /api/floor': await cost('floor', (_) => call('GET', '/api/floor')),
      'GET /api/kds': await cost('kds', (_) => call('GET', '/api/kds')),
      'GET /api/live': await cost('live', (_) => call('GET', '/api/live')),
      'GET /api/checks': await cost('checks', (_) => call('GET', '/api/checks')),
      'GET /api/info (no auth)': await cost('info', (_) => call('GET', '/api/info')),
      'POST order': await cost('order', (_) => call('POST', '/api/checks/${checks[o++ % 150]}/orders', {
            'lines': [
              {'itemId': items[o % 40], 'qty': 1},
            ],
          })),
    };
    final out = File('../test-results/stress/endpoint_cost.json')..parent.createSync(recursive: true);
    final label = Platform.environment['COST_LABEL'] ?? 'run';
    final all = out.existsSync() ? (jsonDecode(out.readAsStringSync()) as Map).cast<String, dynamic>() : <String, dynamic>{};
    all[label] = results.map((k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2))));
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(all));
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(results));
    client.close(force: true);
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  }, timeout: Timeout.none);
}
