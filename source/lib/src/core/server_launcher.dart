/// تشغيل سيرفر الكافيه جوه البرنامج (الكمبيوتر اللي عليه الكاشير). نسخة الويب (الأيفون) مافيهاش سيرفر:
/// الصفحة نفسها جاية من سيرفر الكافيه، وكود السيرفر (sqlite3) مابيشتغلش في المتصفح أصلاً.
library;

export 'server_launcher_io.dart' if (dart.library.js_interop) 'server_launcher_web.dart';
