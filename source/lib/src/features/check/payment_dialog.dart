import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';

/// الدفع: طريقة الدفع، والمبلغ (كله أو جزء)، والكاش اللي العميل إداه والباقي ليه.
/// بيرجع true لو الحساب اتدفع كله واتقفل.
class PaymentDialog extends ConsumerStatefulWidget {
  const PaymentDialog({super.key, required this.detail});
  final CheckDetail detail;

  @override
  ConsumerState<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<PaymentDialog> {
  PayMethod? _method;
  late final _amount = TextEditingController(text: moneyInput(widget.detail.check.dueCents));
  final _received = TextEditingController();
  final _reference = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _received.dispose();
    _reference.dispose();
    super.dispose();
  }

  int get _due => widget.detail.check.dueCents;

  Future<void> _submit() async {
    final amount = parseMoney(_amount.text);
    if (_method == null) return setState(() => _error = 'اختار طريقة الدفع');
    if (amount == null || amount <= 0) return setState(() => _error = 'المبلغ مش صحيح');
    if (amount > _due) return setState(() => _error = 'المبلغ أكبر من الباقي (${money(_due)})');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(sessionProvider).value!.api!.post('/api/checks/${widget.detail.check.id}/payments', {
        'methodId': _method!.id,
        'amountCents': amount,
        if (_reference.text.trim().isNotEmpty) 'reference': _reference.text.trim(),
        'close': amount == _due,
      });
      if (!mounted) return;
      Navigator.pop(context, (res['check'] as Map)['status'] == 'closed');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final methods = (ref.watch(payMethodsProvider).value ?? const []).where((m) => m.active).toList();
    _method ??= methods.where((m) => m.kind == 'cash').firstOrNull;
    final amount = parseMoney(_amount.text) ?? 0;
    final received = parseMoney(_received.text) ?? 0;
    final change = received - amount;
    final text = Theme.of(context).textTheme;
    final c = widget.detail.check;

    // تقسيم سريع بالتساوي
    final guests = (c.guests ?? 0) > 1 ? c.guests! : 0;

    return AlertDialog(
      title: Text('دفع • الباقي ${money(_due)}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in methods)
                ChoiceChip(
                  avatar: Icon(_icon(m.kind), size: 18),
                  label: Text(m.name),
                  selected: _method?.id == m.id,
                  onSelected: (_) => setState(() => _method = m),
                ),
            ]),
            const SizedBox(height: 14),
            MoneyField(controller: _amount, label: 'المبلغ', onChanged: (_) => setState(() {})),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              ActionChip(label: const Text('الباقي كله'), onPressed: () => setState(() => _amount.text = moneyInput(_due))),
              if (guests > 1) ActionChip(label: Text('على $guests بالتساوي'), onPressed: () => setState(() => _amount.text = moneyInput((_due / guests).ceil()))),
              ActionChip(label: const Text('النص'), onPressed: () => setState(() => _amount.text = moneyInput((_due / 2).ceil()))),
            ]),
            if (_method?.kind == 'cash') ...[
              const SizedBox(height: 14),
              MoneyField(controller: _received, label: 'العميل إدّى كام؟ (اختياري)', onChanged: (_) => setState(() {})),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                for (final note in _notesFor(amount)) ActionChip(label: Text(money(note)), onPressed: () => setState(() => _received.text = moneyInput(note))),
              ]),
              if (received > 0) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: change >= 0 ? const Color(0xFF16A34A).withValues(alpha: 0.12) : Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(change >= 0 ? 'الباقي للعميل: ${money(change)}' : 'ناقص ${money(-change)}', style: text.titleMedium?.bold, textAlign: TextAlign.center),
                ),
              ],
            ],
            if (_method != null && _method!.kind != 'cash') ...[
              const SizedBox(height: 10),
              TextField(controller: _reference, decoration: const InputDecoration(labelText: 'رقم العملية (اختياري)')),
            ],
            if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(
          width: 170,
          child: BusyButton(label: amount == _due ? 'دفع وقفل الحساب' : 'تسجيل الدفعة', busy: _busy, onPressed: _submit),
        ),
      ],
    );
  }

  /// فئات الفلوس المناسبة للمبلغ (عشان الكاشير يدوس بسرعة).
  List<int> _notesFor(int amount) {
    if (amount <= 0) return const [];
    final out = <int>{};
    for (final n in [5000, 10000, 20000, 50000, 100000, 200000]) {
      if (n >= amount) out.add(n);
      if (out.length == 3) break;
    }
    final roundUp = ((amount + 999) ~/ 1000) * 1000;
    if (roundUp != amount) out.add(roundUp);
    return out.toList()..sort();
  }

  IconData _icon(String kind) => switch (kind) {
        'cash' => Icons.payments_rounded,
        'card' => Icons.credit_card_rounded,
        'instapay' => Icons.bolt_rounded,
        'wallet' => Icons.account_balance_wallet_rounded,
        _ => Icons.more_horiz_rounded,
      };
}

