import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/shop.dart';
import '../../widgets/common.dart';

final _customersProvider = FutureProvider.autoDispose.family<List<Customer>, String>((ref, q) async {
  refreshOn(ref, 'checks');
  final res = await apiOf(ref).get('/api/customers', query: {if (q.isNotEmpty) 'q': q});
  return (res['customers'] as List).cast<Json>().map(Customer.new).toList();
});

/// العملاء الدايمين (برقم الموبايل): الزيارات، والصرف، ونقط الولاء.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final loyalty = ref.watch(shopProvider).value?.loyaltyEnabled ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('العملاء')),
      body: Column(children: [
        if (!loyalty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(child: ListTile(leading: Icon(Icons.loyalty_outlined), title: Text('نقط الولاء مقفولة'), subtitle: Text('فعّلها من الإعدادات ← بيانات الكافيه عشان العملاء ياخدوا نقط على كل زيارة'))),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: 'دوّر بالاسم أو الموبايل', prefixIcon: Icon(Icons.search_rounded), isDense: true),
            onSubmitted: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: AsyncBody(
            value: ref.watch(_customersProvider(_q)),
            builder: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.people_outline_rounded, text: 'العملاء بيتسجلوا لما الكاشير يكتب رقم الموبايل على الحساب')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final c = list[i];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(child: Text((c.name ?? c.phone).characters.first)),
                          title: Text(c.name ?? c.phone),
                          subtitle: Text([
                            if (c.name != null) c.phone,
                            '${c.visits} زيارة',
                            'صرف ${money(c.spentCents)}',
                            if (c.lastVisitAt != null) 'آخر مرة ${timeAgo(c.lastVisitAt!)}',
                          ].join(' • ')),
                          trailing: loyalty ? Chip(label: Text('${c.points} نقطة')) : null,
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}
