// تشفير إشعارات المالك (RFC 8291) وتوقيع VAPID (RFC 8292)، بقيم الـ RFC الرسمية.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderly/src/server/web_push.dart';
import 'package:pointycastle/export.dart' as pc;

/// فك التشفير زي ما الموبايل بيعمل (عشان نتأكد إن أي رسالة عشوائية بتتفك صح).
Future<List<int>> decryptLikePhone(Uint8List body, P256Keys ua, Uint8List auth) async {
  final salt = body.sublist(0, 16);
  final idlen = body[20];
  final asPublic = body.sublist(21, 21 + idlen);
  final cipher = body.sublist(21 + idlen);
  Uint8List h(List<int> k, List<int> d) => Uint8List.fromList(c.Hmac(c.sha256, k).convert(d).bytes);
  final ecdh = ua.ecdh(asPublic);
  final ikm = h(h(auth, ecdh), [...utf8.encode('WebPush: info'), 0, ...ua.publicKey, ...asPublic, 1]);
  final prk = h(salt, ikm);
  final cek = h(prk, [...utf8.encode('Content-Encoding: aes128gcm'), 0, 1]).sublist(0, 16);
  final nonce = h(prk, [...utf8.encode('Content-Encoding: nonce'), 0, 1]).sublist(0, 12);
  final plain = await AesGcm.with128bits().decrypt(
    SecretBox(cipher.sublist(0, cipher.length - 16), nonce: nonce, mac: Mac(cipher.sublist(cipher.length - 16))),
    secretKey: SecretKey(cek),
  );
  expect(plain.last, 2, reason: 'padding delimiter');
  return plain.sublist(0, plain.length - 1);
}

void main() {
  test('RFC 8291 appendix A: exactly the published result', () async {
    final as = P256Keys.fromPrivate(unb64url('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'));
    expect(b64url(as.publicKey), 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8');
    final ua = P256Keys.fromPrivate(unb64url('q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94'));
    expect(b64url(ua.publicKey), 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4');
    expect(b64url(as.ecdh(ua.publicKey)), 'kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs');

    final body = await encryptPush(
      unb64url('V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24'),
      uaPublic: ua.publicKey,
      authSecret: unb64url('BTBZMqHH6r4Tts7J_aSIgg'),
      asKeys: as,
      salt: unb64url('DGv6ra1nlYgDCS1FRnbzlw'),
    );
    // RFC 8291 section 5: الرسالة المتشفرة كلها (145 بايت)
    expect(
      b64url(body),
      'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml'
      'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT'
      'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
    );
    // وملحق A: الجزء المتشفر لوحده
    expect(body.sublist(86), unb64url('8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ'));
  });

  test('random keys and salt: what the phone decrypts is exactly what was sent', () async {
    final ua = P256Keys.generate();
    final auth = Uint8List.fromList(List.generate(16, (i) => i * 7));
    final msg = utf8.encode(jsonEncode({'title': 'قفل وردية', 'body': 'فرع المعادي • 12,450 ج.م'}));
    final a = await encryptPush(msg, uaPublic: ua.publicKey, authSecret: auth);
    final b = await encryptPush(msg, uaPublic: ua.publicKey, authSecret: auth);
    expect(a, isNot(b), reason: 'every message has its own key and salt');
    expect(utf8.decode(await decryptLikePhone(a, ua, auth)), utf8.decode(msg));
  });

  test('VAPID JWT: ES256 signature verifies with the public key, audience is the push origin', () {
    final keys = P256Keys.generate();
    final jwt = vapidJwt(keys, 'https://web.push.apple.com/QGuQyavXutnMH', 'https://orderly-cafe-28129.web.app', now: DateTime.utc(2026, 11, 23));
    final parts = jwt.split('.');
    final claims = jsonDecode(utf8.decode(unb64url(parts[1]))) as Map;
    expect(claims['aud'], 'https://web.push.apple.com');
    expect(claims['sub'], 'https://orderly-cafe-28129.web.app');
    final sig = unb64url(parts[2]);
    expect(sig.length, 64);
    BigInt big(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
    final curve = pc.ECDomainParameters('prime256v1');
    final verifier = pc.Signer('SHA-256/ECDSA')..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(curve.curve.decodePoint(keys.publicKey), curve)));
    expect(verifier.verifySignature(Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')), pc.ECSignature(big(sig.sublist(0, 32)), big(sig.sublist(32)))), isTrue);
  });

  test('only known push services are contacted', () {
    PushSubscriptionData sub(String e) => PushSubscriptionData(endpoint: e, p256dh: 'x', auth: 'y');
    expect(sub('https://web.push.apple.com/abc').trustedEndpoint, isTrue);
    expect(sub('https://fcm.googleapis.com/fcm/send/abc').trustedEndpoint, isTrue);
    expect(sub('https://updates.push.services.mozilla.com/wpush/v2/abc').trustedEndpoint, isTrue);
    expect(sub('http://web.push.apple.com/abc').trustedEndpoint, isFalse);
    expect(sub('https://evil.example.com/abc').trustedEndpoint, isFalse);
    expect(sub('https://push.apple.com.evil.com/abc').trustedEndpoint, isFalse);
    expect(sub('https://192.168.1.10/abc').trustedEndpoint, isFalse);
  });
}
