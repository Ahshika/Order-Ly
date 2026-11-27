import 'dart:js_interop';

/// الأيفون مابيدّيش إشعارات غير للنسخة اللي على الشاشة الرئيسية (iOS 16.4 أو أحدث).
enum PushSupport { supported, needsHomeScreen, unsupported }

@JS('orderlyPush.supported')
external JSBoolean _supported();

@JS('orderlyPush.needsHomeScreen')
external JSBoolean _needsHomeScreen();

@JS('orderlyPush.subscribe')
external JSPromise<JSString> _subscribe(JSString vapidPublicKey);

PushSupport pushSupport() {
  try {
    if (_needsHomeScreen().toDart) return PushSupport.needsHomeScreen;
    return _supported().toDart ? PushSupport.supported : PushSupport.unsupported;
  } catch (_) {
    return PushSupport.unsupported;
  }
}

/// بيطلب الإذن ويشترك، وبيرجّع الاشتراك JSON (endpoint + keys) عشان يتحفظ على Firebase.
Future<String> subscribePush(String vapidPublicKey) async => (await _subscribe(vapidPublicKey.toJS).toDart).toDart;
