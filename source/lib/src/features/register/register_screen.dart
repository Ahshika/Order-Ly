import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';

const _typeLabels = {
  'sale': 'بيع',
  'expense': 'مصروف',
  'deposit': 'إيداع',
  'withdraw': 'سحب',
  'refund': 'مرتجع',
  'purchase': 'مشتريات',
  'supplier': 'دفع لمورد',
};

/// الدرج (الوردية): فتح بالفلوس اللي في الدرج، والمصاريف، والقفل آخر اليوم بالمقارنة بين المتوقع والفعلي.
class RegisterScreen extends ConsumerWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(registerProvider);
    final user = ref.watch(sessionProvider).value!.user!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الدرج'),
        actions: [
          if (user.isOwner)
            TextButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _HistoryScreen())),
              icon: const Icon(Icons.history_rounded),
              label: const Text('الورديات القديمة'),
            ),
        ],
      ),
      body: AsyncBody(
        value: data,
        onRetry: () => ref.invalidate(registerProvider),
        builder: (r) {
          final session = r['session'] as Map<String, dynamic>?;
          if (session == null) return _Closed(lastKept: r['lastKeptCashCents'] as int?);
          return _Open(session: session, moves: (r['moves'] as List).cast<Json>(), openChecks: r['openChecks'] as int? ?? 0);
        },
      ),
    );
  }
}

class _Closed extends ConsumerStatefulWidget {
  const _Closed({this.lastKept});
  final int? lastKept;

  @override
  ConsumerState<_Closed> createState() => _ClosedState();
}

class _ClosedState extends ConsumerState<_Closed> {
  late final _cash = TextEditingController(text: widget.lastKept == null ? '' : moneyInput(widget.lastKept!));
  bool _busy = false;

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CenteredPanel(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.point_of_sale_rounded, size: 48, color: brandPrimary),
              const SizedBox(height: 8),
              Text('الدرج مقفول', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.bold),
              const SizedBox(height: 4),
              const Text('افتح الوردية عشان تقدر تحصّل فلوس وتستقبل طلبات الـ QR.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              MoneyField(controller: _cash, label: 'الفلوس اللي في الدرج دلوقتي (الفكة)'),
              const SizedBox(height: 16),
              BusyButton(
                label: 'افتح الوردية',
                icon: Icons.lock_open_rounded,
                busy: _busy,
                onPressed: () async {
                  setState(() => _busy = true);
                  try {
                    await ref.read(sessionProvider).value!.api!.post('/api/register/open', {'openingCashCents': parseMoney(_cash.text) ?? 0});
                    ref.invalidate(registerProvider);
                  } catch (e) {
                    if (context.mounted) showMessage(context, errorText(e), error: true);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
              ),
            ]),
          ),
        ),
      );
}

class _Open extends ConsumerWidget {
  const _Open({required this.session, required this.moves, required this.openChecks});
  final Map<String, dynamic> session;
  final List<Json> moves;
  final int openChecks;

  Future<void> _move(BuildContext context, WidgetRef ref, String type) async {
    final res = await showDialog<Map<String, Object?>>(context: context, builder: (_) => _MoveDialog(type: type));
    if (res == null) return;
    try {
      await ref.read(sessionProvider).value!.api!.post('/api/register/moves', res);
      ref.invalidate(registerProvider);
    } catch (e) {
      if (context.mounted) showMessage(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byMethod = (session['byMethod'] as Map? ?? const {}).cast<String, int>();
    final text = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _Kpi(label: 'الكاش المتوقع في الدرج', value: money(session['expectedCashCents'] as int? ?? 0), icon: Icons.payments_rounded, highlight: true),
        _Kpi(label: 'مبيعات الوردية', value: money(session['salesCents'] as int? ?? 0), icon: Icons.trending_up_rounded),
        _Kpi(label: 'حسابات اتقفلت', value: '${session['checksClosed'] ?? 0}', icon: Icons.receipt_long_rounded),
        _Kpi(label: 'فكة البداية', value: money(session['openingCashCents'] as int? ?? 0), icon: Icons.savings_outlined),
      ]),
      const SizedBox(height: 12),
      Text('اتفتحت ${formatDateTime(parseDate(session['openedAt'])!)} بواسطة ${session['openedBy'] ?? ''}', style: text.bodySmall),
      const SectionTitle('حسب طريقة الدفع'),
      Card(
        child: Column(children: [
          for (final e in byMethod.entries)
            ListTile(dense: true, title: Text(payKindLabels[e.key] ?? e.key), trailing: Text(money(e.value), style: const TextStyle().semiBold)),
          if (byMethod.isEmpty) const ListTile(title: Text('لسه مفيش حركة')),
        ]),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(onPressed: () => _move(context, ref, 'expense'), icon: const Icon(Icons.remove_circle_outline_rounded), label: const Text('مصروف')),
        FilledButton.tonalIcon(onPressed: () => _move(context, ref, 'deposit'), icon: const Icon(Icons.add_circle_outline_rounded), label: const Text('إيداع في الدرج')),
        FilledButton.tonalIcon(onPressed: () => _move(context, ref, 'withdraw'), icon: const Icon(Icons.outbox_rounded), label: const Text('سحب من الدرج')),
        FilledButton.icon(
          onPressed: () async {
            if (openChecks > 0 && !await confirmDialog(context, 'فيه $openChecks حساب لسه مفتوح. تقفل الوردية برضه؟')) return;
            if (!context.mounted) return;
            await showDialog<void>(context: context, builder: (_) => _CloseDialog(expected: session['expectedCashCents'] as int? ?? 0));
            ref.invalidate(registerProvider);
          },
          icon: const Icon(Icons.lock_rounded),
          label: const Text('قفل الوردية'),
        ),
      ]),
      const SectionTitle('الحركة'),
      Card(
        child: Column(children: [
          for (final m in moves)
            ListTile(
              dense: true,
              leading: Icon((m['amountCents'] as int) >= 0 ? Icons.south_west_rounded : Icons.north_east_rounded,
                  color: (m['amountCents'] as int) >= 0 ? const Color(0xFF16A34A) : Theme.of(context).colorScheme.error),
              title: Text('${_typeLabels[m['type']] ?? m['type']}${m['category'] != null ? ' • ${m['category']}' : ''}${m['note'] != null ? ' • ${m['note']}' : ''}'),
              subtitle: Text('${payKindLabels[m['method']] ?? m['method']} • ${formatTime(parseDate(m['createdAt'])!)} • ${m['userName'] ?? ''}'),
              trailing: Text(money(m['amountCents'] as int), style: const TextStyle().semiBold),
            ),
          if (moves.isEmpty) const ListTile(title: Text('لسه مفيش حركة')),
        ]),
      ),
    ]);
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.icon, this.highlight = false});
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 220,
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

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({required this.type});
  final String type;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _category;
  static const _expenseCats = ['خامات', 'نضافة', 'صيانة', 'مرتبات', 'إيجار', 'كهربا ومية', 'نت', 'تانية'];

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_typeLabels[widget.type]!),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MoneyField(controller: _amount, label: 'المبلغ', autofocus: true),
            if (widget.type == 'expense') ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in _expenseCats) ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
              ]),
            ],
            const SizedBox(height: 10),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final cents = parseMoney(_amount.text);
              if (cents == null || cents <= 0) return;
              Navigator.pop(context, {'type': widget.type, 'amountCents': cents, 'category': _category, 'note': _note.text});
            },
            child: const Text('تسجيل'),
          ),
        ],
      );
}

