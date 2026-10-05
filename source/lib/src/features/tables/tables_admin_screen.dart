import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../widgets/common.dart';
import '../printing/print_pdf.dart';

final _qrProvider = FutureProvider.autoDispose<Json>((ref) async {
  ref.watch(floorProvider);
  ref.watch(shopProvider);
  return apiOf(ref).get('/api/tables/qr');
});

/// الترابيزات وأماكنها، وطباعة كروت الـ QR اللي العميل بيطلب منها.
class TablesAdminScreen extends ConsumerWidget {
  const TablesAdminScreen({super.key});

  Future<void> _call(BuildContext context, WidgetRef ref, Future<void> Function() f) async {
    try {
      await f();
      ref.invalidate(floorProvider);
    } catch (e) {
      if (context.mounted) showMessage(context, errorText(e), error: true);
    }
  }

  Future<void> _printQr(BuildContext context, WidgetRef ref, {String? onlyTableId}) async {
    try {
      final data = await ref.read(_qrProvider.future);
      if (data['cafeId'] == null) {
        if (context.mounted) {
          showMessage(context, 'الكافيه لسه ما اتسجلش على النت. اتأكد إن كمبيوتر الكاشير عليه نت واستنى دقيقة.', error: true);
        }
        return;
      }
      final shop = await ref.read(shopProvider.future);
      if (!context.mounted) return;
      // حجم الكارت: 4 في الورقة (يتحط على الترابيزة) أو كارت كبير (للكاونتر والحيطة)
      final perPage = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(title: const Text('حجم الكارت'), children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 4),
            child: const ListTile(leading: Icon(Icons.grid_view_rounded), title: Text('4 كروت في الورقة'), subtitle: Text('يتقص ويتحط على كل ترابيزة')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 1),
            child: const ListTile(leading: Icon(Icons.crop_portrait_rounded), title: Text('كارت كبير في الورقة'), subtitle: Text('للكاونتر أو الحيطة أو الباب')),
          ),
        ]),
      );
      if (perPage == null) return;
      final tables = (data['tables'] as List).cast<Json>().where((t) => onlyTableId == null || t['id'] == onlyTableId);
      final cards = [
        for (final t in tables) (title: 'ترابيزة ${t['name']}', subtitle: (t['areaName'] as String?) ?? '', url: t['url'] as String),
        if (onlyTableId == null) (title: 'تيك أواي', subtitle: 'اطلب واستلم من الكاونتر', url: data['takeawayUrl'] as String),
      ];
      if (cards.isEmpty) {
        if (context.mounted) showMessage(context, 'ضيف ترابيزات الأول', error: true);
        return;
      }
      final bytes = await buildQrCardsPdf(cards, shop, perPage: perPage);
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'QR الترابيزات');
    } catch (e) {
      if (context.mounted) showMessage(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(sessionProvider).value!.api!;
    final qr = ref.watch(_qrProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الترابيزات و QR'),
        actions: [
          FilledButton.icon(onPressed: () => _printQr(context, ref), icon: const Icon(Icons.print_rounded), label: const Text('اطبع كروت QR')),
          const SizedBox(width: 12),
        ],
      ),
      body: AsyncBody(
        value: ref.watch(floorProvider),
        builder: (floor) => ListView(padding: const EdgeInsets.all(16), children: [
          if (qr != null && qr['cafeId'] == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: ErrorBanner('لينكات الـ QR هتجهز أول ما كمبيوتر الكاشير يتوصل بالنت.'),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () async {
                final res = await showDialog<Map<String, Object?>>(context: context, builder: (_) => _NewTableDialog(areas: floor.areas));
                if (res == null || !context.mounted) return;
                try {
                  final f = await api.post('/api/tables', res);
                  ref.invalidate(floorProvider);
                  final created = (f['tables'] as List).cast<Json>().where((t) => t['name'] == res['name']).firstOrNull;
                  if (created == null || !context.mounted) return;
                  // الترابيزة الجديدة: نطبع الكارت بتاعها على طول
                  if (await confirmDialog(context, 'ترابيزة ${res['name']} اتضافت. تطبع الـ QR بتاعها دلوقتي؟', ok: 'اطبع')) {
                    if (context.mounted) await _printQr(context, ref, onlyTableId: created['id'] as String);
                  }
                } catch (e) {
                  if (context.mounted) showMessage(context, errorText(e), error: true);
                }
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('ترابيزة جديدة'),
            ),
            FilledButton.tonalIcon(
              onPressed: () async {
                final res = await showDialog<Map<String, Object?>>(context: context, builder: (_) => _BulkDialog(areas: floor.areas));
                if (res != null && context.mounted) await _call(context, ref, () => api.post('/api/tables/bulk', res));
              },
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('إضافة ترابيزات'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final name = await askText(context, 'مكان جديد', label: 'الاسم (مثلاً: التراس، الدور التاني)');
                if (name != null && context.mounted) await _call(context, ref, () => api.post('/api/areas', {'name': name}));
              },
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('مكان جديد'),
            ),
            if (qr?['takeawayUrl'] != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(qr!['takeawayUrl'] as String), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('جرّب منيو التيك أواي'),
              ),
          ]),
          const SizedBox(height: 12),
          for (final area in [...floor.areas, null])
            if (area != null || floor.tables.any((t) => t.areaId == null)) ...[
              Row(children: [
                Expanded(child: SectionTitle(area?.name ?? 'من غير مكان')),
                if (area != null)
                  IconButton(
                    tooltip: 'تعديل اسم المكان',
                    onPressed: () async {
                      final name = await askText(context, 'اسم المكان', initial: area.name);
                      if (name != null && context.mounted) await _call(context, ref, () => api.patch('/api/areas/${area.id}', {'name': name}));
                    },
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
              ]),
              Card(
                child: Column(children: [
                  for (final t in floor.tables.where((t) => t.areaId == area?.id))
                    ListTile(
                      leading: CircleAvatar(child: Text(t.name.length > 3 ? t.name.substring(0, 3) : t.name, style: const TextStyle(fontSize: 13))),
                      title: Text('ترابيزة ${t.name}'),
                      subtitle: Text('${t.seats} كراسي • ${switch (t.autoAccept) { null => 'الموافقة حسب إعداد الكافيه', true => 'طلبات الـ QR بتتقبل لوحدها', false => 'طلبات الـ QR محتاجة موافقة' }}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (a) async {
                          switch (a) {
                            case 'edit':
                              final res = await showDialog<Map<String, Object?>>(context: context, builder: (_) => _TableDialog(table: t, areas: floor.areas));
                              if (res != null && context.mounted) await _call(context, ref, () => api.patch('/api/tables/${t.id}', res));
                            case 'qr':
                              await _printQr(context, ref, onlyTableId: t.id);
                            case 'copy':
                              final url = (qr?['tables'] as List?)?.cast<Json>().where((x) => x['id'] == t.id).firstOrNull?['url'] as String?;
                              if (url != null) {
                                await Clipboard.setData(ClipboardData(text: url));
                                if (context.mounted) showMessage(context, 'اتنسخ لينك الترابيزة');
                              }
                            case 'open':
                              final url = (qr?['tables'] as List?)?.cast<Json>().where((x) => x['id'] == t.id).firstOrNull?['url'] as String?;
                              if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                            case 'key':
                              if (!await confirmDialog(context, 'الـ QR القديم بتاع الترابيزة دي هيبطل يشتغل وهتحتاج تطبع واحد جديد. (استخدمها لو حد صوّر الكود وبيطلب من برا)')) return;
                              if (context.mounted) await _call(context, ref, () => api.post('/api/tables/${t.id}/new-key'));
                            case 'delete':
                              if (!await confirmDialog(context, 'تشيل ترابيزة ${t.name}؟', danger: true)) return;
                              if (context.mounted) await _call(context, ref, () => api.patch('/api/tables/${t.id}', {'active': false}));
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('تعديل')),
                          PopupMenuItem(value: 'qr', child: Text('اطبع الـ QR بتاعها')),
                          PopupMenuItem(value: 'open', child: Text('جرّب المنيو بتاعها')),
                          PopupMenuItem(value: 'copy', child: Text('انسخ اللينك')),
                          PopupMenuItem(value: 'key', child: Text('غيّر الكود السري')),
                          PopupMenuItem(value: 'delete', child: Text('شيل الترابيزة')),
                        ],
                      ),
                    ),
                  if (!floor.tables.any((t) => t.areaId == area?.id)) const ListTile(title: Text('مفيش ترابيزات هنا')),
                ]),
              ),
            ],
        ]),
      ),
    );
  }
}

