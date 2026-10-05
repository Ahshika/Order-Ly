import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../check/check_screen.dart';
import '../printing/print_service.dart';

/// الحسابات: المفتوحة دلوقتي، واللي اتقفلت (بحث بالرقم أو اسم العميل أو الترابيزة).
class ChecksHistoryScreen extends ConsumerStatefulWidget {
  const ChecksHistoryScreen({super.key});

  @override
  ConsumerState<ChecksHistoryScreen> createState() => _ChecksHistoryScreenState();
}

class _ChecksHistoryScreenState extends ConsumerState<ChecksHistoryScreen> {
  String _status = 'closed';
  String _q = '';
  DateTime _day = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final from = DateTime(_day.year, _day.month, _day.day);
    final query = (
      status: _status,
      q: _q,
      from: _status == 'open' || _q.isNotEmpty ? null : from.toUtc().toIso8601String(),
      to: _status == 'open' || _q.isNotEmpty ? null : from.add(const Duration(days: 1)).toUtc().toIso8601String(),
    );
    final checks = ref.watch(checksProvider(query));
    final user = ref.watch(sessionProvider).value!.user!;
    return Scaffold(
      appBar: AppBar(title: const Text('الحسابات')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'open', label: Text('مفتوحة')),
                ButtonSegment(value: 'closed', label: Text('اتقفلت')),
                ButtonSegment(value: 'void', label: Text('ملغية')),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            if (_status != 'open')
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
                  if (d != null) setState(() => _day = d);
                },
                icon: const Icon(Icons.event_rounded),
                label: Text(formatDay(_day)),
              ),
            SizedBox(
              width: 260,
              child: TextField(
                decoration: const InputDecoration(hintText: 'رقم الحساب، العميل، الترابيزة', prefixIcon: Icon(Icons.search_rounded), isDense: true),
                onSubmitted: (v) => setState(() => _q = v.trim()),
              ),
            ),
          ]),
        ),
        Expanded(
          child: AsyncBody(
            value: checks,
            builder: (list) {
              if (list.isEmpty) return const EmptyState(icon: Icons.receipt_long_outlined, text: 'مفيش حسابات');
              final total = list.fold(0, (s, c) => s + c.totalCents);
              return Column(children: [
                if (_status == 'closed') Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('${list.length} حساب • ${money(total)}', style: const TextStyle().semiBold)),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final c = list[i];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(child: Icon(c.type == 'dine_in' ? Icons.table_restaurant_rounded : c.type == 'delivery' ? Icons.delivery_dining_rounded : Icons.shopping_bag_rounded)),
                          title: Text('#${c.number} • ${c.title}'),
                          subtitle: Text([
                            if (c.closedAt != null) formatDateTime(c.closedAt!) else if (c.openedAt != null) 'مفتوح ${timeAgo(c.openedAt!)}',
                            if (c.closedByName != null) c.closedByName!,
                            if (c.voidReason != null) c.voidReason!,
                          ].join(' • ')),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(money(c.totalCents), style: const TextStyle().semiBold),
                            if (c.status == 'closed') IconButton(tooltip: 'طباعة', onPressed: () => printCheckHere(context, ref, c.id), icon: const Icon(Icons.print_outlined)),
                            if (c.status == 'closed' && user.isOwner)
                              IconButton(
                                tooltip: 'فتح الحساب تاني',
                                icon: const Icon(Icons.lock_open_rounded),
                                onPressed: () async {
                                  if (!await confirmDialog(context, 'تفتح حساب #${c.number} تاني عشان تعدّل فيه؟')) return;
                                  try {
                                    await ref.read(sessionProvider).value!.api!.post('/api/checks/${c.id}/reopen');
                                    if (context.mounted) openCheck(context, c.id);
                                  } catch (e) {
                                    if (context.mounted) showMessage(context, errorText(e), error: true);
                                  }
                                },
                              ),
                          ]),
                          onTap: () => openCheck(context, c.id),
                        ),
                      );
                    },
                  ),
                ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

