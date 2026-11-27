/// إشعارات المالك في المتصفح (Web Push): الاشتراك بيتعمل بـ JavaScript صغير في صفحة أبلكيشن المالك
/// (web_owner/index.html)، وعلى أي حاجة غير الويب مش متاحة.
library;

export 'owner_push_stub.dart' if (dart.library.js_interop) 'owner_push_web.dart';
