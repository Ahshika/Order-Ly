import 'dart:convert';

import 'package:http/http.dart' as http;

/// ربط أبلكيشن المالك بالمحل: مشروع Firebase بتاع المحل، والفرع الرئيسي، وحساب المالك عليه.
/// كله بييجي من لينك الـ QR اللي بيظهر على الفرع الرئيسي (routes_owner.dart في السيرفر).
class OwnerLink {
  OwnerLink({required this.apiKey, required this.dbHost, required this.main, required this.ownerUid, required this.email, required this.refreshToken});

  factory OwnerLink.fromJson(Map<String, dynamic> j) => OwnerLink(
        apiKey: j['k'] as String,
        dbHost: j['d'] as String,
        main: j['m'] as String,
        ownerUid: j['u'] as String,
        email: j['e'] as String,
        refreshToken: j['r'] as String,
      );

  final String apiKey;
  final String dbHost;
  final String main;
  final String ownerUid;
  final String email;
  String refreshToken;

  Map<String, Object?> toJson() => {'k': apiKey, 'd': dbHost, 'm': main, 'u': ownerUid, 'e': email, 'r': refreshToken};
}

/// اللي جاي في لينك الـ QR: ?c=الكود&m=الرئيسي&k=مفتاح المشروع&d=الداتابيز
class OwnerInvite {
  OwnerInvite({required this.code, required this.main, required this.apiKey, required this.dbHost});

  static OwnerInvite? fromUri(Uri uri) {
    final q = uri.queryParameters;
    final code = q['c'] ?? '', main = q['m'] ?? '', key = q['k'] ?? '', db = q['d'] ?? '';
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(code)) return null;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(main) || !RegExp(r'^[A-Za-z0-9_-]{10,80}$').hasMatch(key)) return null;
    // داتابيز Firebase بس (نفس شرط صفحة المنيو)
    if (!RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)?\.(firebasedatabase\.app|firebaseio\.com)$').hasMatch(db)) return null;
    return OwnerInvite(code: code, main: main, apiKey: key, dbHost: db);
  }

  final String code;
  final String main;
  final String apiKey;
  final String dbHost;
}

class OwnerCloudException implements Exception {
  OwnerCloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// كلام المالك مع Firebase (REST): الدخول، والقراية، والكتابة.
class OwnerCloud {
  OwnerCloud(this.link, {http.Client? client}) : _http = client ?? http.Client();

  final OwnerLink link;
  final http.Client _http;
  String? _idToken;
  DateTime _expiry = DateTime(2000);

  /// بيتنادى لما التوكن الجديد يطلع (عشان يتحفظ).
  void Function(OwnerLink link)? onRefresh;

  static String _authError(String body) {
    final m = RegExp(r'"message"\s*:\s*"([A-Z_]+)').firstMatch(body)?[1] ?? '';
    return switch (m) {
      'EMAIL_EXISTS' => 'الإيميل ده عليه حساب بالفعل. اختار "عندي حساب"',
      'EMAIL_NOT_FOUND' || 'INVALID_LOGIN_CREDENTIALS' || 'INVALID_PASSWORD' => 'الإيميل أو كلمة السر غلط',
      'WEAK_PASSWORD' => 'كلمة السر لازم 6 حروف على الأقل',
      'INVALID_EMAIL' => 'الإيميل مش صحيح',
      'TOO_MANY_ATTEMPTS_TRY_LATER' => 'محاولات كتير. استنى شوية وجرّب تاني',
      'OPERATION_NOT_ALLOWED' => 'الدخول بالإيميل مقفول على مشروع المحل (لازم يتفعّل من Firebase)',
      _ => 'مشكلة في الدخول ($m)',
    };
  }

  /// دخول أو حساب جديد على مشروع المحل. بيرجع (uid، refreshToken، idToken).
  static Future<(String, String, String)> authenticate(String apiKey, String email, String password, {required bool create, http.Client? client}) async {
    final c = client ?? http.Client();
    final endpoint = create ? 'signUp' : 'signInWithPassword';
    final http.Response res;
    try {
      res = await c
          .post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:$endpoint?key=$apiKey'),
              headers: {'content-type': 'application/json'}, body: jsonEncode({'email': email.trim(), 'password': password, 'returnSecureToken': true}))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw OwnerCloudException('مفيش نت. اتأكد من الاتصال وجرّب تاني');
    }
    if (res.statusCode != 200) throw OwnerCloudException(_authError(res.body));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (j['localId'] as String, j['refreshToken'] as String, j['idToken'] as String);
  }

  Future<String> _token() async {
    if (_idToken != null && DateTime.now().isBefore(_expiry)) return _idToken!;
    final res = await _http
        .post(Uri.parse('https://securetoken.googleapis.com/v1/token?key=${link.apiKey}'), body: {'grant_type': 'refresh_token', 'refresh_token': link.refreshToken})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw OwnerCloudException('الدخول انتهى. سجّل دخول تاني');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    _idToken = j['id_token'] as String;
    _expiry = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expires_in']}') ?? 3600) - 120));
    if (j['refresh_token'] != link.refreshToken) {
      link.refreshToken = j['refresh_token'] as String;
      onRefresh?.call(link);
    }
    return _idToken!;
  }

  void useToken(String idToken) {
    _idToken = idToken;
    _expiry = DateTime.now().add(const Duration(minutes: 50));
  }

  Uri _url(String path, String token, [Map<String, String>? q]) => Uri.parse('https://${link.dbHost}/$path.json').replace(queryParameters: {'auth': token, ...?q});

  Future<Object?> get(String path, {bool shallow = false}) async {
    try {
      final res = await _http.get(_url(path, await _token(), shallow ? {'shallow': 'true'} : null)).timeout(const Duration(seconds: 25));
      if (res.statusCode == 401 || res.statusCode == 403) throw OwnerCloudException('مش مسموحلك تشوف ده (يمكن الفرع الرئيسي شالك)');
      if (res.statusCode != 200) throw OwnerCloudException('Firebase رد بـ ${res.statusCode}');
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on OwnerCloudException {
      rethrow;
    } catch (_) {
      throw OwnerCloudException('مفيش نت. اتأكد من الاتصال وجرّب تاني');
    }
  }

  /// كتابة من غير ما Firebase يرجّع اللي اتكتب (print=silent).
  Future<void> put(String path, Object? value) async {
    final res = await _http.put(_url(path, await _token(), {'print': 'silent'}), body: jsonEncode(value)).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200 && res.statusCode != 204) throw OwnerCloudException('Firebase رفض (${res.statusCode})');
  }
}
