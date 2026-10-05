// بيطلع ملف PDF لكروت الـ QR ببيانات تجريبية للمراجعة (test_visual/shots/qr_cards*.pdf).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';
import 'package:orderly/src/core/shop.dart';
import 'package:orderly/src/features/printing/print_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<({String title, String subtitle, String url})> cards(int n) => [
        for (var i = 1; i <= n; i++) (title: 'ترابيزة $i', subtitle: 'الصالة', url: 'https://orderly-yvzug.web.app/m/VLQsqjmCF2Sf59k4pCp6KPYbO7J3/K45vFEheV67L5ys$i'),
        (title: 'تيك أواي', subtitle: 'اطلب واستلم من الكاونتر', url: 'https://orderly-yvzug.web.app/m/VLQsqjmCF2Sf59k4pCp6KPYbO7J3/tkK45vFEheV67L5'),
      ];

  test('render qr cards', () async {
    await initializeDateFormatting('ar');
    Directory('test_visual/shots').createSync(recursive: true);
    final logo = img.Image(width: 300, height: 300);
    img.fill(logo, color: img.ColorRgb8(255, 255, 255));
    img.fillCircle(logo, x: 150, y: 150, radius: 140, color: img.ColorRgb8(120, 70, 40));
    img.fillCircle(logo, x: 150, y: 150, radius: 80, color: img.ColorRgb8(240, 220, 190));
    final withLogo = ShopProfile({
      'name': 'كافيه الندى',
      'logoBase64': base64.encode(img.encodePng(logo)),
      'settings': {'wifiName': 'Elnada-Guest', 'wifiPassword': 'coffee2026'},
    });
    final noLogo = ShopProfile({'name': 'Bean & Brew كافيه', 'settings': <String, Object?>{}});
    File('test_visual/shots/qr_cards_logo.pdf').writeAsBytesSync(await buildQrCardsPdf(cards(5), withLogo));
    File('test_visual/shots/qr_cards_nologo.pdf').writeAsBytesSync(await buildQrCardsPdf(cards(1), noLogo));
    File('test_visual/shots/qr_cards_big.pdf').writeAsBytesSync(await buildQrCardsPdf(cards(1), withLogo, perPage: 1));
  });
}
