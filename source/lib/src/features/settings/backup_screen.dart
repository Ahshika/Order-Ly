import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../../core/providers.dart';

final _backupsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => apiOf(ref).get('/api/backups'));

String _everyLabel(int hours) => switch (hours) {
      1 => 'كل ساعة',
      24 => 'كل يوم',
      168 => 'كل أسبوع',
      _ => 'كل $hours ساعات',
    };

/// رسالة للمالك: قاعدة البيانات كانت بايظة والسيرفر رجع لنسخة احتياطية لوحده.
class RecoveryNotice extends StatelessWidget {
  const RecoveryNotice({super.key, required this.recovery, this.onDismiss, this.onOpen});
  final Map<String, dynamic> recovery;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final at = parseDate(recovery['backupAt']);
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.restore_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(child: Text('قاعدة البيانات كانت بايظة، والبرنامج رجع لآخر نسخة سليمة لوحده', style: TextStyle(color: scheme.onErrorContainer).bold)),
          ]),
          const SizedBox(height: 6),
          Text(
            'النسخة: ${at == null ? recovery['backup'] : formatDateTime(at)}. أي حاجة اتسجلت بعد الوقت ده مش موجودة، راجعها.\n'
            'الملف البايظ متحفظ هنا (ماتمسحوش، ممكن الدعم الفني يرجّع منه حاجات): ${recovery['corruptFolder']}',
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (onOpen != null) FilledButton.tonal(onPressed: onOpen, child: const Text('النسخ الاحتياطي')),
            if (onDismiss != null) TextButton(onPressed: onDismiss, child: const Text('فهمت')),
          ]),
        ]),
      ),
    );
  }
}

