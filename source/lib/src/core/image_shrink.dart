import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// بيصغّر صورة قبل ما تتبعت للسيرفر (صورة موبايل ممكن تبقى 10-20 ميجا).
/// الشغل كله في Isolate منفصل عشان الشاشة ما تقفش. لو الملف مش صورة بيرجع زي ما هو والسيرفر يرفضه برسالة واضحة.
Future<Uint8List> shrinkForUpload(Uint8List bytes, {int maxSide = 1600, int quality = 85}) async {
  final out = await Isolate.run(() => _shrink(bytes, maxSide, quality));
  return out ?? bytes;
}

/// لوجو صغير PNG (بيحافظ على الخلفية الشفافة). null لو الملف مش صورة.
Future<Uint8List?> logoForUpload(Uint8List bytes) => Isolate.run(() => _logo(bytes));

Uint8List? _shrink(Uint8List bytes, int maxSide, int quality) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var image = decoded;
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height ? img.copyResize(image, width: maxSide) : img.copyResize(image, height: maxSide);
  }
  return img.encodeJpg(image, quality: quality);
}

Uint8List? _logo(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final small = decoded.width > 512 ? img.copyResize(decoded, width: 512) : decoded;
  return img.encodePng(small);
}
