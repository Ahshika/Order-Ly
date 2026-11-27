/// مشروع Firebase الأساسي بتاع Order Ly. المفتاح ده عام ومعمول يتحط في التطبيقات؛
/// الحماية الحقيقية في قواعد قاعدة البيانات (firebase/database.rules.json).
///
/// كل محل ممكن يبقى له مشروع Firebase بتاعه (حدود الخطة المجانية لكل مشروع لوحده): إعداداته بتيجي
/// جوه كود التفعيل ([FirebaseProject])، ولو مفيش، المحل بيشتغل على المشروع ده.
/// صفحة منيو العملاء واحدة لكل المحلات (على المشروع ده، على أكونت ahmedhassanshika655)، وبتعرف داتابيز المحل من اللينك (?d=).
const firebaseProjectId = 'orderly-cafe-28129';
/// المفتاح مش مكتوب في الكود: بييجي وقت البناء من config/firebase.json (متجاهل في git):
///   flutter build ... --dart-define-from-file=config/firebase.json
/// انسخ config/firebase.example.json لـ config/firebase.json وحط المفتاح فيه.
const firebaseApiKey = String.fromEnvironment('ORDERLY_FIREBASE_API_KEY');

/// Realtime Database: الطلبات بتوصل منها للكاشير لحظياً.
const rtdbUrl = 'https://orderly-cafe-28129-default-rtdb.europe-west1.firebasedatabase.app';

/// موقع منيو العملاء (اللي الـ QR بيفتحه) ودليل الاستخدام.
const menuSiteUrl = 'https://orderly-cafe-28129.web.app';

/// عنوان Realtime Database صحيح على Firebase (https، ومن غير مسار). نفس الشرط موجود في صفحة المنيو.
final _databaseHostRe = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)?\.(firebasedatabase\.app|firebaseio\.com)$');

/// مشروع Firebase خاص بمحل (بييجي جوه كود التفعيل المتوقّع، فمحدش يقدر يغيّره).
class FirebaseProject {
  FirebaseProject({required this.projectId, required this.apiKey, required this.databaseUrl}) {
    if (!RegExp(r'^[a-z0-9-]{4,40}$').hasMatch(projectId)) throw const FormatException('اسم مشروع Firebase مش صحيح');
    if (!RegExp(r'^[A-Za-z0-9_-]{20,60}$').hasMatch(apiKey)) throw const FormatException('مفتاح Firebase مش صحيح');
    final uri = Uri.tryParse(databaseUrl);
    if (uri == null || uri.scheme != 'https' || uri.path.replaceAll('/', '').isNotEmpty || !_databaseHostRe.hasMatch(uri.host)) {
      throw const FormatException('عنوان Realtime Database لازم يكون زي https://xxx-default-rtdb.europe-west1.firebasedatabase.app');
    }
  }

  factory FirebaseProject.fromJson(Map<String, dynamic> j) =>
      FirebaseProject(projectId: j['p'] as String, apiKey: j['k'] as String, databaseUrl: j['d'] as String);

  final String projectId;
  final String apiKey;
  final String databaseUrl;

  Map<String, Object?> toJson() => {'p': projectId, 'k': apiKey, 'd': databaseUrl.replaceAll(RegExp(r'/+$'), '')};
}

/// العناوين اللي السيرفر بيكلمها على Firebase. الاختبارات بتحط Firebase وهمي على الجهاز.
class FirebaseEndpoints {
  const FirebaseEndpoints({
    required this.apiKey,
    required this.rtdb,
    this.projectId = firebaseProjectId,
    this.auth = 'https://identitytoolkit.googleapis.com',
    this.token = 'https://securetoken.googleapis.com',
  });

  factory FirebaseEndpoints.forProject(FirebaseProject p) =>
      FirebaseEndpoints(apiKey: p.apiKey, rtdb: p.databaseUrl.replaceAll(RegExp(r'/+$'), ''), projectId: p.projectId);

  final String projectId;
  final String apiKey;
  final String rtdb;
  final String auth;
  final String token;

  /// اللي بيتكتب في لينك الـ QR (?d=) عشان صفحة المنيو تكلّم داتابيز المحل. null = المشروع الأساسي.
  String? get menuDatabaseParam => rtdb == rtdbUrl ? null : Uri.parse(rtdb).host;

  static const live = FirebaseEndpoints(apiKey: firebaseApiKey, rtdb: rtdbUrl);
}
