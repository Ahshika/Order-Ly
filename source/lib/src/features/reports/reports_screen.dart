import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/file_save.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/spreadsheet.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

typedef _Range = ({DateTime from, DateTime to, String label});

final _reportProvider = FutureProvider.autoDispose.family<Json, ({String from, String to})>((ref, r) => apiOf(ref).get('/api/reports/summary', query: {'from': r.from, 'to': r.to}));

final _feedbackProvider = FutureProvider.autoDispose<List<Json>>((ref) async => ((await apiOf(ref).get('/api/feedback'))['feedback'] as List).cast<Json>());

/// تقارير صاحب الكافيه: المبيعات والربح، وساعات الذروة، والأصناف، وهندسة المنيو، والإلغاءات، وتقييمات العملاء.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  late _Range _range = _preset('today');

  static _Range _preset(String k) {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return switch (k) {
      'yesterday' => (from: today.subtract(const Duration(days: 1)), to: today, label: 'امبارح'),
      'week' => (from: today.subtract(const Duration(days: 6)), to: today.add(const Duration(days: 1)), label: 'آخر 7 أيام'),
      'month' => (from: DateTime(n.year, n.month), to: today.add(const Duration(days: 1)), label: 'الشهر ده'),
      'lastMonth' => (from: DateTime(n.year, n.month - 1), to: DateTime(n.year, n.month), label: 'الشهر اللي فات'),
      _ => (from: today, to: today.add(const Duration(days: 1)), label: 'النهارده'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final key = (from: _range.from.toIso8601String(), to: _range.to.toIso8601String());
    final report = ref.watch(_reportProvider(key));
    return Scaffold(
      appBar: AppBar(
        title: const Text('التقارير'),
        actions: [
          if (report.value != null)
            IconButton(tooltip: 'تصدير Excel', onPressed: () => _export(context, report.value!), icon: const Icon(Icons.download_rounded)),
          IconButton(
            tooltip: 'تقييمات العملاء',
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _FeedbackScreen())),
            icon: const Icon(Icons.star_rate_rounded),
          ),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final k in ['today', 'yesterday', 'week', 'month', 'lastMonth'])
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: ChoiceChip(label: Text(_preset(k).label), selected: _range.label == _preset(k).label, onSelected: (_) => setState(() => _range = _preset(k))),
              ),
            ActionChip(
              avatar: const Icon(Icons.date_range_rounded, size: 18),
              label: const Text('فترة تانية'),
              onPressed: () async {
                final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now());
                if (r != null) {
                  setState(() => _range = (from: r.start, to: r.end.add(const Duration(days: 1)), label: '${formatDate(r.start)} - ${formatDate(r.end)}'));
                }
              },
            ),
          ]),
        ),
        Expanded(child: AsyncBody(value: report, onRetry: () => ref.invalidate(_reportProvider(key)), builder: (r) => _Body(r: r))),
      ]),
    );
  }

  Future<void> _export(BuildContext context, Json r) async {
    double p(Object? c) => ((c as num?) ?? 0) / 100;
    try {
      final w = XlsxWriter()
        ..addSheet('الملخص', [
          ['البند', 'القيمة'],
          ['الفترة', _range.label],
          ['عدد الحسابات', r['checks']],
          ['المبيعات (الإجمالي)', p(r['totalCents'])],
          ['الخصومات', p(r['discountCents'])],
          ['الخدمة', p(r['serviceCents'])],
          ['الضريبة', p(r['taxCents'])],
          ['تكلفة الخامات', p(r['costCents'])],
          ['مجمل الربح', p(r['grossProfitCents'])],
          ['المصروفات', p(r['expensesCents'])],
          ['الهالك', p(r['wasteCents'])],
          ['صافي الربح', p(r['netCents'])],
          ['متوسط الحساب', p(r['avgCheckCents'])],
        ])
        ..addSheet('الأصناف', [
          ['الصنف', 'الكمية', 'المبيعات', 'التكلفة', 'الربح'],
          for (final i in (r['items'] as List).cast<Json>()) [i['name'], i['qty'], p(i['revenueCents']), p(i['costCents']), p(i['profitCents'])],
        ])
        ..addSheet('طرق الدفع', [
          ['الطريقة', 'العدد', 'المبلغ'],
          for (final m in (r['byMethod'] as List).cast<Json>()) [m['name'], m['count'], p(m['amountCents'])],
        ])
        ..addSheet('يوم بيوم', [
          ['اليوم', 'المبيعات'],
          for (final d in (r['byDay'] as List).cast<Json>()) [d['day'], p(d['amountCents'])],
        ])
        ..addSheet('الإلغاءات', [
          ['الصنف', 'الكمية', 'القيمة', 'السبب', 'مين'],
          for (final v in (r['voids'] as List).cast<Json>()) [v['name'], v['qty'], p(v['amountCents']), v['reason'], v['userName']],
        ]);
      final path = await saveOrShareFile(w.build(), 'تقرير Order Ly - ${latinDigits(_range.label).replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')}.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      if (path != null && context.mounted) showMessage(context, 'اتحفظ: $path');
    } catch (e) {
      if (context.mounted) showMessage(context, 'مشكلة في التصدير: $e', error: true);
    }
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.r});
  final Json r;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final items = (r['items'] as List).cast<Json>();
    final eng = (r['engineering'] as List).cast<Json>();
    final byHour = (r['byHour'] as List).cast<int>();
    final low = (r['lowStock'] as List).cast<Json>();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        _Kpi('المبيعات', money(r['totalCents'] as int), Icons.payments_rounded, highlight: true),
        _Kpi('صافي الربح', money(r['netCents'] as int), Icons.savings_rounded),
        _Kpi('الحسابات', '${r['checks']}', Icons.receipt_long_rounded),
        _Kpi('متوسط الحساب', money(r['avgCheckCents'] as int), Icons.functions_rounded),
        if ((r['guests'] as int) > 0) _Kpi('الزباين', '${r['guests']}', Icons.groups_rounded),
        if (r['prepMinutes'] != null) _Kpi('متوسط التحضير', '${(r['prepMinutes'] as num).toStringAsFixed(1)} د', Icons.timer_outlined),
        if (r['stayMinutes'] != null) _Kpi('متوسط القعدة', '${(r['stayMinutes'] as num).round()} د', Icons.event_seat_outlined),
        if (r['ratingAvg'] != null) _Kpi('تقييم العملاء', '${(r['ratingAvg'] as num).toStringAsFixed(1)} ★ (${r['ratingCount']})', Icons.star_rounded),
      ]),
      const SectionTitle('الربح'),
      Card(
        child: Column(children: [
          _row('المبيعات قبل الخدمة والضريبة', r['subtotalCents']),
          _row('الخصومات', r['discountCents'], negative: true),
          _row('تكلفة الخامات', r['costCents'], negative: true),
          _row('مجمل الربح', r['grossProfitCents'], bold: true),
          _row('المصروفات', r['expensesCents'], negative: true),
          _row('الهالك', r['wasteCents'], negative: true),
          _row('صافي الربح', r['netCents'], bold: true),
          const Divider(height: 1),
          _row('الخدمة (للعمال)', r['serviceCents']),
          _row('الضريبة', r['taxCents']),
        ]),
      ),
      const SectionTitle('ساعات الذروة'),
      Card(child: Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 8), child: _HourBars(values: byHour))),
      const SectionTitle('طرق الدفع ومصدر الطلبات'),
      Wrap(spacing: 10, runSpacing: 10, children: [
        SizedBox(
          width: 360,
          child: Card(
            child: Column(children: [
              for (final m in (r['byMethod'] as List).cast<Json>()) ListTile(dense: true, title: Text('${m['name']}'), subtitle: Text('${m['count']} دفعة'), trailing: Text(money(m['amountCents'] as int))),
              if ((r['byMethod'] as List).isEmpty) const ListTile(title: Text('مفيش')),
            ]),
          ),
        ),
        SizedBox(
          width: 360,
          child: Card(
            child: Column(children: [
              for (final s in (r['bySource'] as List).cast<Json>())
                ListTile(dense: true, title: Text(orderSourceLabels[s['source']] ?? '${s['source']}'), subtitle: Text('${s['orders']} طلب'), trailing: Text(money(s['amountCents'] as int))),
              if ((r['qrRejected'] as int) > 0) ListTile(dense: true, title: const Text('طلبات QR اترفضت'), trailing: Text('${r['qrRejected']}')),
            ]),
          ),
        ),
      ]),
      const SectionTitle('الأصناف الأكتر مبيعاً'),
      Card(
        child: Column(children: [
          for (final i in items.take(15))
            ListTile(
              dense: true,
              title: Text('${i['name']}'),
              subtitle: Text('ربح ${money(i['profitCents'] as int)}'),
              trailing: Text('${i['qty']} • ${money(i['revenueCents'] as int)}'),
            ),
          if (items.isEmpty) const ListTile(title: Text('مفيش مبيعات في الفترة دي')),
        ]),
      ),
      if (eng.isNotEmpty) ...[
        const SectionTitle('هندسة المنيو'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('كل صنف متقسم حسب البيع والربح مقارنة بالمتوسط:', style: text.bodySmall),
              const SizedBox(height: 8),
              for (final c in const [
                ('star', '⭐ نجوم: بتتباع كتير وربحها عالي (حافظ عليها في أول المنيو)'),
                ('plowhorse', '🐎 شغالة: بتتباع كتير وربحها قليل (ارفع السعر شوية أو قلل التكلفة)'),
                ('puzzle', '🧩 لغز: ربحها عالي بس مش بتتباع (اعرضها أكتر أو اقترحها مع أصناف تانية)'),
                ('dog', '🐕 ضعيفة: قليلة البيع والربح (فكّر تشيلها)'),
              ])
                if (eng.any((e) => e['class'] == c.$1)) ...[
                  Text(c.$2, style: const TextStyle().semiBold),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, top: 2),
                    child: Text(eng.where((e) => e['class'] == c.$1).map((e) => '${e['name']} (${e['qty']})').join('، ')),
                  ),
                ],
            ]),
          ),
        ),
      ],
      if ((r['byStaff'] as List).isNotEmpty) ...[
        const SectionTitle('الموظفين'),
        Card(
          child: Column(children: [
            for (final s in (r['byStaff'] as List).cast<Json>()) ListTile(dense: true, title: Text('${s['name']}'), subtitle: Text('${s['orders']} طلب'), trailing: Text(money(s['amountCents'] as int))),
          ]),
        ),
      ],
      if ((r['voids'] as List).isNotEmpty) ...[
        const SectionTitle('الإلغاءات'),
        Card(
          child: Column(children: [
            for (final v in (r['voids'] as List).cast<Json>().take(30))
              ListTile(dense: true, title: Text('${v['qty']}× ${v['name']} • ${money(v['amountCents'] as int)}'), subtitle: Text('${v['reason'] ?? ''} • ${v['userName'] ?? ''}')),
          ]),
        ),
      ],
      if (low.isNotEmpty) ...[
        const SectionTitle('خامات قربت تخلص'),
        Card(child: Column(children: [for (final l in low) ListTile(dense: true, leading: const Icon(Icons.warning_amber_rounded), title: Text('${l['name']}'), trailing: Text('${l['qty']}'))])),
      ],
    ]);
  }

  Widget _row(String label, Object? cents, {bool bold = false, bool negative = false}) => ListTile(
        dense: true,
        title: Text(label, style: bold ? const TextStyle().bold : null),
        trailing: Text('${negative && (cents as int) > 0 ? '- ' : ''}${money(cents as int)}', style: bold ? const TextStyle().bold : null),
      );
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.icon, {this.highlight = false});
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: Card(
        color: highlight ? scheme.primaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                Text(value, style: Theme.of(context).textTheme.titleMedium?.bold),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// أعمدة المبيعات لكل ساعة.
class _HourBars extends StatelessWidget {
  const _HourBars({required this.values});
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final maxV = values.fold(0, math.max);
    final scheme = Theme.of(context).colorScheme;
    // نعرض بس من أول ساعة فيها بيع لآخر ساعة
    final first = values.indexWhere((v) => v > 0);
    final last = values.lastIndexWhere((v) => v > 0);
    if (maxV == 0) return const SizedBox(height: 60, child: Center(child: Text('مفيش مبيعات')));
    return SizedBox(
      height: 150,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var h = first; h <= last; h++)
            Expanded(
              child: Tooltip(
                message: '${h}:00 • ${money(values[h])}',
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Container(
                    height: 110 * values[h] / maxV + 2,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: values[h] == maxV ? brandAccent : scheme.primary.withValues(alpha: 0.75),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${h % 12 == 0 ? 12 : h % 12}', style: const TextStyle(fontSize: 10)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

class _FeedbackScreen extends ConsumerWidget {
  const _FeedbackScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('تقييمات العملاء')),
        body: AsyncBody(
          value: ref.watch(_feedbackProvider),
          builder: (list) => list.isEmpty
              ? const EmptyState(icon: Icons.star_outline_rounded, text: 'العملاء بيقيّموا من موبايلهم بعد ما يدفعوا')
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final f in list)
                    Card(
                      child: ListTile(
                        leading: Text('${'★' * (f['rating'] as int)}${'☆' * (5 - (f['rating'] as int))}', style: const TextStyle(color: brandAccent, fontSize: 16)),
                        title: Text(f['comment'] as String? ?? 'من غير تعليق'),
                        subtitle: Text([
                          if (f['tableName'] != null) 'ترابيزة ${f['tableName']}',
                          if (f['checkNumber'] != null) 'حساب #${f['checkNumber']}',
                          formatDateTime(parseDate(f['createdAt'])!),
                        ].join(' • ')),
                      ),
                    ),
                ]),
        ),
      );
}
