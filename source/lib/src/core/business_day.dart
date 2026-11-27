/// يوم الشغل: كل حاجة في البرنامج "النهارده" بتاعها محسوب بيه (ترقيم الطلبات، التقارير، ملخص الفروع).
///
/// الكافيه بيحدد ساعات شغله (من / لـ)، أو "24 ساعة" وساعة نهاية اليوم. اليوم بيتقفل عند دقيقة واحدة
/// ثابتة ([cutoff]) بتقع في وسط الوقت اللي الكافيه قافل فيه، فكل يوم شغل بيقع كله في تاريخ واحد:
/// - من 09:00 لـ 21:00 ← اليوم بيتقفل 03:00 (وأي بيع متأخر لحد 3 الفجر على نفس اليوم).
/// - من 21:00 لـ 03:00 ← اليوم بيتقفل 12:00 الضهر (السهرة كلها على تاريخ الليلة اللي بدأت فيها).
/// - 24 ساعة واليوم بيخلص 06:00 ← اليوم من 06:00 لـ 06:00.
/// - 00:00 لـ 00:00 (الافتراضي) ← زي الأول بالظبط: من 12 بالليل لـ 12 بالليل.
///
/// تاريخ اليوم = التاريخ اللي اليوم بدأ فيه. الحساب بالساعة المحلية، فيوم تغيير الساعة الصيفي بيبقى 23 أو 25 ساعة.
library;

class BusinessDay {
  const BusinessDay({this.open = 0, this.close = 0});

  /// من إعدادات الكافيه ('HH:MM')، وأي قيمة مش صحيحة = 00:00.
  factory BusinessDay.fromSettings(Object? open, Object? close) => BusinessDay(open: parseMinutes(open) ?? 0, close: parseMinutes(close) ?? 0);

  /// دقيقة الفتح ودقيقة القفل من أول اليوم (0..1439). لو متساويين = 24 ساعة.
  final int open;
  final int close;

  bool get allDay => open == close;

  /// الدقيقة اللي يوم الشغل بيتقفل ويبدأ اللي بعده عندها.
  int get cutoff {
    if (allDay) return close;
    final closedFor = (open - close + 1440) % 1440;
    return (close + closedFor ~/ 2) % 1440;
  }

  /// بداية يوم الشغل اللي تاريخه [date] (بالساعة المحلية).
  DateTime startOf(DateTime date) => DateTime(date.year, date.month, date.day, cutoff ~/ 60, cutoff % 60);

  /// تاريخ يوم الشغل اللي اللحظة دي جواه (من غير ساعة).
  DateTime dateOf(DateTime t) {
    final local = t.toLocal();
    final d = DateTime(local.year, local.month, local.day);
    return local.isBefore(startOf(d)) ? DateTime(d.year, d.month, d.day - 1) : d;
  }

  /// (من، لـ) ليوم الشغل اللي تاريخه [date]: من أول اليوم لأول اليوم اللي بعده.
  (DateTime, DateTime) rangeOf(DateTime date) => (startOf(date), startOf(DateTime(date.year, date.month, date.day + 1)));

  static String keyOf(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static DateTime? parseKey(Object? key) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch('${key ?? ''}');
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  /// 'HH:MM' ← دقايق من أول اليوم، أو null لو مش صحيح.
  static int? parseMinutes(Object? v) {
    final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch('${v ?? ''}');
    return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
  }

  static String formatMinutes(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}
