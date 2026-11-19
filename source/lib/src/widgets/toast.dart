import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';

enum ToastKind { info, success, error, alert }

/// رسالة صغيرة بتدخل من يمين الشاشة وتختفي لوحدها (بدل الشريط الأبيض اللي كان بياخد عرض الشاشة كله تحت).
/// عرضها محدود (أقصى حاجة 340) عشان ما تغطيش الشغل، وبتتشال بالضغط عليها أو بسحبها لليمين،
/// ولو جت كذا رسالة ورا بعض بيترصّوا تحت بعض (3 بالكتير).
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  showToastOn(overlay, message, kind: kind, duration: duration, actionLabel: actionLabel, onAction: onAction);
}

/// زي [showToast] من غير context (الإشعارات اللي جاية من السيرفر بتستخدمها).
void showToastOn(
  OverlayState overlay,
  String message, {
  ToastKind kind = ToastKind.info,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) =>
    _Toasts.show(overlay, _ToastData(message, kind, duration ?? _defaultDuration(kind, actionLabel != null), actionLabel, onAction));

Duration _defaultDuration(ToastKind kind, bool hasAction) => switch (kind) {
      _ when hasAction => const Duration(seconds: 7),
      ToastKind.error => const Duration(seconds: 5),
      ToastKind.alert => const Duration(seconds: 6),
      _ => const Duration(milliseconds: 3200),
    };

class _ToastData {
  _ToastData(this.message, this.kind, this.duration, this.actionLabel, this.onAction);
  final String message;
  final ToastKind kind;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class _Toasts {
  static const _max = 3;
  static final _live = <_ToastHandle>[];

  static void show(OverlayState overlay, _ToastData data) {
    // رسايل كانت على شاشة اتقفلت (مثلاً خروج من الحساب): نشيلها من القايمة عشان ماتبوظش ترتيب الجديدة
    _live.removeWhere((t) => t.entry == null || !t.entry!.mounted);
    // نفس الرسالة بالظبط لسه ظاهرة (مثلاً "اتضاف" بسرعة ورا بعض): نجدّد وقتها بدل ما نكررها
    final same = _live.where((t) => t.data.message == data.message && !t.closing).firstOrNull;
    if (same != null) return same.restart();
    while (_live.where((t) => !t.closing).length >= _max) {
      _live.firstWhere((t) => !t.closing).close();
    }
    late final _ToastHandle handle;
    handle = _ToastHandle(data, () {
      _live.remove(handle);
      _relayout();
    });
    _live.add(handle);
    handle.entry = OverlayEntry(builder: (_) => _ToastView(handle: handle, index: () => _live.indexOf(handle)));
    overlay.insert(handle.entry!);
    _relayout();
  }

  static void _relayout() {
    for (final t in _live) {
      t.entry?.markNeedsBuild();
    }
  }
}

class _ToastHandle {
  _ToastHandle(this.data, this._onRemoved) {
    restart();
  }

  final _ToastData data;
  final VoidCallback _onRemoved;
  OverlayEntry? entry;
  Timer? _timer;
  bool closing = false;
  final visible = ValueNotifier<bool>(false);
  int generation = 0;

  void restart() {
    _timer?.cancel();
    generation++;
    _timer = Timer(data.duration, close);
    entry?.markNeedsBuild();
  }

  void close() {
    if (closing) return;
    closing = true;
    _timer?.cancel();
    visible.value = false;
    // نستنى حركة الخروج وبعدين نشيلها
    Timer(const Duration(milliseconds: 260), () {
      entry?.remove();
      entry = null;
      _onRemoved();
    });
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({required this.handle, required this.index});
  final _ToastHandle handle;
  final int Function() index;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.handle.visible.value = true);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.handle;
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (h.data.kind) {
      ToastKind.success => (scheme.primary, Icons.check_circle_rounded),
      ToastKind.error => (scheme.error, Icons.error_rounded),
      ToastKind.alert => (brandAccent, Icons.notifications_active_rounded),
      ToastKind.info => (scheme.primary, Icons.info_rounded),
    };
    final width = (media.size.width - 32).clamp(200.0, 340.0);
    final slot = widget.index().clamp(0, 2);
    return Positioned(
      // ناحية اليمين دايماً (مش حسب اتجاه الكتابة)، وتحت شريط الموبايل اللي فوق
      right: 16,
      top: media.padding.top + 12 + slot * 76,
      width: width,
      child: ValueListenableBuilder<bool>(
        valueListenable: h.visible,
        builder: (context, shown, child) => AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(1.15, 0),
          duration: const Duration(milliseconds: 240),
          curve: shown ? Curves.easeOutCubic : Curves.easeInCubic,
          child: AnimatedOpacity(opacity: shown ? 1 : 0, duration: const Duration(milliseconds: 200), child: child),
        ),
        child: Dismissible(
          key: ObjectKey(h),
          direction: DismissDirection.startToEnd,
          onDismissed: (_) => h.close(),
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Material(
              color: scheme.surfaceContainerHigh,
              elevation: 6,
              shadowColor: Colors.black38,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: h.close,
                child: Container(
                  decoration: BoxDecoration(border: BorderDirectional(start: BorderSide(color: color, width: 4))),
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Row(children: [
                    Icon(icon, color: color, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(h.data.message, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurface, fontSize: 14)),
                    ),
                    if (h.data.actionLabel != null)
                      TextButton(
                        onPressed: () {
                          h.close();
                          h.data.onAction?.call();
                        },
                        child: Text(h.data.actionLabel!),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
