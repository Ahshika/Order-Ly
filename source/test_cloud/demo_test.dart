// كافيه تجريبي مؤقت على النت عشان نجرب صفحة المنيو من المتصفح (فولدر مؤقت، وبيتمسح في الآخر).
// التشغيل:  flutter test test_cloud/demo_test.dart --dart-define=DEMO_MINUTES=15
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/firebase_config.dart';
import 'package:orderly/src/server/api_server.dart';

const _minutes = int.fromEnvironment('DEMO_MINUTES', defaultValue: 15);
const _out = String.fromEnvironment('DEMO_OUT', defaultValue: 'demo.json');

List<int> _photo(int r, int g, int b) {
  final im = img.Image(width: 480, height: 320);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  img.fillCircle(im, x: 240, y: 160, radius: 110, color: img.ColorRgb8(255, 255, 255));
  img.fillCircle(im, x: 240, y: 160, radius: 85, color: img.ColorRgb8((r * .6).round(), (g * .6).round(), (b * .6).round()));
  return img.encodeJpg(im);
}

void main() {
  test('demo cafe', () async {
    final dir = await Directory.systemTemp.createTemp('orderly_demo');
    final server = OrderlyServer(dataDir: dir.path, requestedPort: 0);
    await server.start();
    final api = ApiClient('http://127.0.0.1:${server.port}');
    try {
      api.token = (await api.post('/api/setup', {'shopName': 'كافيه الندى', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
      final stations = (await api.get('/api/menu'))['stations'] as List;
      final bar = stations.first['id'], kitchen = stations.last['id'];
      await api.patch('/api/shop', {
        'settings': {'serviceBp': 1200, 'qrWelcome': 'أهلاً بيك! اطلب من موبايلك وإحنا نجهزه ☕', 'wifiName': 'Elnada-Guest', 'wifiPassword': 'coffee2026', 'loyaltyEnabled': true},
      });
      await api.post('/api/categories', {'name': 'مشروبات ساخنة', 'nameEn': 'Hot drinks', 'stationId': bar});
      await api.post('/api/categories', {'name': 'مشروبات ساقعة', 'nameEn': 'Iced drinks', 'stationId': bar});
      await api.post('/api/categories', {'name': 'حلويات', 'nameEn': 'Desserts', 'stationId': kitchen});
      final cats = {for (final c in (await api.get('/api/menu'))['categories'] as List) c['name']: c['id']};
      final size = await api.post('/api/modifier-groups', {
        'name': 'الحجم', 'nameEn': 'Size', 'minSelect': 1, 'maxSelect': 1,
        'options': [
          {'name': 'وسط', 'nameEn': 'Medium', 'isDefault': true},
          {'name': 'كبير', 'nameEn': 'Large', 'priceCents': 1500},
        ],
      });
      final sugar = await api.post('/api/modifier-groups', {
        'name': 'السكر', 'nameEn': 'Sugar', 'minSelect': 0, 'maxSelect': 1,
        'options': [
          {'name': 'من غير', 'nameEn': 'None'},
          {'name': 'خفيف', 'nameEn': 'Light'},
          {'name': 'زيادة', 'nameEn': 'Extra'},
        ],
      });
      final extras = await api.post('/api/modifier-groups', {
        'name': 'إضافات', 'nameEn': 'Extras', 'minSelect': 0, 'maxSelect': 3,
        'options': [
          {'name': 'شوت إسبريسو', 'nameEn': 'Espresso shot', 'priceCents': 1000},
          {'name': 'لبن شوفان', 'nameEn': 'Oat milk', 'priceCents': 1200},
          {'name': 'كراميل', 'nameEn': 'Caramel', 'priceCents': 800},
        ],
      });
      Future<String> item(String cat, String name, String en, int price, {List<Object?> groups = const [], String? desc, List<String> tags = const [], List<int>? rgb}) async {
        final res = await api.post('/api/items', {
          'categoryId': cats[cat], 'name': name, 'nameEn': en, 'priceCents': price, 'groupIds': groups, 'description': desc, 'tags': tags,
        });
        final id = res['id'] as String;
        if (rgb != null) await api.put('/api/items/$id/image', {'base64': base64.encode(_photo(rgb[0], rgb[1], rgb[2]))});
        return id;
      }

      final latte = await item('مشروبات ساخنة', 'لاتيه', 'Latte', 6000, groups: [size['id'], sugar['id'], extras['id']], desc: 'إسبريسو دبل مع لبن مبخر ورغوة ناعمة', tags: ['best'], rgb: [180, 130, 90]);
      await item('مشروبات ساخنة', 'كابتشينو', 'Cappuccino', 5500, groups: [size['id'], sugar['id'], extras['id']], rgb: [150, 100, 70]);
      await item('مشروبات ساخنة', 'إسبريسو', 'Espresso', 3500, groups: [sugar['id']], rgb: [90, 60, 40]);
      await item('مشروبات ساقعة', 'آيس لاتيه', 'Iced latte', 6500, groups: [size['id'], sugar['id'], extras['id']], tags: ['cold', 'new'], rgb: [200, 170, 140]);
      await item('مشروبات ساقعة', 'موهيتو', 'Mojito', 5000, tags: ['cold'], rgb: [120, 200, 120]);
      final cake = await item('حلويات', 'تشيز كيك', 'Cheesecake', 8500, desc: 'بصوص التوت', rgb: [230, 200, 150]);
      await item('حلويات', 'براوني', 'Brownie', 6000, rgb: [100, 60, 40]);
      await api.patch('/api/items/$latte', {'upsell': [cake]});
      await api.post('/api/tables/bulk', {'from': 1, 'to': 5});
      await api.post('/api/register/open', {});
      await api.post('/api/pay-methods', {'name': 'فودافون كاش', 'kind': 'wallet', 'account': '01012345678'});
      await api.post('/api/pay-methods', {'name': 'InstaPay', 'kind': 'instapay', 'account': 'elnada@instapay', 'instructions': 'اكتب رقم الترابيزة في ملاحظة التحويل'});
      await server.syncNow();
      await Future<void>.delayed(const Duration(seconds: 3));
      await server.syncNow();
      final qr = await api.get('/api/tables/qr');
      File(_out).writeAsStringSync(jsonEncode({'port': server.port, 'token': api.token, 'qr': qr, 'rtdb': rtdbUrl}));
      // ignore: avoid_print
      print('DEMO READY ${qr['tables'][0]['url']}');
      final end = DateTime.now().add(const Duration(minutes: _minutes));
      while (DateTime.now().isBefore(end) && File(_out).existsSync()) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      await server.cleanupCloudForTests();
      api.close();
      await server.stop();
      await dir.delete(recursive: true);
      if (File(_out).existsSync()) File(_out).deleteSync();
    }
  }, timeout: const Timeout(Duration(minutes: _minutes + 3)));
}