class _NewTableDialog extends StatefulWidget {
  const _NewTableDialog({required this.areas});
  final List<Area> areas;

  @override
  State<_NewTableDialog> createState() => _NewTableDialogState();
}

class _NewTableDialogState extends State<_NewTableDialog> {
  final _name = TextEditingController();
  final _seats = TextEditingController(text: '4');
  late String? _area = widget.areas.firstOrNull?.id;

  @override
  void dispose() {
    _name.dispose();
    _seats.dispose();
    super.dispose();
  }

  void _save() {
    final name = latinDigits(_name.text.trim());
    if (name.isEmpty) return;
    Navigator.pop(context, {'name': name, 'seats': int.tryParse(latinDigits(_seats.text)) ?? 4, 'areaId': _area});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('ترابيزة جديدة'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'رقم الترابيزة (أو اسمها)', hintText: 'مثلاً: 15 أو VIP'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 10),
            TextField(controller: _seats, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد الكراسي')),
            if (widget.areas.length > 1) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _area,
                decoration: const InputDecoration(labelText: 'المكان'),
                items: [for (final a in widget.areas) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setState(() => _area = v),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: _save, child: const Text('ضيف')),
        ],
      );
}

class _BulkDialog extends StatefulWidget {
  const _BulkDialog({required this.areas});
  final List<Area> areas;

