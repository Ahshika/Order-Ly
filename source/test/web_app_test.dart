// السيرفر بيقدّم نسخة الويب للموظفين (الأيفون) على نفس البورت، من غير ما يطلّع أي ملف بره فولدرها.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orderly/src/server/api_server.dart';

void main() {
  late Directory dir;
  late Directory web;
  late OrderlyServer server;
  late String base;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('orderly_webapp');
    web = Directory('${dir.path}/web')..createSync();
    File('${web.path}/index.html').writeAsStringSync('<!doctype html><title>Order Ly</title>');
    File('${web.path}/main.dart.js').writeAsStringSync('console.log(1)');
    Directory('${web.path}/canvaskit').createSync();
    File('${web.path}/canvaskit/canvaskit.wasm').writeAsBytesSync([0, 97, 115, 109]);
    // ملف سري جنب فولدر الويب: ممنوع يوصله حد
    File('${dir.path}/secret.txt').writeAsStringSync('SECRET');
    server = OrderlyServer(dataDir: '${dir.path}/data', requestedPort: 0, cloudSync: false, webDir: web.path);
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  test('the page, its files with the right types, and 304 when nothing changed', () async {
    final index = await http.get(Uri.parse('$base/'));
    expect(index.statusCode, 200);
    expect(index.headers['content-type'], startsWith('text/html'));
    expect(index.body, contains('Order Ly'));
    expect(index.headers['cache-control'], 'no-cache');

    final wasm = await http.get(Uri.parse('$base/canvaskit/canvaskit.wasm'));
    expect(wasm.headers['content-type'], 'application/wasm');
    final js = await http.get(Uri.parse('$base/main.dart.js'));
    expect(js.headers['content-type'], startsWith('text/javascript'));

    final again = await http.get(Uri.parse('$base/main.dart.js'), headers: {'if-none-match': js.headers['etag']!});
    expect(again.statusCode, 304);

    // صفحة جوه البرنامج (من غير امتداد) = الصفحة الرئيسية، وملف مش موجود = 404
    expect((await http.get(Uri.parse('$base/orders'))).body, contains('Order Ly'));
    expect((await http.get(Uri.parse('$base/nothing.js'))).statusCode, 404);
  });

  test('nothing outside the web folder can be read', () async {
    for (final path in ['/../secret.txt', '/%2e%2e/secret.txt', '/..%2fsecret.txt', '/canvaskit/..%5c..%5csecret.txt', '/C:%5cWindows%5cwin.ini']) {
      final res = await http.get(Uri.parse('$base$path'));
      expect(res.body, isNot(contains('SECRET')), reason: path);
      expect(res.statusCode, anyOf(404, 200), reason: path);
    }
    // ومحاولة عن طريق اتصال خام (من غير ما مكتبة http تنضّف المسار)
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write('GET /../secret.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
    final raw = await socket.cast<List<int>>().transform(const SystemEncoding().decoder).join();
    expect(raw, isNot(contains('SECRET')));
    await socket.close();
  });

  test('the API is unchanged: unknown /api paths are still JSON 404, POST to the page is refused', () async {
    final res = await http.get(Uri.parse('$base/api/nothing'));
    expect(res.statusCode, 404);
    expect(res.headers['content-type'], contains('json'));
    expect((await http.get(Uri.parse('$base/api/info'))).statusCode, 200);
    expect((await http.post(Uri.parse('$base/index.html'))).statusCode, 405);
  });

  test('no web folder: a clear Arabic message instead of a crash', () async {
    await server.stop();
    server = OrderlyServer(dataDir: '${dir.path}/data2', requestedPort: 0, cloudSync: false, webDir: '${dir.path}/missing');
    await server.start();
    final res = await http.get(Uri.parse('http://127.0.0.1:${server.port}/'));
    expect(res.statusCode, 404);
    expect(res.body, contains('نسخة الويب'));
  });
}
