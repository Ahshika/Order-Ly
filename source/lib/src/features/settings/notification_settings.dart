import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/notifications.dart';
import '../../core/session.dart';

/// إعدادات الإشعارات والأصوات على الجهاز ده (كل موبايل/كمبيوتر ليه إعداداته).
class NotificationSettingsTiles extends ConsumerStatefulWidget {
  const NotificationSettingsTiles({super.key});

  @override
  ConsumerState<NotificationSettingsTiles> createState() => _NotificationSettingsTilesState();
}

class _NotificationSettingsTilesState extends ConsumerState<NotificationSettingsTiles> {
  bool? _batteryOk;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isAndroid) {
      FlutterForegroundTask.isIgnoringBatteryOptimizations.then((v) {
        if (mounted) setState(() => _batteryOk = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    final center = ref.read(notificationCenterProvider);
    final muted = config.mutedKinds;
    final on = config.notificationsOn;
    Future<void> change(Future<void> Function() f) async {
      await f();
      if (mounted) setState(() {});
    }

    return Column(children: [
      SwitchListTile(
        secondary: const Icon(Icons.notifications_active_rounded),
        title: const Text('الإشعارات على الجهاز ده'),
        subtitle: const Text('طلب جديد، ترابيزة بتنادي، تحويل، طلب جاهز... كل واحد حسب شغله'),
        value: on,
        onChanged: (v) => change(() => config.setNotificationsOn(v)),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.volume_up_rounded),
        title: const Text('صوت مع الإشعارات'),
        subtitle: const Text('لكل نوع صوت مختلف، عشان تعرف من غير ما تبص'),
        value: config.alertSound,
        onChanged: on ? (v) => change(() => config.setAlertSound(v)) : null,
      ),
      if (!kIsWeb && Platform.isAndroid) ...[
        SwitchListTile(
          secondary: const Icon(Icons.screen_lock_portrait_rounded),
          title: const Text('توصل والموبايل مقفول'),
          subtitle: const Text('البرنامج يفضل متصل بالكافيه في الخلفية (بيبان إشعار ثابت "Order Ly شغال")'),
          value: config.notifyInBackground,
          onChanged: on
              ? (v) => change(() async {
                    await config.setNotifyInBackground(v);
                    await BackgroundConnection.update(loggedIn: true, wanted: v);
                  })
              : null,
        ),
        if (_batteryOk == false && config.notifyInBackground)
          ListTile(
            leading: const Icon(Icons.battery_alert_rounded),
            title: const Text('توفير البطارية ممكن يوقّف الإشعارات'),
            subtitle: const Text('اسمح لـ Order Ly يشتغل من غير قيود البطارية'),
            trailing: FilledButton.tonal(
              onPressed: () async {
                final ok = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
                if (mounted) setState(() => _batteryOk = ok);
              },
              child: const Text('سماح'),
            ),
          ),
      ],
      const Divider(height: 1),
      for (final e in notifyKinds.entries)
        CheckboxListTile(
          dense: true,
          value: on && !muted.contains(e.key),
          onChanged: on ? (v) => change(() => config.setKindMuted(e.key, v != true)) : null,
          title: Text(e.value),
          secondary: IconButton(
            tooltip: 'جرّب',
            icon: const Icon(Icons.play_circle_outline_rounded),
            onPressed: () => center.show(e.key, 'تجربة: ${e.value}', 'كده الإشعار هيبان على الجهاز ده'),
          ),
        ),
    ]);
  }
}
