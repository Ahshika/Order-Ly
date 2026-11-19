// بيعمل أصوات الإشعارات (WAV) بالحساب: نغمات بسيطة من غير أي ملفات صوت لحد تاني (مفيش حقوق ملكية).
// كل نوع إشعار ليه صوت مختلف عشان الويتر يعرف من غير ما يبص (طلب جديد، ترابيزة بتنادي، تحويل...).
// التشغيل (من فولدر source):  dart run tool/make_sounds.dart
// بيكتب في assets/sounds/ (للكمبيوتر وجوه التطبيق) وفي android/app/src/main/res/raw/ (صوت إشعار أندرويد).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _rate = 44100;

/// نغمة "جرس": أساسي + هارمونيات بتخفت بسرعة.
List<double> bell(double freq, double seconds, {double decay = 5}) => List.generate((seconds * _rate).round(), (i) {
      final t = i / _rate;
      final env = exp(-decay * t) * min(1, t * 400); // بداية ناعمة من غير "طقّة"
      return env * (sin(2 * pi * freq * t) + 0.45 * sin(2 * pi * freq * 2 * t) + 0.2 * sin(2 * pi * freq * 3.01 * t)) / 1.65;
    });

/// نغمة قصيرة واضحة (بلِيب).
List<double> beep(double freq, double seconds) => List.generate((seconds * _rate).round(), (i) {
      final t = i / _rate;
      final env = min(1.0, min(t * 300, (seconds - t) * 60));
      return env * (0.8 * sin(2 * pi * freq * t) + 0.2 * sin(2 * pi * freq * 2 * t));
    });

/// صوت تنبيه غلط: نغمة واطية خشنة.
List<double> buzz(double freq, double seconds) => List.generate((seconds * _rate).round(), (i) {
      final t = i / _rate;
      final env = min(1.0, min(t * 200, (seconds - t) * 40));
      final s = sin(2 * pi * freq * t);
      return env * (s.sign * 0.35 + s * 0.45);
    });

List<double> silence(double seconds) => List.filled((seconds * _rate).round(), 0);

List<double> seq(List<List<double>> parts) => [for (final p in parts) ...p];

Uint8List wav(List<double> samples, {double volume = 0.85}) {
  final peak = samples.fold<double>(0, (m, s) => max(m, s.abs()));
  final scale = peak == 0 ? 0 : volume / peak;
  final data = ByteData(44 + samples.length * 2);
  void str(int o, String s) => s.codeUnits.asMap().forEach((i, c) => data.setUint8(o + i, c));
  str(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, _rate, Endian.little);
  data.setUint32(28, _rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i] * scale * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  final sounds = <String, List<double>>{
    // طلب جديد من موبايل عميل: تلات نغمات طالعة، مرتين
    'order_new': seq([beep(1047, .11), beep(1319, .11), beep(1568, .2), silence(.12), beep(1047, .11), beep(1319, .11), beep(1568, .24)]),
    // ترابيزة بتنادي الويتر أو عايزة الحساب: دينج دونج
    'table_call': seq([bell(784, .45, decay: 4), bell(659, .7, decay: 3.5)]),
    // عميل حوّل فلوس: نغمتين عاليتين سريعتين ونغمة أعلى
    'payment': seq([beep(1760, .08), silence(.04), beep(1760, .08), silence(.05), beep(2093, .22)]),
    // الطلب جاهز للتقديم: أربيجيو مبهج
    'order_ready': seq([bell(1319, .18, decay: 7), bell(1568, .18, decay: 7), bell(2093, .5, decay: 4)]),
    // طلب جديد للبار/المطبخ: جرس مرتين
    'kitchen_new': seq([bell(880, .5, decay: 4), bell(880, .7, decay: 3)]),
    // مشكلة (الطباعة فشلت): بز واطي مرتين
    'problem': seq([buzz(220, .25), silence(.12), buzz(196, .35)]),
  };
  final assets = Directory('assets/sounds')..createSync(recursive: true);
  final raw = Directory('android/app/src/main/res/raw')..createSync(recursive: true);
  for (final e in sounds.entries) {
    final bytes = wav(e.value);
    File('${assets.path}/${e.key}.wav').writeAsBytesSync(bytes);
    File('${raw.path}/${e.key}.wav').writeAsBytesSync(bytes);
    stdout.writeln('${e.key}.wav  ${(e.value.length / _rate).toStringAsFixed(2)}s  ${bytes.length ~/ 1024} KB');
  }
  // R8 ممكن يشيل الأصوات من النسخة النهائية لأن مفيش كود بيشاور عليها مباشرة
  File('android/app/src/main/res/raw/keep.xml').writeAsStringSync(
      '<?xml version="1.0" encoding="utf-8"?>\n<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@raw/*,@drawable/ic_stat_orderly" />\n');
}
