import 'package:url_launcher/url_launcher.dart';

/// بيفتح واتساب على رقم معين ومعاه رسالة جاهزة.
Future<bool> openWhatsApp(String internationalNumber, String text) async {
  final uri = Uri.parse('https://wa.me/$internationalNumber?text=${Uri.encodeComponent(text)}');
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
