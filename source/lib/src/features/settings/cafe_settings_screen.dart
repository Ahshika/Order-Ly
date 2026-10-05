import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../core/cafe_models.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../menu/item_editor.dart';

/// بيانات الكافيه وكل إعداداته (لصاحب الكافيه بس).
class CafeSettingsScreen extends ConsumerStatefulWidget {
  const CafeSettingsScreen({super.key});

  @override
  ConsumerState<CafeSettingsScreen> createState() => _CafeSettingsScreenState();
}

class _CafeSettingsScreenState extends ConsumerState<CafeSettingsScreen> {
  ShopProfile? _shop;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _branch = TextEditingController();
  final _service = TextEditingController();
  final _tax = TextEditingController();
  final _footer = TextEditingController();
  final _welcome = TextEditingController();
  final _wifiName = TextEditingController();
  final _wifiPass = TextEditingController();
  final _earn = TextEditingController();
  final _pointValue = TextEditingController();
  final _minRedeem = TextEditingController();
  final _s = <String, Object?>{};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _branch, _service, _tax, _footer, _welcome, _wifiName, _wifiPass, _earn, _pointValue, _minRedeem]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(ShopProfile s) {
    _shop = s;
    _name.text = s.name;
    _phone.text = s.phone ?? '';
    _address.text = s.address ?? '';
    _branch.text = s.branchName ?? '';
    _service.text = _pct(s.intSetting('serviceBp'));
    _tax.text = _pct(s.intSetting('taxBp'));
    _footer.text = s.receiptFooter;
    _welcome.text = s.strSetting('qrWelcome');
    _wifiName.text = s.strSetting('wifiName');
    _wifiPass.text = s.strSetting('wifiPassword');
    _earn.text = moneyInput(s.intSetting('loyaltyEarnCents', 1000));
    _pointValue.text = moneyInput(s.intSetting('loyaltyPointValue', 25));
    _minRedeem.text = '${s.intSetting('loyaltyMinRedeem', 100)}';
    _s
      ..clear()
      ..addAll(s.settings);
  }

  String _pct(int bp) => bp == 0 ? '' : (bp / 100).toString().replaceAll(RegExp(r'\.0$'), '');
  int _bp(TextEditingController c) => ((double.tryParse(latinDigits(c.text.trim())) ?? 0) * 100).round();

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(sessionProvider).value!.api!.patch('/api/shop', {
        'name': _name.text,
        'phone': _phone.text,
        'address': _address.text,
        'branchName': _branch.text.trim().isEmpty ? 'الفرع الرئيسي' : _branch.text,
        'settings': {
          ..._s,
          'serviceBp': _bp(_service),
          'taxBp': _bp(_tax),
          'receiptFooter': _footer.text,
          'qrWelcome': _welcome.text,
          'wifiName': _wifiName.text,
          'wifiPassword': _wifiPass.text,
          'loyaltyEarnCents': parseMoney(_earn.text) ?? 1000,
          'loyaltyPointValue': parseMoney(_pointValue.text) ?? 25,
          'loyaltyMinRedeem': int.tryParse(latinDigits(_minRedeem.text)) ?? 100,
        },
      });
      ref.invalidate(shopProvider);
      _load(ShopProfile(res));
      if (mounted) showMessage(context, 'الإعدادات اتحفظت');
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickLogo() async {
    final bytes = await pickImageBytes(context);
    if (bytes == null) return;
    try {
      final png = await Isolate.run(() {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        final small = decoded.width > 512 ? img.copyResize(decoded, width: 512) : decoded;
        return img.encodePng(small);
      });
      if (png == null) throw Exception('الصورة مش صحيحة');
      await ref.read(sessionProvider).value!.api!.put('/api/shop/logo', {'png': base64.encode(png)});
      ref.invalidate(shopProvider);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e).replaceFirst('Exception: ', ''), error: true);
    }
  }

  Widget _switch(String key, String title, {String? subtitle, bool def = false}) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: _s[key] as bool? ?? def,
        onChanged: (v) => setState(() => _s[key] = v),
      );

  @override
  Widget build(BuildContext context) {
    final shop = ref.watch(shopProvider).value;
    if (shop != null && _shop == null) _load(shop);
    if (_shop == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(
        title: const Text('بيانات الكافيه والإعدادات'),
        actions: [Padding(padding: const EdgeInsets.all(8), child: SizedBox(width: 110, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)))],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            SectionCard(title: 'الكافيه', icon: Icons.storefront_rounded, children: [
              Row(children: [
                InkWell(
                  onTap: _pickLogo,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(16)),
                    child: shop?.logo != null
                        ? ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.memory(shop!.logo!, fit: BoxFit.contain))
                        : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_photo_alternate_outlined), Text('اللوجو', style: TextStyle(fontSize: 12))]),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(children: [
                    TextField(controller: _name, decoration: const InputDecoration(labelText: 'اسم الكافيه')),
                    const SizedBox(height: 10),
                    TextField(controller: _branch, decoration: const InputDecoration(labelText: 'اسم الفرع')),
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'التليفون')),
              const SizedBox(height: 10),
              TextField(controller: _address, decoration: const InputDecoration(labelText: 'العنوان')),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'الخدمة والضريبة', icon: Icons.percent_rounded, children: [
              Row(children: [
                Expanded(child: TextField(controller: _service, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الخدمة', suffixText: '%', hintText: '12'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _tax, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الضريبة', suffixText: '%', hintText: '14'))),
              ]),
              _switch('serviceOnTakeaway', 'الخدمة على التيك أواي والديليفري كمان'),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'طلب العميل من الـ QR', icon: Icons.qr_code_2_rounded, children: [
              _switch('qrEnabled', 'العملاء يقدروا يطلبوا من موبايلهم', def: true),
              const SizedBox(height: 6),
              const Text('الطلبات اللي بتيجي من الـ QR:'),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'manual', label: Text('الكاشير يوافق الأول'), icon: Icon(Icons.verified_user_outlined)),
                  ButtonSegment(value: 'auto', label: Text('تتبعت للبار على طول'), icon: Icon(Icons.bolt_rounded)),
                ],
                selected: {_s['qrApproval'] as String? ?? 'manual'},
                onSelectionChanged: (v) => setState(() => _s['qrApproval'] = v.first),
              ),
              const SizedBox(height: 4),
              Text('وتقدر تعمل لكل ترابيزة إعداد خاص من شاشة "الترابيزات و QR".', style: Theme.of(context).textTheme.bodySmall),
              _switch('qrNeedsOpenRegister', 'مفيش طلبات والدرج مقفول', subtitle: 'عشان محدش يطلب والكافيه مقفول', def: true),
              _switch('qrRequireContact', 'العميل لازم يكتب اسمه ورقم موبايله', subtitle: 'بيظهروا مع الطلب، والعميل بيتسجل في "العملاء" لوحده', def: true),
              const SizedBox(height: 6),
              TextField(controller: _welcome, maxLines: 2, decoration: const InputDecoration(labelText: 'رسالة ترحيب في أول المنيو (اختياري)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _wifiName, decoration: const InputDecoration(labelText: 'اسم الواي فاي (اختياري)'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _wifiPass, decoration: const InputDecoration(labelText: 'باسورد الواي فاي'))),
              ]),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _s['menuLanguages'] as String? ?? 'ar_en',
                decoration: const InputDecoration(labelText: 'لغة المنيو'),
                items: const [
                  DropdownMenuItem(value: 'ar_en', child: Text('عربي وإنجليزي (العميل يختار)')),
                  DropdownMenuItem(value: 'ar', child: Text('عربي بس')),
                  DropdownMenuItem(value: 'en', child: Text('English only')),
                ],
                onChanged: (v) => setState(() => _s['menuLanguages'] = v),
              ),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'الكاشير والصلاحيات', icon: Icons.admin_panel_settings_outlined, children: [
              _switch('cashierCanDiscount', 'الكاشير يقدر يعمل خصم', def: true),
              _switch('voidNeedsOwner', 'إلغاء صنف اتحضر محتاج صاحب الكافيه'),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'نقط الولاء', icon: Icons.loyalty_rounded, children: [
              _switch('loyaltyEnabled', 'العملاء ياخدوا نقط على كل زيارة (برقم الموبايل)'),
              if (_s['loyaltyEnabled'] == true) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: MoneyField(controller: _earn, label: 'نقطة لكل')),
                  const SizedBox(width: 10),
                  Expanded(child: MoneyField(controller: _pointValue, label: 'النقطة تساوي')),
                ]),
                const SizedBox(height: 10),
                TextField(controller: _minRedeem, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'أقل عدد نقط يتصرف')),
                const SizedBox(height: 6),
                Builder(builder: (context) {
                  final earn = parseMoney(_earn.text) ?? 1000, value = parseMoney(_pointValue.text) ?? 25;
                  return Text('يعني العميل اللي يصرف ${money(earn * 100)} ياخد 100 نقطة = خصم ${money(value * 100)} (${percent((value * 10000 / earn).round())})',
                      style: Theme.of(context).textTheme.bodySmall);
                }),
              ],
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'الفاتورة', icon: Icons.receipt_long_rounded, children: [
              DropdownButtonFormField<String>(
                initialValue: _s['receiptPaper'] as String? ?? '80mm',
                decoration: const InputDecoration(labelText: 'مقاس ورق الطابعة'),
                items: const [
                  DropdownMenuItem(value: '80mm', child: Text('رول 80 مم (الأشهر)')),
                  DropdownMenuItem(value: '58mm', child: Text('رول 58 مم')),
                  DropdownMenuItem(value: 'a5', child: Text('A5')),
                  DropdownMenuItem(value: 'a4', child: Text('A4')),
                ],
                onChanged: (v) => setState(() => _s['receiptPaper'] = v),
              ),
              const SizedBox(height: 10),
              TextField(controller: _footer, maxLines: 2, decoration: const InputDecoration(labelText: 'كلمة في آخر الفاتورة')),
            ]),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }
}