/// النسخ الاحتياطي: بيتعمل لوحده كل يوم، وتقدر تعمله يدوي أو ترجّع نسخة قديمة.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(_backupsProvider);
      if (mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseFolder(String? current) async {
    final isServer = ref.read(appConfigProvider).mode == AppMode.server;
    String? path;
    if (isServer) {
      path = await getDirectoryPath(confirmButtonText: 'اختيار الفولدر');
    } else {
      final c = TextEditingController(text: current);
      path = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('فولدر النسخ على كمبيوتر السيرفر'),
          content: TextField(controller: c, textDirection: TextDirection.ltr, decoration: const InputDecoration(hintText: r'D:\Backups')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('حفظ')),
          ],
        ),
      );
    }
    if (path == null || !mounted) return;
    await _run(
      () => ref.read(sessionProvider).value!.api!.patch('/api/backups/settings', {'backupDir': path}),
      'هيتعمل نسخة في الفولدر ده كل يوم',
    );
  }

  Future<void> _restore(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: brandAccent, size: 40),
        title: const Text('ترجيع نسخة قديمة؟'),
        content: Text('كل البيانات هترجع زي ما كانت وقت النسخة ($name)، وأي حاجة اتسجلت بعدها هتروح.\n'
            'البرنامج هيحتفظ بنسخة من البيانات الحالية للاحتياط.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: brandAccent), onPressed: () => Navigator.pop(context, true), child: const Text('ترجيع')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => ref.read(sessionProvider).value!.api!.post('/api/backups/restore', {'name': name}),
      'اقفل البرنامج على كمبيوتر السيرفر وافتحه تاني عشان الترجيع يتم',
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_backupsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('النسخ الاحتياطي')),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: ErrorBanner(errorText(e))),
        data: (d) {
          final last = parseDate(d['lastBackupAt']);
          final err = (d['lastBackupError'] as String?)?.isEmpty ?? true ? null : d['lastBackupError'] as String;
          final external = (d['backupDir'] as String?)?.isEmpty ?? true ? null : d['backupDir'] as String;
          final backups = (d['backups'] as List).cast<Map<String, dynamic>>();
          final every = d['everyHours'] as int? ?? 24;
          final keep = d['keep'] as int? ?? 14;
          final estimated = d['estimatedBytes'] as int?;
          final recovery = d['recovery'] as Map<String, dynamic>?;
          Future<void> save(Map<String, Object?> body) => _run(() => ref.read(sessionProvider).value!.api!.patch('/api/backups/settings', body), 'اتحفظ');
          return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
            if (recovery != null) ...[
              RecoveryNotice(recovery: recovery, onDismiss: _busy ? null : () => save({'dismissRecovery': true})),
              const SizedBox(height: 12),
            ],
            if (d['restorePending'] == true)
              const Padding(padding: EdgeInsets.only(bottom: 12), child: ErrorBanner('فيه ترجيع مستني: اقفل البرنامج على كمبيوتر السيرفر وافتحه تاني.')),
            SectionCard(title: 'الحالة', icon: Icons.shield_rounded, children: [
              Text(last == null ? 'لسه ما اتعملش نسخة' : 'آخر نسخة: ${formatDateTime(last)} (${timeAgo(last)})', style: const TextStyle().semiBold),
              const SizedBox(height: 4),
              Text('البرنامج بيعمل نسخة لوحده ${_everyLabel(every)}، وبيحتفظ بآخر $keep نسخة.'),
              if (err != null) ...[const SizedBox(height: 8), ErrorBanner(err)],
              const SizedBox(height: 12),
              BusyButton(
                label: 'اعمل نسخة دلوقتي',
                icon: Icons.backup_rounded,
                busy: _busy,
                onPressed: () => _run(() => ref.read(sessionProvider).value!.api!.post('/api/backups'), 'اتعملت نسخة'),
              ),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'مواعيد النسخ', icon: Icons.schedule_rounded, children: [
              DropdownButtonFormField<int>(
                key: ValueKey('every-$every'),
                initialValue: every,
                decoration: const InputDecoration(labelText: 'اعمل نسخة'),
                items: [for (final h in (d['everyChoices'] as List? ?? const [1, 3, 6, 12, 24, 168]).cast<int>()) DropdownMenuItem(value: h, child: Text(_everyLabel(h)))],
                onChanged: _busy ? null : (v) => v == null || v == every ? null : save({'everyHours': v}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey('keep-$keep'),
                initialValue: keep,
                decoration: const InputDecoration(labelText: 'احتفظ بآخر'),
                items: [for (final k in (d['keepChoices'] as List? ?? const [7, 14, 30, 60]).cast<int>()) DropdownMenuItem(value: k, child: Text('$k نسخة'))],
                onChanged: _busy ? null : (v) => v == null || v == keep ? null : save({'keep': v}),
              ),
              if (estimated != null) ...[
                const SizedBox(height: 6),
                Text('المساحة المتوقعة على الكمبيوتر: حوالي ${(estimated / 1024 / 1024).toStringAsFixed(0)} ميجا', style: Theme.of(context).textTheme.bodySmall),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: d['onShiftClose'] == true,
                title: const Text('نسخة كمان مع قفل كل وردية'),
                subtitle: const Text('أول ما الكاشير يقفل الدرج، شغل الوردية كله بيتحفظ'),
                onChanged: _busy ? null : (v) => save({'onShiftClose': v}),
              ),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'نسخة في مكان تاني', icon: Icons.folder_copy_rounded, children: [
              const Text('لو الكمبيوتر باظ أو اتسرق، النسخ اللي عليه هتضيع معاه. اختار فولدر تاني يتحفظ فيه نسخة كمان:\n'
                  '• فلاشة أو هارد خارجي\n'
                  '• أو فولدر Google Drive على الكمبيوتر (لو مسطب Google Drive) عشان النسخة تبقى على النت ببلاش'),
              const SizedBox(height: 12),
              if (external != null) Text(external, textDirection: TextDirection.ltr, style: TextStyle(color: scheme.primary).semiBold),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _chooseFolder(external),
                  icon: const Icon(Icons.folder_open_rounded),
                  label: Text(external == null ? 'اختيار فولدر' : 'تغيير'),
                ),
                if (external != null)
                  TextButton(
                    onPressed: _busy ? null : () => _run(() => ref.read(sessionProvider).value!.api!.patch('/api/backups/settings', {'backupDir': null}), 'اتلغى الفولدر التاني'),
                    child: const Text('إلغاء'),
                  ),
              ]),
            ]),
            const SizedBox(height: 12),
            SectionCard(title: 'النسخ المحفوظة', icon: Icons.history_rounded, children: [
              Text(d['localPath'] as String? ?? '', textDirection: TextDirection.ltr, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              for (final b in backups)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.inventory_2_rounded),
                  title: Text(formatDateTime(parseDate(b['createdAt'])!)),
                  subtitle: Text('${((b['size'] as int) / 1024 / 1024).toStringAsFixed(1)} ميجا'),
                  trailing: TextButton(onPressed: _busy ? null : () => _restore(b['name'] as String), child: const Text('ترجيع')),
                ),
              if (backups.isEmpty) const Text('مفيش نسخ لسه'),
            ]),
          ]);
        },
      ),
    );
  }
}
