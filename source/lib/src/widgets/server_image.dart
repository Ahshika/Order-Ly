import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics.dart';
import '../core/session.dart';

/// صورة متخزنة على سيرفر الكافيه (صورة صنف، أو صورة تحويل).
class ServerImage extends ConsumerWidget {
  const ServerImage(this.fileId, {super.key, this.fit = BoxFit.cover, this.width, this.height});

  final String fileId;
  final BoxFit fit;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(sessionProvider).value?.api;
    if (api == null) return const SizedBox.shrink();
    return Image.network(
      '${api.baseUrl}/api/files/$fileId',
      headers: {'authorization': 'Bearer ${api.token}'},
      fit: fit,
      width: width,
      height: height,
      errorBuilder: (_, _, _) =>
          Container(width: width, height: height, color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Icon(Icons.broken_image_outlined)),
    );
  }
}

/// عرض الصورة كاملة (مثلاً صورة التحويل) مع تكبير.
Future<void> showImageViewer(BuildContext context, String fileId, {String? title}) {
  FreezeWatchdog.action('عرض صورة كبيرة');
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(title ?? 'الصورة'),
            trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
          ),
          Flexible(
            child: InteractiveViewer(maxScale: 5, child: ServerImage(fileId, fit: BoxFit.contain)),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}
