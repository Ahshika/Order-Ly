/// مشروع Firebase بتاع Order Ly (واحد لكل الكافيهات). المفتاح ده عام ومعمول يتحط في التطبيقات؛
/// الحماية الحقيقية في قواعد قاعدة البيانات (firebase/database.rules.json).
const firebaseProjectId = 'orderly-yvzug';
const firebaseApiKey = 'AIzaSyBXKteV9D9ityE9-1dpzclk9Qckd6JtHTo';

/// Realtime Database: الطلبات بتوصل منها للكاشير لحظياً.
const rtdbUrl = 'https://orderly-yvzug-default-rtdb.europe-west1.firebasedatabase.app';

/// موقع منيو العملاء (اللي الـ QR بيفتحه) ودليل الاستخدام.
const menuSiteUrl = 'https://orderly-yvzug.web.app';

/// العناوين اللي السيرفر بيكلمها على Firebase. الاختبارات بتحط Firebase وهمي على الجهاز.
class FirebaseEndpoints {
  const FirebaseEndpoints({
    required this.apiKey,
    required this.rtdb,
    this.auth = 'https://identitytoolkit.googleapis.com',
    this.token = 'https://securetoken.googleapis.com',
  });

  final String apiKey;
  final String rtdb;
  final String auth;
  final String token;

  static const live = FirebaseEndpoints(apiKey: firebaseApiKey, rtdb: rtdbUrl);
}
