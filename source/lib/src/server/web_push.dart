/// إشعارات Web Push للمالك (أيفون وأندرويد) من كمبيوتر الكافيه نفسه، من غير أي سيرفر ولا خطة مدفوعة.
///
/// - التشفير: RFC 8291 (aes128gcm): ECDH على P-256 + HKDF + AES-128-GCM.
/// - هوية المرسل: RFC 8292 (VAPID): توقيع ES256 بمفتاح المحل.
/// المتصفح (Apple أو Google) بيوصّل الرسالة للموبايل حتى والأبلكيشن مقفول، ومايقدرش يقراها.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

final _curve = pc.ECDomainParameters('prime256v1');

String b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');
Uint8List unb64url(String s) => base64Url.decode(s.replaceAll(RegExp(r'\s'), '').padRight((s.replaceAll(RegExp(r'\s'), '').length + 3) ~/ 4 * 4, '='));

Uint8List _bigToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

BigInt _bytesToBig(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));

pc.SecureRandom _random() {
  final r = Random.secure();
  return pc.FortunaRandom()..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)))));
}

/// زوج مفاتيح P-256: الخاص 32 بايت، والعام 65 بايت (0x04 || x || y).
class P256Keys {
  P256Keys(this.privateKey, this.publicKey);

  factory P256Keys.generate() {
    final gen = pc.ECKeyGenerator()..init(pc.ParametersWithRandom(pc.ECKeyGeneratorParameters(_curve), _random()));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;
    return P256Keys(_bigToBytes(priv.d!, 32), pub.Q!.getEncoded(false));
  }

  factory P256Keys.fromPrivate(Uint8List privateKey) {
    final q = (_curve.G * _bytesToBig(privateKey))!;
    return P256Keys(privateKey, q.getEncoded(false));
  }

  final Uint8List privateKey;
  final Uint8List publicKey;

  /// السر المشترك (x بتاع النقطة، 32 بايت) مع مفتاح عام تاني.
  Uint8List ecdh(Uint8List otherPublic) {
    final point = _curve.curve.decodePoint(otherPublic);
    if (point == null || point.isInfinity) throw const FormatException('مفتاح الموبايل مش صحيح');
    final agreement = pc.ECDHBasicAgreement()..init(pc.ECPrivateKey(_bytesToBig(privateKey), _curve));
    return _bigToBytes(agreement.calculateAgreement(pc.ECPublicKey(point, _curve)), 32);
  }

  /// توقيع ES256 (r || s، 64 بايت) زي ما JWT بيطلب.
  Uint8List signEs256(List<int> message) {
    final signer = pc.Signer('SHA-256/DET-ECDSA')..init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(pc.ECPrivateKey(_bytesToBig(privateKey), _curve)));
    final sig = signer.generateSignature(Uint8List.fromList(message)) as pc.ECSignature;
    return Uint8List.fromList([..._bigToBytes(sig.r, 32), ..._bigToBytes(sig.s, 32)]);
  }
}

Uint8List _hmac(List<int> key, List<int> data) => Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

/// تشفير رسالة لاشتراك واحد (RFC 8291). [asKeys] و[salt] للاختبار بس (قيم RFC)، وغير كده عشوائيين.
Future<Uint8List> encryptPush(List<int> plaintext, {required Uint8List uaPublic, required Uint8List authSecret, P256Keys? asKeys, Uint8List? salt}) async {
  final keys = asKeys ?? P256Keys.generate();
  final s = salt ?? Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
  final ecdhSecret = keys.ecdh(uaPublic);
  final prkKey = _hmac(authSecret, ecdhSecret);
  final keyInfo = [...utf8.encode('WebPush: info'), 0, ...uaPublic, ...keys.publicKey];
  final ikm = _hmac(prkKey, [...keyInfo, 1]);
  final prk = _hmac(s, ikm);
  final cek = _hmac(prk, [...utf8.encode('Content-Encoding: aes128gcm'), 0, 1]).sublist(0, 16);
  final nonce = _hmac(prk, [...utf8.encode('Content-Encoding: nonce'), 0, 1]).sublist(0, 12);
  final box = await AesGcm.with128bits().encrypt([...plaintext, 2], secretKey: SecretKey(cek), nonce: nonce);
  final header = BytesBuilder()
    ..add(s)
    ..add([0, 0, 16, 0]) // حجم السجل 4096
    ..addByte(keys.publicKey.length)
    ..add(keys.publicKey);
  return Uint8List.fromList([...header.toBytes(), ...box.cipherText, ...box.mac.bytes]);
}

/// اشتراك موبايل واحد (من PushSubscription.toJSON() في المتصفح).
class PushSubscriptionData {
  PushSubscriptionData({required this.endpoint, required this.p256dh, required this.auth});

  factory PushSubscriptionData.fromJson(Map<String, dynamic> j) {
    final keys = (j['keys'] as Map).cast<String, dynamic>();
    return PushSubscriptionData(endpoint: j['endpoint'] as String, p256dh: keys['p256dh'] as String, auth: keys['auth'] as String);
  }

  final String endpoint;
  final String p256dh;
  final String auth;

  /// خدمات الإشعارات المعروفة بس (Apple وGoogle وMozilla وMicrosoft)، عشان محدش يخلّي الكمبيوتر يكلّم سيرفر تاني.
  bool get trustedEndpoint {
    final u = Uri.tryParse(endpoint);
    if (u == null || u.scheme != 'https') return false;
    const hosts = ['push.apple.com', 'fcm.googleapis.com', 'push.services.mozilla.com', 'notify.windows.com', 'android.googleapis.com'];
    return hosts.any((h) => u.host == h || u.host.endsWith('.$h'));
  }
}

/// JWT بتاع VAPID: الخدمة بتعرف إن الرسالة من صاحب المفتاح اللي الموبايل اشترك بيه.
String vapidJwt(P256Keys keys, String endpoint, String subject, {DateTime? now}) {
  final u = Uri.parse(endpoint);
  final exp = (now ?? DateTime.now()).add(const Duration(hours: 12)).millisecondsSinceEpoch ~/ 1000;
  final head = b64url(utf8.encode(jsonEncode({'typ': 'JWT', 'alg': 'ES256'})));
  final body = b64url(utf8.encode(jsonEncode({'aud': '${u.scheme}://${u.host}', 'exp': exp, 'sub': subject})));
  final signed = '$head.$body';
  return '$signed.${b64url(keys.signEs256(utf8.encode(signed)))}';
}

enum PushResult { sent, gone, failed }

/// بيبعت رسالة لاشتراك واحد. gone = الموبايل لغى الاشتراك (لازم يتمسح).
Future<PushResult> sendPush(http.Client client, PushSubscriptionData sub, Map<String, Object?> message, {required P256Keys vapid, required String subject}) async {
  if (!sub.trustedEndpoint) return PushResult.gone;
  final body = await encryptPush(utf8.encode(jsonEncode(message)), uaPublic: unb64url(sub.p256dh), authSecret: unb64url(sub.auth));
  final res = await client
      .post(Uri.parse(sub.endpoint), headers: {
        'authorization': 'vapid t=${vapidJwt(vapid, sub.endpoint, subject)}, k=${b64url(vapid.publicKey)}',
        'content-encoding': 'aes128gcm',
        'content-type': 'application/octet-stream',
        'ttl': '86400',
        'urgency': 'high',
      }, body: body)
      .timeout(const Duration(seconds: 20));
  if (res.statusCode == 404 || res.statusCode == 410) return PushResult.gone;
  return res.statusCode >= 200 && res.statusCode < 300 ? PushResult.sent : PushResult.failed;
}
