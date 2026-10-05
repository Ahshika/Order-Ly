import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/cafe_models.dart';
import '../../core/diagnostics.dart';
import '../../core/format.dart';
import '../../core/image_shrink.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../../widgets/server_image.dart';
import '../inventory/recipe_editor.dart';

/// بيختار صورة من الجهاز (ملف على الكمبيوتر، أو المعرض/الكاميرا على الموبايل).
Future<Uint8List?> pickImageBytes(BuildContext context) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera_rounded), title: const Text('الكاميرا'), onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_rounded), title: const Text('الصور'), onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null) return null;
    final f = await ImagePicker().pickImage(source: source, maxWidth: 1200, imageQuality: 85);
    return f?.readAsBytes();
  }
  // بنفتح على فولدر الصور اللي على الجهاز، مش آخر فولدر (لو كان موبايل متوصل أو فولدر شبكة، ويندوز ممكن يعلّق فيه)
  final pictures = '${Platform.environment['USERPROFILE'] ?? ''}\\Pictures';
  FreezeWatchdog.action('نافذة اختيار صورة من ويندوز');
  DiagLog.app?.write('INFO', 'فتح نافذة اختيار صورة');
  final f = await openFile(
    initialDirectory: Directory(pictures).existsSync() ? pictures : null,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'صور', extensions: ['jpg', 'jpeg', 'png', 'webp']),
    ],
  );
  DiagLog.app?.write('INFO', f == null ? 'نافذة اختيار الصورة اتقفلت من غير اختيار' : 'اتختارت صورة ${await f.length() ~/ 1024} KB');
  return f?.readAsBytes();
}

class ItemEditor extends ConsumerStatefulWidget {
  const ItemEditor({super.key, required this.menu, this.item, this.categoryId});
  final MenuData menu;
  final MenuItem? item;
  final String? categoryId;

