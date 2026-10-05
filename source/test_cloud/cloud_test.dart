// اختبار حقيقي على Firebase (محتاج نت). بيعمل كافيه مؤقت في فولدر مؤقت، وبيمسح كل حاجة في الآخر.
// التشغيل:  flutter test test_cloud/cloud_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:orderly/src/core/api_client.dart';
import 'package:orderly/src/core/firebase_config.dart';
import 'package:orderly/src/server/api_server.dart';

void main() {
  late Directory dir;
  late OrderlyServer server;
  late ApiClient api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_cloud');
    server = OrderlyServer(dataDir: dir.path, requestedPort: 0);
    await server.start();
    api = ApiClient('http://127.0.0.1:${server.port}');
    api.token = (await api.post('/api/setup', {'shopName': 'كافيه تجربة', 'ownerName': 'تست', 'username': 'owner', 'password': 'owner123'}))['token'] as String;
  });

  tearDown(() async {
    await server.cleanupCloudForTests();
    api.close();
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<T> waitFor<T>(Future<T?> Function() f, {Duration timeout = const Duration(seconds: 40)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final v = await f();
      if (v != null) return v;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('timeout');
  }

  Future<http.Response> anon(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$rtdbUrl/$path.json'));
    if (body != null) req.body = jsonEncode(body);
    return http.Response.fromStream(await req.send());
  }

  test('customer phone → Firebase → cashier, and status back to the phone', () async {
    final stations = (await api.get('/api/menu'))['stations'] as List;
    await api.post('/api/categories', {'name': 'مشروبات', 'stationId': stations.first['id']});
    final cat = ((await api.get('/api/menu'))['categories'] as List).single['id'];
    final item = await api.post('/api/items', {'categoryId': cat, 'name': 'إسبريسو', 'priceCents': 4000});
    await api.post('/api/tables', {'name': '1'});
    await api.post('/api/register/open', {});
    final wallet = (await api.post('/api/pay-methods', {'name': 'فودافون كاش', 'kind': 'wallet', 'account': '01000000000'}))['methods'] as List;
    final walletId = wallet.firstWhere((m) => m['kind'] == 'wallet')['id'];
    await server.syncNow();
    final uid = server.db.setting('cloud_uid')!;
    final key = server.db.selectOne("SELECT qr_key FROM tables WHERE name = '1'")!['qr_key'] as String;

    // الصفحة بتقرا بيانات الكافيه والمنيو من غير تسجيل دخول
    final pub = jsonDecode((await anon('GET', 'cafes/$uid/pub')).body) as Map;
    expect(pub['name'], 'كافيه تجربة');
    expect(pub['open'], true);
    expect((pub['pay'] as List).any((m) => m['acc'] == '01000000000'), true);
    final menu = jsonDecode((await anon('GET', 'cafes/$uid/menu')).body) as Map;
    expect((menu['items'] as List).single['n'], 'إسبريسو');
    expect(jsonDecode((await anon('GET', 'cafes/$uid/tables/$key')).body)['n'], '1');

    // ممنوع: قراءة كل أكواد الترابيزات، أو inbox الكافيه، أو الكتابة بكود غلط
    expect((await anon('GET', 'cafes/$uid/tables')).statusCode, 401);
    expect((await anon('GET', 'inbox/$uid')).statusCode, 401);
    final msg = {
      't': 'order',
      'k': 'wrongKey',
      'c': 'test-client-123456',
      'at': {'.sv': 'timestamp'},
      'j': jsonEncode({
        'name': 'تجربة',
        'phone': '01011112222',
        'items': [
          {'i': item['id'], 'q': 2},
        ],
        'pay': {'m': walletId, 'a': 8000},
      }),
    };
    expect((await anon('PUT', 'inbox/$uid/bad1', msg)).statusCode, 401);

    // العميل يرفع صورة التحويل ويبعت الطلب
    final png = base64.encode(img.encodePng(img.Image(width: 40, height: 60)));
    expect((await anon('PUT', 'proof/$uid/ord1', {'k': key, 'd': 'data:image/png;base64,$png'})).statusCode, 200);
    expect((await anon('PUT', 'inbox/$uid/ord1', {...msg, 'k': key, 'p': true})).statusCode, 200);
    // نفس المعرّف مرة تانية مرفوض (العميل مايقدرش يعدّل رسالة اتبعتت)
    expect((await anon('PUT', 'inbox/$uid/ord1', {...msg, 'k': key})).statusCode, 401);

    // الطلب بيوصل للكاشير لوحده (لحظي)
    final order = await waitFor(() async => server.db.selectOne("SELECT * FROM orders WHERE cloud_id = 'ord1'"));
    expect(order['status'], 'pending');
    final pay = await waitFor(() async => server.db.selectOne("SELECT * FROM payments WHERE cloud_id = 'ord1'"));
    expect(pay['status'], 'pending');
    expect(pay['proof_file'], isNotNull);
    // الرسالة والصورة بيتمسحوا من النت بعد ما وصلوا
    await waitFor(() async => (await anon('GET', 'proof/$uid/ord1')).statusCode == 401 ? true : null);

    // العميل بيتابع حالة طلبه
    await server.syncNow();
    var track = jsonDecode((await anon('GET', 'trackc/$uid/test-client-123456')).body) as Map;
    expect(track['orders']['ord1']['s'], 'pending');

    await api.post('/api/orders/${order['id']}/accept');
    await server.syncNow();
    track = jsonDecode((await anon('GET', 'trackc/$uid/test-client-123456')).body) as Map;
    expect(track['orders']['ord1']['s'], 'accepted');
    final bill = jsonDecode((await anon('GET', 'trackt/$uid/$key')).body) as Map;
    expect(bill['total'], 8000);
    expect(bill['pend'], 8000);

    // نداء الويتر
    expect((await anon('PUT', 'inbox/$uid/call1', {...msg, 't': 'call', 'k': key, 'j': jsonEncode({'kind': 'waiter'})})).statusCode, 200);
    await waitFor(() async => server.db.selectOne("SELECT * FROM service_calls WHERE cloud_id = 'call1'"));

    // الكافيه قفل الدرج: الصفحة بتعرف إنه مش بيستقبل، والكتابة بتترفض
    await api.post('/api/payments/${pay['id']}/confirm');
    await api.post('/api/checks/${order['check_id']}/close');
    await api.post('/api/register/close', {'countedCashCents': 0});
    await server.syncNow();
    expect((jsonDecode((await anon('GET', 'cafes/$uid/pub')).body) as Map)['open'], false);
    expect((await anon('PUT', 'inbox/$uid/late1', {...msg, 'k': key})).statusCode, 401);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
