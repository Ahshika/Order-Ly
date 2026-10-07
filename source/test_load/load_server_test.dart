import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/server/api_server.dart';

/// سيرفر لاختبار الضغط (k6): نفس سيرفر البرنامج بس على فولدر مؤقت وبورت تاني،
/// عمره ما بيلمس بيانات الكافيه الحقيقية.
///
/// LOAD_OUT = فولدر بيتكتب فيه seed.json (التوكن والأصناف والترابيزات) و server_metrics.csv
/// وبيفضل شغال لحد ما يلاقي ملف LOAD_OUT/stop.
void main() {
  test('load server', () async {
    final out = Directory(Platform.environment['LOAD_OUT']!);
    final port = int.parse(Platform.environment['LOAD_PORT'] ?? '18790');
    final dir = await Directory.systemTemp.createTemp('orderly_load');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: port, cloudSync: false);
    await server.start();
    final api = ApiClient('http://127.0.0.1:$port');
    api.token = (await api.post('/api/setup', {
      'shopName': 'كافيه التيست',
      'ownerName': 'تيست',
      'username': 'owner',
      'password': 'owner123',
    }))['token'] as String;

    // منيو: 4 أقسام × 10 أصناف، نص المشروبات ليها حجم إجباري وإضافات
    var menu = await api.get('/api/menu');
    final stations = (menu['stations'] as List).cast<Map<String, dynamic>>();
    final bar = stations.firstWhere((s) => s['name'] == 'البار')['id'];
    final kitchen = stations.firstWhere((s) => s['name'] == 'المطبخ')['id'];
    final size = await api.post('/api/modifier-groups', {
      'name': 'الحجم', 'minSelect': 1, 'maxSelect': 1,
      'options': [
        {'name': 'وسط', 'priceCents': 0, 'isDefault': true},
        {'name': 'كبير', 'priceCents': 1500},
      ],
    });
    final extras = await api.post('/api/modifier-groups', {
      'name': 'إضافات', 'minSelect': 0, 'maxSelect': 2,
      'options': [
        {'name': 'شوت', 'priceCents': 1000},
        {'name': 'شوفان', 'priceCents': 1200},
      ],
    });
    final items = <Map<String, Object?>>[];
    for (var c = 0; c < 4; c++) {
      final drinks = c < 2;
      final m = await api.post('/api/categories', {'name': 'قسم $c', 'stationId': drinks ? bar : kitchen});
      final cat = (m['categories'] as List).firstWhere((x) => x['name'] == 'قسم $c');
      for (var i = 0; i < 10; i++) {
        final withMods = drinks && i.isEven;
        final it = await api.post('/api/items', {
          'categoryId': cat['id'],
          'name': 'صنف $c-$i',
          'priceCents': 3000 + i * 500,
          if (withMods) 'groupIds': [size['id'], extras['id']],
        });
        items.add({'id': it['id'], 'mods': withMods});
      }
    }
    menu = await api.get('/api/menu');
    final groups = (menu['modifierGroups'] as List).cast<Map<String, dynamic>>();
    List<String> opts(String g) => (groups.firstWhere((x) => x['name'] == g)['options'] as List).map((o) => o['id'] as String).toList();

    // 310 ترابيزة (كل مستخدم وهمي في k6 بياخد ترابيزة لوحده)
    await api.post('/api/tables/bulk', {'from': 1, 'to': 150});
    await api.post('/api/tables/bulk', {'from': 151, 'to': 310});
    final tables = ((await api.get('/api/floor'))['tables'] as List).map((t) => t['id']).toList();
    final cash = ((await api.get('/api/pay-methods'))['methods'] as List).firstWhere((x) => x['kind'] == 'cash')['id'];
    await api.post('/api/register/open', {'openingCashCents': 50000});

    await out.create(recursive: true);
    File('${out.path}/seed.json').writeAsStringSync(jsonEncode({
      'base': 'http://127.0.0.1:$port',
      'token': api.token,
      'items': items,
      'sizes': opts('الحجم'),
      'extras': opts('إضافات'),
      'tables': tables,
      'cash': cash,
    }));

    // كل ثانية: تأخير الـ event loop (لو كبير يبقى السيرفر "مهنّج")، الرامات، حجم الداتابيز
    final metrics = File('${out.path}/server_metrics.csv').openWrite()..writeln('time,loop_lag_ms,rss_mb,db_mb,wal_mb');
    final stop = File('${out.path}/stop');
    var last = DateTime.now();
    while (!stop.existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final now = DateTime.now();
      final lag = now.difference(last).inMilliseconds - 1000;
      last = now;
      double mb(String f) => File(f).existsSync() ? File(f).lengthSync() / 1048576 : 0;
      metrics.writeln('${now.toUtc().toIso8601String()},$lag,${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)},'
          '${mb('${dir.path}/orderly.db').toStringAsFixed(2)},${mb('${dir.path}/orderly.db-wal').toStringAsFixed(2)}');
    }
    await metrics.close();
    // نسخة من لوج السيرفر قبل ما الفولدر المؤقت يتمسح
    final log = File('${dir.path}/logs/server.log');
    if (log.existsSync()) log.copySync('${out.path}/server.log');
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  }, timeout: Timeout.none);
}
