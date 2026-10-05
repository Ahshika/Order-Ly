import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_info.dart';
import '../../core/firebase_config.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../core/theme.dart';
import '../../server/api_server.dart' show serverPort;
import '../../server/discovery.dart';
import '../../widgets/common.dart';
import '../../core/providers.dart';
import '../printing/print_service.dart';
import 'audit_screen.dart';
import 'backup_screen.dart';
import 'cafe_settings_screen.dart';
import 'license_screen.dart';
import 'logs_screen.dart';
import 'pay_methods_screen.dart';

final _localIpsProvider = FutureProvider<List<String>>((ref) => localIpAddresses());

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value!;
    final user = session.user!;
    final config = ref.read(appConfigProvider);
    final isServer = config.mode == AppMode.server;
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          const SectionTitle('حسابي'),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.person_rounded),
                title: Text(user.name),
                subtitle: Text('${user.role.label} • @${user.username}'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.password_rounded),
                title: const Text('تغيير كلمة السر'),
                trailing: const Icon(Icons.chevron_left_rounded),
                onTap: () => showDialog<void>(context: context, builder: (_) => const _ChangePasswordDialog()),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('تسجيل خروج'),
                onTap: () => ref.read(sessionProvider.notifier).logout(),
              ),
            ]),
          ),
          const SectionTitle('الاتصال'),
          Card(
            child: Column(children: [
              ListTile(
                leading: Icon(isServer ? Icons.dns_rounded : Icons.wifi_rounded),
                title: Text(isServer ? 'الجهاز ده هو سيرفر الكافيه' : 'متصل بسيرفر الكافيه'),
                subtitle: Text(isServer ? 'لازم البرنامج يفضل مفتوح على الجهاز ده عشان الأجهزة التانية تشتغل' : session.api!.baseUrl,
                    textDirection: isServer ? null : TextDirection.ltr, textAlign: TextAlign.right),
              ),
              if (isServer) ...[
                const Divider(height: 1),
                const _ServerAddresses(),
              ],
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: Text(isServer ? 'تغيير طريقة تشغيل الجهاز' : 'تغيير السيرفر'),
                subtitle: isServer ? const Text('بيانات الكافيه مش هتتمسح من الجهاز') : null,
                onTap: () async {
                  final ok = await _confirm(context,
                      isServer
                          ? 'لو غيرت، الأجهزة المتصلة بالكمبيوتر ده هتفصل لحد ما ترجع تختاره سيرفر تاني. متأكد؟'
                          : 'هتخرج من الحساب وترجع لشاشة اختيار السيرفر. متأكد؟');
                  if (ok) await ref.read(sessionProvider.notifier).resetConnection();
                },
              ),
            ]),
          ),
          const SectionTitle('الشكل'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('تلقائي'), icon: Icon(Icons.brightness_auto_rounded)),
                  ButtonSegment(value: ThemeMode.light, label: Text('فاتح'), icon: Icon(Icons.light_mode_rounded)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('غامق'), icon: Icon(Icons.dark_mode_rounded)),
                ],
                selected: {themeMode},
                onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
              ),
            ),
          ),
          if (user.isOwner) ...[
            const SectionTitle('الكافيه'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.storefront_rounded),
                  title: const Text('بيانات الكافيه والإعدادات'),
                  subtitle: const Text('اللوجو، والخدمة والضريبة، وطلب العميل من الـ QR، والواي فاي، ونقط الولاء'),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CafeSettingsScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet_rounded),
                  title: const Text('طرق الدفع'),
                  subtitle: const Text('أرقام المحافظ وInstaPay اللي العميل بيحوّل عليها'),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PayMethodsScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.workspace_premium_rounded),
                  title: const Text('الاشتراك'),
                  subtitle: const Text('حالة الاشتراك، وكود الجهاز، والتفعيل'),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LicenseScreen())),
                ),
                const Divider(height: 1),
                const _CloudStatusTile(),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.backup_rounded),
                  title: const Text('النسخ الاحتياطي'),
                  subtitle: const Text('نسخة كل يوم لوحدها، وترجيع نسخة قديمة'),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BackupScreen())),
                ),
              ]),
            ),
          ],
          const SectionTitle('الجهاز ده'),
          const _DeviceSettingsCard(),
          if (user.isOwner) ...[
            const SectionTitle('المتابعة'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('سجل النشاط'),
                subtitle: const Text('مين عمل إيه وإمتى'),
                trailing: const Icon(Icons.chevron_left_rounded),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AuditScreen())),
              ),
            ),
          ],
          const SectionTitle('المشاكل'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('سجل المشاكل'),
              subtitle: const Text('لو البرنامج علّق أو ظهر خطأ، من هنا تبعت التفاصيل لصاحب البرنامج'),
              trailing: const Icon(Icons.chevron_left_rounded),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LogsScreen())),
            ),
          ),
          const SectionTitle('المساعدة'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: const Text('دليل الاستخدام'),
              subtitle: const Text('شرح كل حاجة في البرنامج خطوة بخطوة'),
              trailing: const Icon(Icons.open_in_new_rounded),
              onTap: () => launchUrl(Uri.parse('$menuSiteUrl/guide'), mode: LaunchMode.externalApplication),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text('$appName $appVersion',
                style: Theme.of(context).textTheme.bodySmall, textDirection: TextDirection.ltr),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('أيوه')),
          ],
        ),
      ) ??
      false;
}

