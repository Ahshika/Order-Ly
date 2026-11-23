import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'session.dart';

/// الجهاز متصل بالسيرفر دلوقتي؟ (الشاشة الرئيسية بتعرض شريط ثابت لما الاتصال يقطع، لحد ما يرجع)
final serverConnectedProvider = NotifierProvider<ServerConnection, bool>(ServerConnection.new);

class ServerConnection extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool connected) {
    if (state != connected) state = connected;
  }
}

/// اتصال لحظي بالسيرفر: أول ما أي جهاز يغيّر حاجة، كل الأجهزة التانية بتعرف وتحدّث الشاشة.
///
/// بيطلع اسم الحاجة اللي اتغيرت (مثلاً 'users')، والشاشات بتسمع على اللي يهمها.
final realtimeProvider = StreamProvider<RealtimeEvent>((ref) {
  final session = ref.watch(sessionProvider).value;
  final api = session?.api;
  if (session?.status != SessionStatus.ready || api == null) return const Stream.empty();

  final controller = StreamController<RealtimeEvent>();
  WebSocketChannel? channel;
  Timer? reconnect;
  var disposed = false;
  var connectedBefore = false;
  // آخر وقت (بساعة السيرفر) شفنا فيه حاجة: لما الاتصال يرجع بنطلب الإشعارات اللي فاتتنا من بعده
  String? serverTime;

  void online(bool v) {
    if (!disposed) ref.read(serverConnectedProvider.notifier).set(v);
  }

  void connect() {
    if (disposed) return;
    // ping كل 5 ثواني: لو الواي فاي قطع من غير ما الاتصال يتقفل رسمي، بنعرف في ثواني مش دقايق
    final uri = api.webSocketUri();
    final target = serverTime == null ? uri : uri.replace(queryParameters: {...uri.queryParameters, 'since': serverTime});
    // المتصفح (نسخة الويب) مابيدعمش ping من البرنامج: السيرفر بيقفل الاتصال الميت، وبنرجع نتصل لوحدنا
    channel = kIsWeb ? WebSocketChannel.connect(target) : IOWebSocketChannel.connect(target, pingInterval: const Duration(seconds: 5));
    // أول ما الاتصال يرجع بعد ما قطع (السيرفر رجع، أو الواي فاي رجع): كل الشاشات تتحدّث
    channel!.ready.then((_) {
      online(true);
      if (connectedBefore && !disposed) controller.add(RealtimeEvent('*'));
      connectedBefore = true;
    }, onError: (_) => online(false));
    channel!.stream.listen(
      (msg) {
        try {
          final data = jsonDecode(msg as String) as Map<String, dynamic>;
          if ((data['type'] == 'hello' || data['type'] == 'notify') && data['at'] is String) {
            final at = data['at'] as String;
            if (serverTime == null || at.compareTo(serverTime!) > 0) serverTime = at;
          }
          if (data['type'] == 'changed') controller.add(RealtimeEvent(data['topic'] as String));
          // إشعار للموظفين (طلب جديد، ترابيزة بتنادي، تحويل...): الشاشات مابتسمعش عليه، مركز الإشعارات بس
          if (data['type'] == 'notify') controller.add(RealtimeEvent('notify', data));
        } catch (_) {}
      },
      onDone: () {
        // الاتصال اتقفل عشان إحنا قفلناه (خروج من الحساب): مفيش داعي نرجع نتصل
        if (disposed) return;
        online(false);
        reconnect = Timer(const Duration(seconds: 3), connect);
      },
      onError: (_) => online(false),
      cancelOnError: false,
    );
  }

  connect();
  ref.onDispose(() {
    disposed = true;
    reconnect?.cancel();
    channel?.sink.close();
    controller.close();
  });
  return controller.stream;
});

/// بيعيد تحميل provider معين لما موضوع معين يتغير على السيرفر.
void refreshOn(Ref ref, String topic) => refreshOnTopics(ref, {topic});

/// بيستنى ربع ثانية بعد آخر حدث قبل ما يعيد التحميل: لو أجهزة كتير بتغيّر حاجات في نفس اللحظة،
/// الشاشة بتتحدّث مرة واحدة بدل عشر مرات.
void refreshOnTopics(Ref ref, Set<String> topics) {
  Timer? pending;
  ref.onDispose(() => pending?.cancel());
  ref.listen(realtimeProvider, (_, next) {
    final t = next.value?.topic;
    if (t == null || (t != '*' && !topics.contains(t))) return;
    pending?.cancel();
    pending = Timer(const Duration(milliseconds: 250), ref.invalidateSelf);
  });
}

/// كل حدث object جديد (من غير ==) عشان Riverpod ما يتجاهلش حدثين ورا بعض لنفس الموضوع.
class RealtimeEvent {
  RealtimeEvent(this.topic, [this.data]);
  final String topic;

  /// تفاصيل الحدث (للإشعارات بس).
  final Map<String, dynamic>? data;
}

/// زي [refreshOn] بس لأكتر من موضوع.
void refreshOnAny(Ref ref, Set<String> topics) => refreshOnTopics(ref, topics);