  @override
  ConsumerState<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends ConsumerState<ItemEditor> {
  final _form = GlobalKey<FormState>();
  late final MenuItem? _it = widget.item;
  late final _name = TextEditingController(text: _it?.name);
  late final _nameEn = TextEditingController(text: _it?.nameEn);
  late final _desc = TextEditingController(text: _it?.description);
  late final _descEn = TextEditingController(text: _it?.descriptionEn);
  late final _price = TextEditingController(text: _it == null ? '' : moneyInput(_it.priceCents));
  late final _cost = TextEditingController(text: _it == null || _it.costCents == 0 ? '' : moneyInput(_it.costCents));
  late String _category = _it?.categoryId ?? widget.categoryId ?? widget.menu.categories.first.id;
  late String? _station = _it?.stationId;
  late final Set<String> _groups = {...?_it?.groupIds};
  late final Set<String> _tags = {...?_it?.tags};
  late final Set<String> _upsell = {...?_it?.upsell};
  late bool _showInQr = _it?.showInQr ?? true;
  late bool _active = _it?.active ?? true;
  late String? _imageId = _it?.imageId;
  late String? _id = _it?.id;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _nameEn, _desc, _descEn, _price, _cost]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> _save({bool close = true}) async {
    if (!_form.currentState!.validate()) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(sessionProvider).value!.api!;
      final body = {
        'categoryId': _category,
        'name': _name.text,
        'nameEn': _nameEn.text,
        'description': _desc.text,
        'descriptionEn': _descEn.text,
        'priceCents': parseMoney(_price.text) ?? 0,
        'costCents': parseMoney(_cost.text) ?? 0,
        'stationId': _station,
        'groupIds': _groups.toList(),
        'tags': _tags.toList(),
        'upsell': _upsell.toList(),
        'showInQr': _showInQr,
        'active': _active,
      };
      final res = _id == null ? await api.post('/api/items', body) : await api.patch('/api/items/$_id', body);
      _id = res['id'] as String;
      ref.invalidate(menuAllProvider);
      ref.invalidate(menuProvider);
      if (close && mounted) Navigator.pop(context);
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    if (_id == null && !await _save(close: false)) return;
    if (!mounted) return;
    final picked = await pickImageBytes(context);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await shrinkForUpload(picked);
      final res = await ref.read(sessionProvider).value!.api!.send('PUT', '/api/items/$_id/image', body: {'base64': base64.encode(bytes)}, timeout: const Duration(seconds: 60));
      setState(() => _imageId = res['imageId'] as String);
      ref.invalidate(menuAllProvider);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.menu;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_it == null ? 'صنف جديد' : _it.name),
        actions: [Padding(padding: const EdgeInsets.all(8), child: SizedBox(width: 110, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)))],
      ),
      body: Form(
        key: _form,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: ErrorBanner(_error!)),
              SectionCard(title: 'الصنف', icon: Icons.local_cafe_rounded, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  InkWell(
                    onTap: _busy ? null : _pickImage,
                    borderRadius: BorderRadius.circular(14),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 130,
                        height: 130,
                        child: _imageId != null
                            ? ServerImage(_imageId!)
                            : Container(
                                color: scheme.primaryContainer.withValues(alpha: 0.5),
                                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_a_photo_rounded, size: 32), SizedBox(height: 6), Text('صورة الصنف')]),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(children: [
                      TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'اسم الصنف *'), validator: (v) => (v ?? '').trim().isEmpty ? 'اكتب الاسم' : null),
                      const SizedBox(height: 10),
                      TextFormField(controller: _nameEn, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'Name in English')),
                      if (_imageId != null)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: () async {
                              await ref.read(sessionProvider).value!.api!.delete('/api/items/$_id/image');
                              setState(() => _imageId = null);
                              ref.invalidate(menuAllProvider);
                            },
                            child: const Text('شيل الصورة'),
                          ),
                        ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                TextFormField(controller: _desc, maxLines: 2, decoration: const InputDecoration(labelText: 'وصف قصير (بيظهر للعميل)')),
                const SizedBox(height: 10),
                TextFormField(controller: _descEn, maxLines: 2, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'Description in English')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: MoneyField(controller: _price, label: 'السعر *', validator: (c) => c == null || c <= 0 ? 'اكتب السعر' : null)),
                  const SizedBox(width: 10),
                  Expanded(child: MoneyField(controller: _cost, label: 'التكلفة (لو من غير وصفة)')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'القسم'),
                      items: [for (final c in menu.categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                      onChanged: (v) => setState(() => _category = v!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _station,
                      decoration: const InputDecoration(labelText: 'بيتحضر فين؟'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('زي القسم')),
                        for (final s in menu.stations.where((s) => s.active)) DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => setState(() => _station = v),
                    ),
                  ),
                ]),
              ]),
              const SizedBox(height: 12),
              SectionCard(title: 'الإضافات المتاحة للصنف ده', icon: Icons.tune_rounded, children: [
                if (menu.groups.isEmpty) const Text('لسه مفيش مجموعات إضافات. اعملها من تبويب "الإضافات".'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final g in menu.groups.where((g) => g.active))
                    FilterChip(
                      label: Text('${g.name} (${g.rule})'),
                      selected: _groups.contains(g.id),
                      onSelected: (v) => setState(() => v ? _groups.add(g.id) : _groups.remove(g.id)),
                    ),
                ]),
              ]),
              const SizedBox(height: 12),
              SectionCard(title: 'منيو العميل (QR)', icon: Icons.qr_code_2_rounded, children: [
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('بيظهر في منيو العميل'), value: _showInQr, onChanged: (v) => setState(() => _showInQr = v)),
                Text('علامات', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in tagLabels.entries)
                    FilterChip(label: Text(e.value), selected: _tags.contains(e.key), onSelected: (v) => setState(() => v ? _tags.add(e.key) : _tags.remove(e.key))),
                ]),
                const SizedBox(height: 12),
                Text('نقترح عليه معاه (لحد 4 أصناف) - بيزوّد المبيعات', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final id in _upsell)
                    if (menu.item(id) != null) InputChip(label: Text(menu.item(id)!.name), onDeleted: () => setState(() => _upsell.remove(id))),
                  if (_upsell.length < 4)
                    ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('اختار صنف'),
                      onPressed: () async {
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (context) => SimpleDialog(title: const Text('اختار صنف'), children: [
                            for (final it in menu.items.where((i) => i.active && i.id != _id && !_upsell.contains(i.id)))
                              SimpleDialogOption(onPressed: () => Navigator.pop(context, it.id), child: Text('${it.name} • ${money(it.priceCents)}')),
                          ]),
                        );
                        if (picked != null) setState(() => _upsell.add(picked));
                      },
                    ),
                ]),
              ]),
              const SizedBox(height: 12),
              if (_id != null)
                SectionCard(title: 'الوصفة (الخامات اللي بيستهلكها)', icon: Icons.science_outlined, children: [
                  const Text('لما الصنف ده يتباع، الخامات دي بتتخصم من المخزون لوحدها. ولو خامة خلصت، الصنف بيبقى "خلصان".'),
                  const SizedBox(height: 8),
                  RecipeEditor(kind: 'item', id: _id!),
                ])
              else
                const Card(child: ListTile(leading: Icon(Icons.info_outline_rounded), title: Text('احفظ الصنف الأول وبعدين تقدر تضيف الصورة والوصفة'))),
              if (_it != null) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('الصنف شغال'),
                  subtitle: const Text('لو قفلته بيختفي من المنيو، والطلبات القديمة بتفضل زي ما هي'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }
}

