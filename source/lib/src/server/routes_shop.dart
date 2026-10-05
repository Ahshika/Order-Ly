part of 'api_server.dart';

const receiptPapers = {'80mm', '58mm', 'a5', 'a4'};

/// إعدادات الكافيه الافتراضية (بتتخزن JSON في settings.cafe).
const defaultCafeSettings = <String, Object?>{
  // الخدمة والضريبة بالـ basis points (1200 = 12%)
  'serviceBp': 0,
  'taxBp': 0,
  // الخدمة على الصالة بس ولا على التيك أواي كمان
  'serviceOnTakeaway': false,
  'receiptPaper': '80mm',
  'receiptFooter': 'شكراً لزيارتكم، نورتونا',
  'cashierCanDiscount': true,
  // إلغاء صنف بعد ما اتبعت للبار/المطبخ محتاج المالك
  'voidNeedsOwner': false,
  // ----- منيو العميل (QR)
  'qrEnabled': true,
  // manual: كل طلب لازم الكاشير يوافق عليه. auto: بيتقبل لوحده. (والترابيزة ممكن يبقى ليها إعداد خاص)
  'qrApproval': 'manual',
  // الطلبات من الـ QR بتتقبل بس والدرج مفتوح (يعني الكافيه شغال)
  'qrNeedsOpenRegister': true,
  // العميل لازم يكتب اسمه ورقم موبايله قبل ما يبعت الطلب
  'qrRequireContact': true,
  'qrWelcome': '',
  'wifiName': '',
  'wifiPassword': '',
  'menuLanguages': 'ar_en',
  // ----- نقط الولاء
  'loyaltyEnabled': false,
  // نقطة لكل كام جنيه (بالقروش)
  'loyaltyEarnCents': 1000,
  // قيمة النقطة الواحدة لما تتصرف (بالقروش)
  'loyaltyPointValue': 25,
  'loyaltyMinRedeem': 100,
};

extension _ShopRoutes on OrderlyServer {
  void _registerShopRoutes(Router r) {
    r.get('/api/shop', _authed((req, u) => _shopJson()));
    r.patch('/api/shop', _authed(_updateShop, only: {'owner'}));
    r.put('/api/shop/logo', _authed(_setLogo, only: {'owner'}));
    r.delete('/api/shop/logo', _authed((req, u) {
      final f = File(p.join(dataDir, 'logo.png'));
      if (f.existsSync()) f.deleteSync();
      _broadcast('shop');
      return {'ok': true};
    }, only: {'owner'}));

    r.post('/api/cloud/sync', _authed((req, u) async {
      await syncNow();
      return _shopJson();
    }, only: {'owner'}));

    r.get('/api/files/<id>', _authed(_serveFile));
  }

  /// أول ما الكافيه يتسجل: بار ومطبخ، وصالة، وطرق الدفع الأساسية.
  void _seedDefaults(String now) {
    db.execute('INSERT INTO stations(id, name, sort, created_at) VALUES(?, ?, 0, ?)', [_uuid.v4(), 'البار', now]);
    db.execute('INSERT INTO stations(id, name, sort, created_at) VALUES(?, ?, 1, ?)', [_uuid.v4(), 'المطبخ', now]);
    db.execute('INSERT INTO areas(id, name, sort, created_at) VALUES(?, ?, 0, ?)', [_uuid.v4(), 'الصالة', now]);
    db.execute(
      "INSERT INTO pay_methods(id, name, kind, show_in_qr, sort, created_at) VALUES(?, 'كاش', 'cash', 1, 0, ?)",
      [_uuid.v4(), now],
    );
    db.execute(
      "INSERT INTO pay_methods(id, name, kind, show_in_qr, sort, created_at) VALUES(?, 'فيزا', 'card', 1, 1, ?)",
      [_uuid.v4(), now],
    );
  }

  // ---------------------------------------------------------------- settings

  Map<String, Object?> _jsonSetting(String key, Map<String, Object?> defaults) {
    final raw = db.setting(key);
    if (raw == null) return {...defaults};
    try {
      return {...defaults, ...(jsonDecode(raw) as Map<String, dynamic>)};
    } catch (_) {
      return {...defaults};
    }
  }

