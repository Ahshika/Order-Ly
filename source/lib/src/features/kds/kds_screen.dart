import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// شاشة البار / المطبخ: الطلبات اللي محتاجة تتحضر، بالترتيب، ومعاها وقت الانتظار.
/// تدوس على الصنف يبقى "بيتحضر" ثم "جاهز"، أو "الطلب كله جاهز".
class KdsScreen extends ConsumerStatefulWidget {
  const KdsScreen({super.key});

  @override
  ConsumerState<KdsScreen> createState() => _KdsScreenState();
}

class _KdsScreenState extends ConsumerState<KdsScreen> {
  late String _station = ref.read(appConfigProvider).kdsStation;
  Timer? _clock;
  int _lastCount = -1;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _post(String path, [Map<String, Object?>? body]) async {
    try {
      await ref.read(sessionProvider).value!.api!.post(path, body);
      ref.invalidate(kdsProvider(_station));
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider).value;
    final orders = ref.watch(kdsProvider(_station));
    ref.listen(kdsProvider(_station), (_, next) {
      final n = next.value?.where((o) => o.status == 'accepted').length;
      if (n == null) return;
      if (_lastCount >= 0 && n > _lastCount && ref.read(appConfigProvider).alertSound) SystemSound.play(SystemSoundType.alert);
      _lastCount = n;
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('البار والمطبخ'),
        actions: [
          if (menu != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButton<String>(
                value: menu.stations.any((s) => s.id == _station) ? _station : '',
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: '', child: Text('كل الأماكن')),
                  for (final s in menu.stations) DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) {
                  setState(() => _station = v ?? '');
                  ref.read(appConfigProvider).setKdsStation(_station);
                },
              ),
            ),
        ],
      ),
      body: AsyncBody(
        value: orders,
        onRetry: () => ref.invalidate(kdsProvider(_station)),
        builder: (list) {
          if (list.isEmpty) return const EmptyState(icon: Icons.coffee_maker_outlined, text: 'مفيش طلبات دلوقتي ☕');
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 320, mainAxisExtent: 360, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: list.length,
            itemBuilder: (_, i) => _OrderTicket(
              order: list[i],
              stationName: menu?.station(_station.isEmpty ? null : _station)?.name,
              onItem: (l) => _post('/api/order-items/${l.id}/status', {'status': l.status == 'new' ? 'preparing' : l.status == 'preparing' ? 'ready' : 'preparing'}),
              onReady: () => _post('/api/orders/${list[i].id}/ready', {if (_station.isNotEmpty) 'stationId': _station}),
              onServed: () => _post('/api/orders/${list[i].id}/served'),
            ),
          );
        },
      ),
    );
  }
}

class _OrderTicket extends StatelessWidget {
  const _OrderTicket({required this.order, required this.onItem, required this.onReady, required this.onServed, this.stationName});
  final OrderInfo order;
  final String? stationName;
  final ValueChanged<OrderLine> onItem;
  final VoidCallback onReady;
  final VoidCallback onServed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final since = order.acceptedAt ?? order.createdAt;
    final minutes = DateTime.now().difference(since).inMinutes;
    final ready = order.items.every((l) => l.status == 'ready');
    // اللون بيتغير مع وقت الانتظار: أخضر، بعدين برتقاني، بعدين أحمر
    final Color head = ready
        ? const Color(0xFF16A34A)
        : minutes >= 15
            ? scheme.error
            : minutes >= 8
                ? const Color(0xFFD97706)
                : brandPrimary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: head,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(order.place, style: text.titleMedium?.bold.copyWith(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [
                    orderSourceLabels[order.source],
                    formatTime(order.createdAt),
                    if (order.tableName != null && order.guestName != null) order.guestName,
                    if (order.guestPhone != null) order.guestPhone,
                  ].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('#${order.number}', style: text.titleLarge?.bold.copyWith(color: Colors.white)),
              Text('$minutes د', style: const TextStyle(color: Colors.white, fontSize: 12).bold),
            ]),
          ]),
        ),
        if (order.note != null)
          Container(
            color: const Color(0xFFD97706).withValues(alpha: 0.15),
            padding: const EdgeInsets.all(8),
            child: Text('ملاحظة: ${order.note}', style: const TextStyle().bold),
          ),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: [
            for (final l in order.items)
              InkWell(
                onTap: () => onItem(l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(
                      l.status == 'ready' ? Icons.check_circle_rounded : l.status == 'preparing' ? Icons.timelapse_rounded : Icons.radio_button_unchecked_rounded,
                      color: l.status == 'ready' ? const Color(0xFF16A34A) : l.status == 'preparing' ? const Color(0xFFD97706) : scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text('${l.qty}×', style: text.titleMedium?.bold),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.name, style: text.titleMedium?.semiBold.copyWith(decoration: l.status == 'ready' ? TextDecoration.lineThrough : null)),
                        for (final m in l.modifiers) Text('+ ${m['name']}', style: text.bodyMedium),
                        if (l.note != null) Text('ملاحظة: ${l.note}', style: text.bodyMedium?.bold.copyWith(color: scheme.error)),
                      ]),
                    ),
                  ]),
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: ready
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
                  onPressed: onServed,
                  icon: const Icon(Icons.room_service_rounded),
                  label: const Text('اتسلّم للويتر'),
                )
              : FilledButton.icon(onPressed: onReady, icon: const Icon(Icons.done_all_rounded), label: Text(stationName == null ? 'الطلب جاهز' : 'جاهز من $stationName')),
        ),
      ]),
    );
  }
}
