import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import 'common.dart';

/// بيانات العميل اللي طلب من الـ QR جنب بعض: رقم الترابيزة، والاسم، والموبايل (نسخ واتصال).
class GuestContact extends StatelessWidget {
  const GuestContact({super.key, this.tableName, this.name, this.phone, this.dense = false});

  final String? tableName;
  final String? name;
  final String? phone;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = dense ? 13.0 : 15.0;
    Widget chip(IconData icon, String text, {Color? color, VoidCallback? onTap, bool ltr = false}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
            decoration: BoxDecoration(color: (color ?? scheme.primary).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: size + 2, color: color ?? scheme.primary),
              const SizedBox(width: 5),
              Text(text, textDirection: ltr ? TextDirection.ltr : null, style: TextStyle(fontSize: size, color: color ?? scheme.primary).bold),
            ]),
          ),
        );

    return Wrap(spacing: 6, runSpacing: 6, children: [
      if (tableName != null) chip(Icons.table_restaurant_rounded, 'ترابيزة $tableName', color: brandAccent),
      if (name != null && name!.isNotEmpty) chip(Icons.person_rounded, name!),
      if (phone != null && phone!.isNotEmpty)
        chip(
          Icons.phone_rounded,
          phone!,
          ltr: true,
          onTap: () => showModalBottomSheet<void>(
            context: context,
            builder: (sheet) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(title: Text(phone!, textDirection: TextDirection.ltr, textAlign: TextAlign.right, style: const TextStyle().bold)),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('نسخ الرقم'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: phone!));
                    Navigator.pop(sheet);
                    showMessage(context, 'اتنسخ الرقم');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.call_rounded),
                  title: const Text('اتصال'),
                  onTap: () {
                    Navigator.pop(sheet);
                    launchUrl(Uri.parse('tel:${phone!.replaceAll(' ', '')}'));
                  },
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}