class _CloseDialog extends ConsumerStatefulWidget {
  const _CloseDialog({required this.expected});
  final int expected;

  @override
  ConsumerState<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends ConsumerState<_CloseDialog> {
  final _counted = TextEditingController();
  final _kept = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _counted.dispose();
    _kept.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_result != null) {
      final diff = (_result!['countedCashCents'] as int) - (_result!['expectedCashCents'] as int);
      return AlertDialog(
        title: const Text('الوردية اتقفلت'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('المبيعات: ${money(_result!['salesCents'] as int)}'),
          Text('المتوقع: ${money(_result!['expectedCashCents'] as int)}'),
          Text('الفعلي: ${money(_result!['countedCashCents'] as int)}'),
          const SizedBox(height: 8),
          Text(diff == 0 ? 'الدرج مظبوط ✔' : diff > 0 ? 'زيادة ${money(diff)}' : 'عجز ${money(-diff)}',
              style: Theme.of(context).textTheme.titleMedium?.bold.copyWith(color: diff < 0 ? Theme.of(context).colorScheme.error : const Color(0xFF16A34A))),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('تمام'))],
      );
    }
    final counted = parseMoney(_counted.text);
    return AlertDialog(
      title: const Text('قفل الوردية'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('الكاش المتوقع: ${money(widget.expected)}', style: const TextStyle().semiBold),
          const SizedBox(height: 12),
          MoneyField(controller: _counted, label: 'عدّيت كام في الدرج؟', autofocus: true, onChanged: (_) => setState(() {})),
          if (counted != null && _counted.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(counted == widget.expected ? 'مظبوط ✔' : counted > widget.expected ? 'زيادة ${money(counted - widget.expected)}' : 'عجز ${money(widget.expected - counted)}'),
          ],
          const SizedBox(height: 10),
          MoneyField(controller: _kept, label: 'هتسيب كام فكة للوردية الجاية؟'),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(
          width: 140,
          child: BusyButton(
            label: 'اقفل',
            busy: _busy,
            onPressed: counted == null || _counted.text.isEmpty
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      final res = await ref.read(sessionProvider).value!.api!.post('/api/register/close', {
                        'countedCashCents': counted,
                        'keptCashCents': parseMoney(_kept.text) ?? 0,
                        'note': _note.text,
                      });
                      setState(() => _result = res['closed'] as Map<String, dynamic>);
                    } catch (e) {
                      if (context.mounted) showMessage(context, errorText(e), error: true);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
        ),
      ],
    );
  }
}

final _historyProvider = FutureProvider.autoDispose<List<Json>>((ref) async => ((await apiOf(ref).get('/api/register/history'))['sessions'] as List).cast<Json>());

class _HistoryScreen extends ConsumerWidget {
  const _HistoryScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('الورديات')),
        body: AsyncBody(
          value: ref.watch(_historyProvider),
          builder: (list) => ListView(padding: const EdgeInsets.all(16), children: [
            for (final s in list)
              Card(
                child: ListTile(
                  title: Text('${formatDateTime(parseDate(s['openedAt'])!)} ← ${s['closedAt'] == null ? 'مفتوحة' : formatTime(parseDate(s['closedAt'])!)}'),
                  subtitle: Text([
                    'المبيعات ${money(s['salesCents'] as int? ?? 0)}',
                    if (s['countedCashCents'] != null) 'الفرق ${money((s['countedCashCents'] as int) - (s['expectedCashCents'] as int))}',
                    '${s['openedBy'] ?? ''}${s['closedBy'] != null ? ' / ${s['closedBy']}' : ''}',
                  ].join(' • ')),
                ),
              ),
          ]),
        ),
      );
}
