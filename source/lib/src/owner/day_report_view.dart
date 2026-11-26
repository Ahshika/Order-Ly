import '../core/format.dart';

/// تقرير اليوم (routes_day_reports.dart في السيرفر) مترتب أقسام: نفس الترتيب في شاشة المالك وفي الـ PDF.
class ReportSection {
  const ReportSection(this.title, this.rows, {this.note});
  final String title;
  final List<(String, String)> rows;
  final String? note;
}

const _types = {'dine_in': 'صالة', 'takeaway': 'تيك أواي', 'delivery': 'ديليفري'};
const _sources = {'cashier': 'الكاشير', 'waiter': 'الويتر', 'qr': 'العميل (QR)'};

String _m(Object? cents) => money(cents is int ? cents : 0);

String _time(Object? iso) {
  final d = iso is String ? DateTime.tryParse(iso) : null;
  return d == null ? '-' : formatTime(d.toLocal());
}

String drawerText(Object? diff) {
  if (diff is! int) return '-';
  if (diff == 0) return 'مظبوط';
  return diff > 0 ? 'زيادة ${money(diff)}' : 'ناقص ${money(-diff)}';
}

List<ReportSection> dayReportSections(Map<String, dynamic> r) {
  final s = (r['sales'] as Map?) ?? const {};
  final cash = (r['cash'] as Map?) ?? const {};
  final exp = (r['expenses'] as Map?) ?? const {};
  final voids = (r['voids'] as Map?) ?? const {};
  final fb = (r['feedback'] as Map?) ?? const {};
  final hours = (r['hours'] as Map?) ?? const {};
  final byHour = (r['byHour'] as List? ?? const []).cast<int>();
  final busiest = byHour.isEmpty ? -1 : byHour.indexOf(byHour.reduce((a, b) => a > b ? a : b));
  return [
    ReportSection('المبيعات', [
      ('الإجمالي', _m(s['totalCents'])),
      ('عدد الحسابات', '${s['checks'] ?? 0}'),
      ('متوسط الحساب', _m(s['avgCheckCents'])),
      ('قبل الخدمة والضريبة', _m(s['subtotalCents'])),
      if ((s['discountCents'] ?? 0) != 0) ('الخصومات (${s['discountedChecks'] ?? 0} حساب)', _m(s['discountCents'])),
      if ((s['serviceCents'] ?? 0) != 0) ('الخدمة', _m(s['serviceCents'])),
      if ((s['taxCents'] ?? 0) != 0) ('الضريبة', _m(s['taxCents'])),
      if ((s['deliveryCents'] ?? 0) != 0) ('التوصيل', _m(s['deliveryCents'])),
      if ((s['pointsUsed'] ?? 0) != 0) ('نقط اتصرفت', '${s['pointsUsed']}'),
      if ((s['costCents'] ?? 0) != 0) ('تكلفة الأصناف', _m(s['costCents'])),
      if ((s['costCents'] ?? 0) != 0) ('مكسب تقريبي', _m(s['grossProfitCents'])),
      if ((s['guests'] ?? 0) != 0) ('عدد الضيوف', '${s['guests']}'),
    ]),
    ReportSection('الدرج', [
      ('المفروض يبقى فيه', _m(cash['expectedCents'])),
      ('اتعدّ', _m(cash['countedCents'])),
      ('الفرق', drawerText(cash['diffCents'])),
    ]),
    ReportSection('طرق الدفع', [for (final m in (r['byMethod'] as List? ?? const [])) ('${m['name']} (${m['count']})', _m(m['amountCents']))]),
    ReportSection('نوع الحساب', [for (final t in (r['byType'] as List? ?? const [])) ('${_types[t['type']] ?? t['type']} (${t['count']})', _m(t['amountCents']))]),
    ReportSection('الطلبات جت منين', [for (final t in (r['bySource'] as List? ?? const [])) (_sources[t['source']] ?? '${t['source']}', '${t['orders']} طلب')]),
    ReportSection('المصروفات', [
      for (final e in (exp['byCategory'] as List? ?? const [])) ('${e['name']} (${e['count']})', _m(e['amountCents'])),
      if ((exp['totalCents'] ?? 0) != 0) ('الإجمالي', _m(exp['totalCents'])),
    ]),
    ReportSection('المرتجعات والإلغاء', [
      ('أصناف اتلغت (${voids['count'] ?? 0})', _m(voids['amountCents'])),
      if ((voids['checks'] ?? 0) != 0) ('حسابات اتلغت (${voids['checks']})', _m(voids['checksAmountCents'])),
      for (final v in (voids['items'] as List? ?? const []))
        ('${v['qty']}× ${v['name']} • ${v['by'] ?? '-'}${(v['reason'] ?? '').toString().isEmpty ? '' : ' • ${v['reason']}'}', _m(v['amountCents'])),
    ]),
    ReportSection('أكتر الأصناف', [for (final i in (r['top'] as List? ?? const [])) ('${i['qty']}× ${i['name']}', _m(i['revenueCents']))]),
    ReportSection('الورديات', [
      for (final sh in (r['shifts'] as List? ?? const []))
        (
          '${_time(sh['openedAt'])} - ${sh['closedAt'] == null ? 'لسه مفتوحة' : _time(sh['closedAt'])} • ${sh['openedBy'] ?? ''}${sh['spansDays'] == true ? ' • داخلة على يومين' : ''}',
          '${_m(sh['salesCents'])} • الدرج ${drawerText(sh['diffCents'])}',
        ),
    ]),
    ReportSection('تاني', [
      if (busiest >= 0 && byHour[busiest] > 0) ('أكتر ساعة بيع', '${busiest.toString().padLeft(2, '0')}:00 (${_m(byHour[busiest])})'),
      if ((fb['count'] ?? 0) != 0) ('تقييم العملاء', '${fb['avg']} من 5 (${fb['count']})'),
      if (r['open'] is Map && ((r['open'] as Map)['n'] ?? 0) != 0) ('حسابات لسه مفتوحة', '${(r['open'] as Map)['n']} • ${_m((r['open'] as Map)['t'])}'),
      if ((r['lowStock'] ?? 0) != 0) ('أصناف المخزن قربت تخلص', '${r['lowStock']}'),
      ('ساعات الشغل', '${hours['open'] ?? '00:00'} - ${hours['close'] ?? '00:00'}'),
    ]),
  ].where((sec) => sec.rows.isNotEmpty).toList();
}
