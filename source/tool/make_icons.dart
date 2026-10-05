// بيرسم لوجو Order Ly (فنجان قهوة أبيض على خلفية تركواز، ونقطة QR كهرمانية) بكل المقاسات المطلوبة.
// التشغيل من فولدر source:  dart run tool/make_icons.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

final _teal1 = img.ColorRgb8(0x0F, 0x76, 0x6E);
final _teal2 = img.ColorRgb8(0x14, 0xB8, 0xA6);
final _white = img.ColorRgb8(255, 255, 255);
final _amber = img.ColorRgb8(0xD9, 0x77, 0x06);

bool _inRoundRect(num x, num y, num x0, num y0, num x1, num y1, num r) {
  if (x < x0 || x > x1 || y < y0 || y > y1) return false;
  final cx = x < x0 + r ? x0 + r : (x > x1 - r ? x1 - r : x);
  final cy = y < y0 + r ? y0 + r : (y > y1 - r ? y1 - r : y);
  return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
}

/// الرسم بدقة عالية (4096) وبعدين بيتصغّر عشان الحواف تبقى ناعمة.
img.Image _draw({required bool background, double scale = 1}) {
  const n = 2048;
  final im = img.Image(width: n, height: n, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
  final s = n / 1024 * scale;
  final o = n / 2 - 512 * s;
  double X(num v) => o + v * s;

  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (background && _inRoundRect(x, y, 0, 0, n - 1, n - 1, n * 0.22)) {
        final t = (x + y) / (2 * n);
        im.setPixelRgba(x, y, (_teal1.r + (_teal2.r - _teal1.r) * t).round(), (_teal1.g + (_teal2.g - _teal1.g) * t).round(),
            (_teal1.b + (_teal2.b - _teal1.b) * t).round(), 255);
      }
      // الفنجان: جسم بزوايا مدورة تحت
      final inCup = _inRoundRect(x, y, X(250), X(430), X(690), X(760), 110 * s) && y >= X(430);
      final inTopBar = _inRoundRect(x, y, X(230), X(400), X(710), X(470), 30 * s);
      // الودن
      final dx = x - X(700), dy = y - X(560);
      final rr = math.sqrt(dx * dx + dy * dy);
      final inHandle = rr <= 120 * s && rr >= 62 * s && x > X(640);
      // الطبق
      final inSaucer = _inRoundRect(x, y, X(170), X(790), X(770), X(840), 26 * s);
      // البخار
      bool steam(double cx) {
        final yy = (y - X(170)) / s;
        if (yy < 0 || yy > 190) return false;
        final sx = X(cx + 26 * math.sin(yy / 190 * 2 * math.pi));
        return (x - sx).abs() <= 22 * s;
      }

      if (inCup || inTopBar || inHandle || inSaucer || steam(370) || steam(470) || steam(570)) {
        im.setPixelRgba(x, y, _white.r.toInt(), _white.g.toInt(), _white.b.toInt(), 255);
      }
      // نقطة الـ QR الكهرمانية
      final qx = x - X(800), qy = y - X(800);
      if (qx * qx + qy * qy <= (150 * s) * (150 * s)) {
        im.setPixelRgba(x, y, _amber.r.toInt(), _amber.g.toInt(), _amber.b.toInt(), 255);
        final lx = (x - X(700)) / s, ly = (y - X(700)) / s;
        // مربعات QR صغيرة بيضا
        final cell = 40.0;
        final cxI = (lx / cell).floor(), cyI = (ly / cell).floor();
        const pattern = {'1,1', '1,2', '2,1', '3,3', '2,3', '3,1', '1,3'};
        if (pattern.contains('$cxI,$cyI') && (lx % cell) > 5 && (ly % cell) > 5) {
          im.setPixelRgba(x, y, 255, 255, 255, 255);
        }
      }
    }
  }
  return im;
}

void _save(img.Image src, String path, int size) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(img.copyResize(src, width: size, height: size, interpolation: img.Interpolation.average)));
}

void main() {
  final full = _draw(background: true);
  final fg = _draw(background: false, scale: 0.62);
  _save(full, 'assets/icon/app_icon.png', 1024);
  _save(fg, 'assets/icon/app_icon_foreground.png', 1024);
  for (final sz in [32, 180, 192, 512]) {
    _save(full, 'firebase/public/icon-$sz.png', sz);
  }
  stdout.writeln('icons ok');
}