  @override
  State<_BulkDialog> createState() => _BulkDialogState();
}

class _BulkDialogState extends State<_BulkDialog> {
  final _from = TextEditingController(text: '1');
  final _to = TextEditingController(text: '10');
  final _prefix = TextEditingController();
  final _seats = TextEditingController(text: '4');
  late String? _area = widget.areas.firstOrNull?.id;

  @override
  void dispose() {
    for (final c in [_from, _to, _prefix, _seats]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('إضافة ترابيزات'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: _from, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'من رقم'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _to, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'لحد رقم'))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _prefix, decoration: const InputDecoration(labelText: 'قبل الرقم (اختياري، مثلاً: T أو تراس)')),
            const SizedBox(height: 10),
            TextField(controller: _seats, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد الكراسي')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              initialValue: _area,
              decoration: const InputDecoration(labelText: 'المكان'),
              items: [for (final a in widget.areas) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => _area = v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'from': int.tryParse(latinDigits(_from.text)) ?? 1,
              'to': int.tryParse(latinDigits(_to.text)) ?? 0,
              'prefix': _prefix.text,
              'seats': int.tryParse(latinDigits(_seats.text)) ?? 4,
              'areaId': _area,
            }),
            child: const Text('ضيف'),
          ),
        ],
      );
}

class _TableDialog extends StatefulWidget {
  const _TableDialog({required this.table, required this.areas});
  final TableInfo table;
  final List<Area> areas;

  @override
  State<_TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends State<_TableDialog> {
  late final _name = TextEditingController(text: widget.table.name);
  late final _seats = TextEditingController(text: '${widget.table.seats}');
  late String? _area = widget.table.areaId;
  late bool? _auto = widget.table.autoAccept;

  @override
  void dispose() {
    _name.dispose();
    _seats.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('ترابيزة ${widget.table.name}'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم / الرقم')),
            const SizedBox(height: 10),
            TextField(controller: _seats, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد الكراسي')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              initialValue: _area,
              decoration: const InputDecoration(labelText: 'المكان'),
              items: [for (final a in widget.areas) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => _area = v),
            ),
            const SizedBox(height: 12),
            const Text('طلبات العملاء من الـ QR على الترابيزة دي:'),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('حسب الإعدادات')),
                ButtonSegment(value: 1, label: Text('تتقبل لوحدها')),
                ButtonSegment(value: 2, label: Text('محتاجة موافقة')),
              ],
              selected: {_auto == null ? 0 : _auto! ? 1 : 2},
              onSelectionChanged: (s) => setState(() => _auto = switch (s.first) { 1 => true, 2 => false, _ => null }),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'name': _name.text,
              'seats': int.tryParse(latinDigits(_seats.text)) ?? 4,
              'areaId': _area,
              'autoAccept': _auto,
            }),
            child: const Text('حفظ'),
          ),
        ],
      );
}