class _ServerAddresses extends ConsumerWidget {
  const _ServerAddresses();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ips = ref.watch(_localIpsProvider).value ?? const [];
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('عنوان السيرفر للأجهزة التانية', style: text.titleSmall?.bold),
          const SizedBox(height: 4),
          Text('الموبايلات بتلاقي السيرفر لوحدها. لو ما لقيتوش، اكتب العنوان ده في الموبايل:', style: text.bodySmall),
          const SizedBox(height: 8),
          if (ips.isEmpty) const Text('الجهاز مش متوصل بشبكة'),
          for (final ip in ips)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SelectableText('$ip:$serverPort', textDirection: TextDirection.ltr, style: text.titleMedium?.semiBold),
                  IconButton(
                    tooltip: 'نسخ',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: ip));
                      showMessage(context, 'اتنسخ العنوان');
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider).value!.api!.post('/api/auth/password', {
        'currentPassword': _current.text,
        'newPassword': _new.text,
      });
      if (!mounted) return;
      Navigator.pop(context);
      showMessage(context, 'تم تغيير كلمة السر، واتعمل خروج من كل الأجهزة التانية');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('تغيير كلمة السر'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(controller: _current, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة السر الحالية')),
              const SizedBox(height: 12),
              TextFormField(
                controller: _new,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'كلمة السر الجديدة'),
                validator: (v) => (v ?? '').length < 6 ? '6 حروف أو أرقام على الأقل' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'تأكيد كلمة السر الجديدة'),
                validator: (v) => v != _new.text ? 'مش زي اللي فوق' : null,
              ),
              if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(width: 120, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)),
      ],
    );
  }
}

/// إعدادات خاصة بالجهاز ده بس: الطابعات (الحسابات والبار والمطبخ)، وصوت التنبيه.
class _DeviceSettingsCard extends ConsumerStatefulWidget {
  const _DeviceSettingsCard();

  @override
  ConsumerState<_DeviceSettingsCard> createState() => _DeviceSettingsCardState();
}

class _DeviceSettingsCardState extends ConsumerState<_DeviceSettingsCard> {
  @override
  Widget build(BuildContext context) {
    final config = ref.read(appConfigProvider);
    final stations = config.printStations;
    final menu = ref.watch(menuProvider).value;
    final agent = ref.watch(printAgentProvider);
    final targets = <(String, String)>[
      ('receipt', 'الحسابات والفواتير'),
      if (menu != null)
        for (final s in menu.stations.where((s) => s.active)) (s.id, 'تيكت ${s.name}'),
    ];

    Widget printerTile(String id, String label) {
      final p = stations[id];
      return ListTile(
        leading: Icon(id == 'receipt' ? Icons.receipt_long_rounded : Icons.print_rounded),
        title: Text(label),
        subtitle: Text(p != null ? 'بيطبع هنا على: ${p.name}' : 'مش بيطبع من الجهاز ده'),
        trailing: Wrap(children: [
          if (p != null)
            TextButton(
              onPressed: () async {
                await config.setPrintStation(id, null, null);
                ref.invalidate(printAgentProvider);
                setState(() {});
              },
              child: const Text('إلغاء'),
            ),
          FilledButton.tonal(
            onPressed: () async {
              await pickStationPrinter(context, ref, id, label);
              if (mounted) setState(() {});
            },
            child: Text(p == null ? 'اختيار طابعة' : 'تغيير'),
          ),
        ]),
      );
    }

    return Card(
      child: Column(children: [
        const ListTile(
          leading: Icon(Icons.info_outline_rounded),
          title: Text('الطباعة الأوتوماتيك'),
          subtitle: Text('اختار الطابعات المتوصلة بالجهاز ده. أي طلب يتقبل بيطلع تيكته لوحده على طابعة البار أو المطبخ، والحساب على طابعة الكاشير.'),
        ),
        for (final t in targets) ...[const Divider(height: 1), printerTile(t.$1, t.$2)],
        if (agent.active) ...[
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: Icon(Icons.check_circle_rounded, color: agent.failed > 0 ? Theme.of(context).colorScheme.error : const Color(0xFF16A34A)),
            title: Text('محطة الطباعة شغالة • اتطبع ${agent.printed}${agent.failed > 0 ? ' • فشل ${agent.failed}' : ''}'),
            subtitle: agent.lastError == null ? const Text('سيب البرنامج مفتوح على الجهاز ده') : Text('آخر مشكلة: ${agent.lastError}'),
          ),
        ],
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_rounded),
          title: const Text('صوت تنبيه للطلبات الجديدة'),
          value: config.alertSound,
          onChanged: (v) async {
            await config.setAlertSound(v);
            setState(() {});
          },
        ),
      ]),
    );
  }
}

/// حالة الربط مع منيو العملاء على النت.
class _CloudStatusTile extends ConsumerStatefulWidget {
  const _CloudStatusTile();

  @override
  ConsumerState<_CloudStatusTile> createState() => _CloudStatusTileState();
}

class _CloudStatusTileState extends ConsumerState<_CloudStatusTile> {
  bool _busy = false;

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider).value!.api!.send('POST', '/api/cloud/sync', timeout: const Duration(seconds: 90));
      ref.invalidate(shopProvider);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shop = ref.watch(shopProvider).value;
    final scheme = Theme.of(context).colorScheme;
    final error = shop?.cloudError;
    final last = shop?.cloudLastSync;
    final live = shop?.cloudLive ?? false;
    return ListTile(
      leading: Icon(live ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: live ? const Color(0xFF16A34A) : error != null ? scheme.error : scheme.outline),
      title: const Text('منيو العملاء على النت (QR)'),
      subtitle: Text([
        live ? 'متصل: الطلبات بتوصل على طول' : 'مش متصل دلوقتي',
        if (error != null) 'آخر مشكلة: $error' else if (last != null) 'آخر تحديث ${timeAgo(last)}',
      ].join(' • ')),
      trailing: _busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(tooltip: 'تحديث دلوقتي', icon: const Icon(Icons.sync_rounded), onPressed: _sync),
    );
  }
}
