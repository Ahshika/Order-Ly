part of 'api_server.dart';

/// نسخة الويب للموظفين (الأيفون والتابلت من غير ما يتسطب حاجة): السيرفر بيقدّم ملفات `flutter build web`
/// على نفس البورت، فالموبايل بيفتح `http://<IP الكاشير>:8753` ويضيفها للشاشة الرئيسية.
/// نفس العنوان بتاع الـ API، فمفيش CORS ولا إعدادات. ومن غير نت خالص (كل الملفات جوه البرنامج).
///
/// الملفات بتتدور في: ORDERLY_WEB_DIR، وبعدين فولدر web جنب البرنامج (المثبّت)، وبعدين build/web (التطوير).
extension _WebApp on OrderlyServer {
  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'wasm': 'application/wasm',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'ico': 'image/x-icon',
    'svg': 'image/svg+xml',
    'css': 'text/css; charset=utf-8',
    'otf': 'font/otf',
    'ttf': 'font/ttf',
    'woff2': 'font/woff2',
    'wav': 'audio/wav',
    'mp3': 'audio/mpeg',
    'txt': 'text/plain; charset=utf-8',
  };

  static String? _findWebDir() {
    final candidates = [
      Platform.environment['ORDERLY_WEB_DIR'],
      p.join(p.dirname(Platform.resolvedExecutable), 'web'),
      p.join(Directory.current.path, 'build', 'web'),
    ];
    for (final c in candidates) {
      if (c != null && c.isNotEmpty && File(p.join(c, 'index.html')).existsSync()) return p.canonicalize(c);
    }
    return null;
  }

  Response _webApp(Request req) {
    if (req.method != 'GET' && req.method != 'HEAD') return _json(405, {'error': 'مش مسموح'});
    final dir = webDir;
    if (dir == null || !File(p.join(dir, 'index.html')).existsSync()) {
      return Response.notFound('<!doctype html><meta charset="utf-8"><p dir="rtl">نسخة الويب مش موجودة على الكمبيوتر ده. حدّث البرنامج.</p>',
          headers: {'content-type': 'text/html; charset=utf-8'});
    }
    final segments = req.url.pathSegments.where((s) => s.isNotEmpty).toList();
    // ".." أو "\" أو ":" في أي جزء = محاولة توصل لملف بره الفولدر
    if (segments.any((s) => s == '..' || s == '.' || s.contains('\\') || s.contains(':') || s.contains('\u0000'))) {
      return Response.notFound('');
    }
    var file = File(p.joinAll([dir, ...segments]));
    if (segments.isEmpty || FileSystemEntity.isDirectorySync(file.path)) file = File(p.join(dir, 'index.html'));
    final path = p.canonicalize(file.path);
    if (!p.isWithin(dir, path)) return Response.notFound('');
    if (!file.existsSync()) {
      // مسار من غير امتداد = صفحة جوه البرنامج: الصفحة الرئيسية بتتعامل معاها
      if (segments.isNotEmpty && !segments.last.contains('.')) file = File(p.join(dir, 'index.html'));
      if (!file.existsSync()) return Response.notFound('');
    }
    final stat = file.statSync();
    final etag = '"${stat.size.toRadixString(16)}-${stat.modified.millisecondsSinceEpoch.toRadixString(16)}"';
    final headers = {
      'content-type': _types[p.extension(file.path).replaceFirst('.', '').toLowerCase()] ?? 'application/octet-stream',
      // الأيفون بيتأكد كل مرة (304 لو ماتغيرش): تحديث البرنامج على الكاشير بيوصل للموظفين على طول
      'cache-control': 'no-cache',
      'etag': etag,
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    };
    if (req.headers['if-none-match'] == etag) return Response.notModified(headers: headers);
    return Response.ok(req.method == 'HEAD' ? null : file.openRead(), headers: {...headers, 'content-length': '${stat.size}'});
  }
}
