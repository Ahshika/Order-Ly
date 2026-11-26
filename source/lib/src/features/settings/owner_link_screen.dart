import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cafe_models.dart' show Json;
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// ربط المالك من بره (routes_owner.dart): كود لمرة واحدة بـ QR، والمالك يصوّره من موبايله ويعمل حساب.
final _ownerProvider = FutureProvider.autoDispose<Json>((ref) {
  refreshOn(ref, 'owner');
  return apiOf(ref).get('/api/owner');
});

class OwnerLinkScreen extends ConsumerStatefulWidget {
  const OwnerLinkScreen({super.key});

  @override
  ConsumerState<OwnerLinkScreen> createState() => _OwnerLinkScreenState();
}

class _OwnerLinkScreenState extends ConsumerState<OwnerLinkScreen> {
  bool _busy = false;

  Future<void> _call(Future<Json> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      ref.invalidate(_ownerProvider);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(sessionProvider).value!.api!;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('المالك من بره')),
      body: AsyncBody(
        value: ref.watch(_ownerProvider),
        onRetry: () => ref.invalidate(_ownerProvider),
        builder: (s) {
          // التحكم من بعيد: كل كمبيوتر بيقرر لنفسه (هو اللي بينفّذ أوامر الفرع بتاعه)
          final remote = Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.settings_remote_rounded),
              title: const Text('التحكم من بعيد'),
              subtitle: const Text('المالك يغيّر الأسعار، ويقفل أو يفتح صنف، ويشوف الحسابات المفتوحة والسجل من موبايله. '
                  'كل حاجة بتتسجل في سجل العمليات "من أبلكيشن المالك".'),
              value: s['remote'] == true,
              onChanged: _busy ? null : (v) => _call(() => api.post('/api/owner/remote', {'on': v})),
            ),
          );
          if (s['hub'] != true) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              const EmptyState(icon: Icons.account_tree_rounded, text: 'ربط المالك بيتعمل من الفرع الرئيسي، والمالك هيشوف تقارير الفرع ده من هناك.'),
              remote,
            ]);
          }
          if (s['ready'] != true) {
            return const EmptyState(icon: Icons.cloud_off_rounded, text: 'الكمبيوتر ده لسه مااتوصلش بالنت. استنى دقيقة وارجع تاني.');
          }
          final code = s['code'] as Map?;
          final owners = (s['owners'] as List? ?? const []).cast<Map>();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Text('المالك بيشوف تقرير كل وردية وكل يوم لكل الفروع من موبايله وهو في أي مكان، ويجيله إشعار مع كل قفل درج.', style: text.bodyMedium),
                const SizedBox(height: 16),
                if (s['error'] != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: ErrorBanner('${s['error']}')),
                if (code == null)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _call(() => api.post('/api/owner/code')),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('اعمل كود ربط'),
                  )
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(children: [
                        Text('صوّر الكود ده بكاميرا موبايل المالك', style: text.titleMedium),
                        const SizedBox(height: 12),
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(12),
                          child: BarcodeWidget(barcode: Barcode.qrCode(), data: code['link'] as String, width: 220, height: 220),
                        ),
                        const SizedBox(height: 8),
                        SelectableText('${code['code']}', style: text.headlineSmall?.copyWith(letterSpacing: 4), textDirection: TextDirection.ltr),
                        Text('بيخلص الساعة ${formatTime(DateTime.parse(code['exp'] as String).toLocal())}، وبيشتغل لمرة واحدة', style: text.bodySmall),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: code['link'] as String));
                            showMessage(context, 'اتنسخ اللينك (ابعته للمالك واتساب لو مش جنبك)');
                          },
                          icon: const Icon(Icons.copy_rounded),
                          label: const Text('نسخ اللينك'),
                        ),
                        const Divider(),
                        Text(
                          'على الأيفون: بعد ما اللينك يفتح في Safari، زرار المشاركة › "إضافة إلى الشاشة الرئيسية"، وافتحه من الأيقونة وكمّل التسجيل (عشان الإشعارات تشتغل).\n'
                          'على أندرويد: كمّل التسجيل في Chrome، ومن القايمة "إضافة للشاشة الرئيسية".',
                          style: text.bodySmall,
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 12),
                remote,
                const SizedBox(height: 20),
                Text('الملّاك المربوطين', style: text.titleMedium),
                const SizedBox(height: 6),
                if (owners.isEmpty) Text('لسه محدش', style: text.bodySmall),
                for (final o in owners)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.verified_user_rounded),
                      title: Text('${o['name'] ?? ''}'),
                      subtitle: Text('${o['email'] ?? ''}', textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                      trailing: IconButton(
                        tooltip: 'شيل الصلاحية',
                        icon: const Icon(Icons.person_remove_rounded),
                        onPressed: _busy
                            ? null
                            : () async {
                                final ok = await confirmDialog(context, 'شيل ${o['name'] ?? 'المالك ده'}؟ مش هيقدر يشوف التقارير ولا هيجيله إشعارات تاني.', ok: 'شيله', danger: true);
                                if (ok) await _call(() => api.post('/api/owner/remove', {'uid': o['uid']}));
                              },
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }
}