  Map<String, Object?> get _cafe => _jsonSetting('cafe', defaultCafeSettings);
  int _cafeInt(String key) => _cafe[key] as int? ?? defaultCafeSettings[key] as int;
  bool _cafeBool(String key) => _cafe[key] as bool? ?? defaultCafeSettings[key] as bool;

  Map<String, Object?> _shopJson() {
    final shop = db.selectOne('SELECT * FROM shop LIMIT 1');
    final branch = db.selectOne('SELECT * FROM branches WHERE is_local = 1 LIMIT 1');
    final logo = File(p.join(dataDir, 'logo.png'));
    return {
      'name': shop?['name'],
      'phone': shop?['phone'],
      'address': shop?['address'],
      'branchName': branch?['name'],
      'logoBase64': logo.existsSync() ? base64.encode(logo.readAsBytesSync()) : null,
      'settings': _cafe,
      'menuBaseUrl': menuSiteUrl,
      'cloud': {
        'cafeId': db.setting('cloud_uid'),
        'lastSync': db.setting('cloud_last_sync'),
        'lastError': db.setting('cloud_last_error'),
        'live': _cloud?.live ?? false,
      },
    };
  }

  Future<Object?> _updateShop(Request req, AuthUser u) async {
    final body = await _body(req);
    final shop = db.selectOne('SELECT id FROM shop LIMIT 1');
    if (shop == null) throw ApiError(400, 'الكافيه لسه ما اتسجلش');

    db.transaction(() {
      if (body.containsKey('name')) {
        db.execute('UPDATE shop SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم الكافيه'), shop['id']]);
      }
      for (final key in ['phone', 'address']) {
        if (body.containsKey(key)) {
          db.execute('UPDATE shop SET $key = ? WHERE id = ?', [_optionalText(body, key), shop['id']]);
          db.execute('UPDATE branches SET $key = ? WHERE is_local = 1', [_optionalText(body, key)]);
        }
      }
      if (body.containsKey('branchName')) {
        db.execute('UPDATE branches SET name = ? WHERE is_local = 1', [_requiredText(body, 'branchName', 'اسم الفرع')]);
      }
      if (body['settings'] is Map) {
        final current = _cafe;
        (body['settings'] as Map).forEach((k, v) {
          final key = k as String;
          if (!defaultCafeSettings.containsKey(key)) return;
          final def = defaultCafeSettings[key];
          if (def is int && v is int) {
            current[key] = switch (key) {
              'serviceBp' || 'taxBp' => v.clamp(0, 5000),
              _ => v.clamp(0, 100000000),
            };
          } else if (def is bool && v is bool) {
            current[key] = v;
          } else if (def is String && v is String) {
            if (v.length > 500) throw ApiError(400, 'النص طويل جداً');
            if (key == 'receiptPaper' && !receiptPapers.contains(v)) throw ApiError(400, 'مقاس الورق مش صحيح');
            if (key == 'qrApproval' && !const {'manual', 'auto'}.contains(v)) throw ApiError(400, 'اختيار مش صحيح');
            if (key == 'menuLanguages' && !const {'ar', 'ar_en', 'en'}.contains(v)) throw ApiError(400, 'اختيار مش صحيح');
            current[key] = v.trim();
          }
        });
        db.setSetting('cafe', jsonEncode(current));
      }
    });
    _audit(u.id, 'shop.update', 'shop', shop['id'] as String, body.keys.join('، '));
    _broadcast('shop');
    return _shopJson();
  }

  Future<Object?> _setLogo(Request req, AuthUser u) async {
    final body = await _body(req);
    final List<int> bytes;
    try {
      bytes = base64.decode(body['png'] as String? ?? '');
    } catch (_) {
      throw ApiError(400, 'الصورة مش صحيحة');
    }
    const pngMagic = [0x89, 0x50, 0x4E, 0x47];
    if (bytes.length < 8 || !List.generate(4, (i) => bytes[i] == pngMagic[i]).every((b) => b)) {
      throw ApiError(400, 'الصورة لازم تكون PNG');
    }
    if (bytes.length > 1024 * 1024) throw ApiError(400, 'الصورة كبيرة جداً');
    File(p.join(dataDir, 'logo.png')).writeAsBytesSync(bytes);
    _audit(u.id, 'shop.logo', 'shop', null, null);
    _broadcast('shop');
    return {'ok': true};
  }

  // ---------------------------------------------------------------- files (صور المنيو وصور التحويلات)

  Directory get _filesDir => Directory(p.join(dataDir, 'files'))..createSync(recursive: true);

  /// بيصغّر الصورة في Isolate لوحده (عشان السيرفر يفضل يرد على باقي الأجهزة) وبيحفظها.
  Future<String> _saveImage(List<int> bytes, String kind, String? userId, {int maxSide = 800, int quality = 80}) async {
    final jpg = await shrinkInBackground(bytes, maxSide, quality);
    if (jpg == null) throw ApiError(400, 'الصورة مش صحيحة');
    return _storeJpeg(jpg, kind, userId);
  }

  /// بيحفظ صورة JPEG جاهزة (متصغرة قبل كده).
  String _storeJpeg(List<int> jpg, String kind, String? userId) {
    final id = _uuid.v4();
    File(p.join(_filesDir.path, id)).writeAsBytesSync(jpg);
    db.execute(
      'INSERT INTO files(id, kind, mime, size, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?)',
      [id, kind, 'image/jpeg', jpg.length, userId, nowIso()],
    );
    return id;
  }

  List<int> _decodeImageBody(Map<String, dynamic> body) {
    try {
      final bytes = base64.decode(body['base64'] as String? ?? '');
      if (bytes.isEmpty) throw ApiError(400, 'مفيش صورة');
      if (bytes.length > 8 * 1024 * 1024) throw ApiError(400, 'الصورة كبيرة جداً (أقصى حاجة 8 ميجا)');
      return bytes;
    } on FormatException {
      throw ApiError(400, 'الصورة مش صحيحة');
    }
  }

  void _deleteFile(String? id) {
    if (id == null) return;
    db.execute('DELETE FROM files WHERE id = ?', [id]);
    final f = File(p.join(_filesDir.path, id));
    if (f.existsSync()) f.deleteSync();
  }

  Object? _serveFile(Request req, AuthUser u) {
    final id = req.params['id']!;
    final row = db.selectOne('SELECT * FROM files WHERE id = ?', [id]);
    final f = File(p.join(_filesDir.path, p.basename(id)));
    if (row == null || !f.existsSync()) throw ApiError(404, 'الملف مش موجود');
    return Response.ok(f.readAsBytesSync(), headers: {
      'content-type': row['mime'] as String,
      'cache-control': 'private, max-age=31536000, immutable',
    });
  }
}

/// نفس [shrinkToJpeg] بس في Isolate لوحده (عشان السيرفر ما يقفش).
Future<List<int>?> shrinkInBackground(List<int> bytes, int maxSide, int quality) => Isolate.run(() => shrinkToJpeg(bytes, maxSide, quality));

String _logoInIsolate(List<int> bytes) {
  final decoded = img.decodeImage(Uint8List.fromList(bytes));
  if (decoded == null) return '';
  final small = decoded.width > 160 ? img.copyResize(decoded, width: 160) : decoded;
  return base64.encode(img.encodePng(small));
}

Future<String> smallLogoInBackground(List<int> bytes) => Isolate.run(() => _logoInIsolate(bytes));

/// تصغير صورة لأقصى عرض/طول [maxSide] وتحويلها JPEG. null لو الملف مش صورة.
List<int>? shrinkToJpeg(List<int> bytes, int maxSide, int quality) {
  final decoded = img.decodeImage(Uint8List.fromList(bytes));
  if (decoded == null) return null;
  var image = decoded;
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height ? img.copyResize(image, width: maxSide) : img.copyResize(image, height: maxSide);
  }
  return img.encodeJpg(image, quality: quality);
}
