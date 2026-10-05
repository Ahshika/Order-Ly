import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/theme.dart';

/// لوجو Order Ly: فنجان قهوة جوه مربع بزوايا مدورة، وعلامة طلب صغيرة.
class OrderlyLogo extends StatelessWidget {
  const OrderlyLogo({super.key, this.size = 56, this.showName = true});

  final double size;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [brandPrimary, Color(0xFF14B8A6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.local_cafe_rounded, color: Colors.white, size: size * 0.58),
          Positioned(
            bottom: size * 0.1,
            right: size * 0.1,
            child: Container(
              padding: EdgeInsets.all(size * 0.04),
              decoration: const BoxDecoration(color: brandAccent, shape: BoxShape.circle),
              child: Icon(Icons.qr_code_2_rounded, color: Colors.white, size: size * 0.2),
            ),
          ),
        ],
      ),
    );
    if (!showName) return mark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(height: 12),
        BrandName(style: Theme.of(context).textTheme.headlineSmall?.bold),
      ],
    );
  }
}

class BrandName extends StatelessWidget {
  const BrandName({super.key, this.style});
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Order', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
            const TextSpan(text: ' Ly', style: TextStyle(color: brandAccent)),
          ]),
          style: style ?? Theme.of(context).textTheme.titleLarge?.bold,
        ),
      );
}

/// كارت في نص الشاشة للشاشات البسيطة زي الدخول والإعداد.
class CenteredPanel extends StatelessWidget {
  const CenteredPanel({super.key, required this.child, this.maxWidth = 460});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
        ],
      ),
    );
  }
}

/// زرار بيعرض loading وهو بيستنى العملية تخلص.
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed, this.icon});

  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : Text(label);
    if (icon != null && !busy) {
      return FilledButton.icon(onPressed: onPressed, icon: Icon(icon), label: child);
    }
    return FilledButton(onPressed: busy ? null : onPressed, child: child);
  }
}

String errorText(Object e) => e is ApiException ? e.message : 'حصل خطأ غير متوقع: $e';

void showMessage(BuildContext context, String message, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? scheme.error : null,
    ));
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.bold),
      );
}

/// شارة رقم صغيرة (عدد الطلبات المستنية مثلاً).
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.color});
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: color ?? Theme.of(context).colorScheme.error, borderRadius: BorderRadius.circular(20)),
      child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12).bold),
    );
  }
}

/// تأكيد قبل عملية مهمة.
Future<bool> confirmDialog(BuildContext context, String message, {String ok = 'أيوه', bool danger = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(ok),
          ),
        ],
      ),
    ) ??
    false;

/// سؤال نص (زي سبب الإلغاء).
Future<String?> askText(BuildContext context, String title, {String? label, String? initial, bool required = true, int maxLines = 1, TextInputType? keyboard}) async {
  final c = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: c,
          autofocus: true,
          maxLines: maxLines,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(context, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('تمام')),
      ],
    ),
  );
  if (result == null) return null;
  if (required && result.trim().isEmpty) return null;
  return result.trim();
}

/// شاشة فاضية بأيقونة ورسالة.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.outline)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

/// عرض حالة FutureProvider: تحميل / خطأ بزرار إعادة / المحتوى.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final data = value.value;
    if (data != null) return builder(data);
    if (value.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ErrorBanner(errorText(value.error!)),
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('جرّب تاني'))],
          ]),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}
