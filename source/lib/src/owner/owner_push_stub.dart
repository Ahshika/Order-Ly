/// خارج المتصفح: مفيش Web Push.
enum PushSupport { supported, needsHomeScreen, unsupported }

PushSupport pushSupport() => PushSupport.unsupported;

Future<String> subscribePush(String vapidPublicKey) async => throw UnsupportedError('الإشعارات من المتصفح بس');
