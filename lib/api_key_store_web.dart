// ignore_for_file: avoid_web_libraries_in_flutter

// ignore: deprecated_member_use
import 'dart:html' as html;

const _apiKeyCookieName = 'wilddex_openai_api_key';

Future<String> loadStoredOpenAiKey() async {
  final cookies = html.document.cookie?.split(';') ?? const [];
  for (final cookie in cookies) {
    final parts = cookie.trim().split('=');
    if (parts.length < 2) continue;
    if (parts.first == _apiKeyCookieName) {
      return Uri.decodeComponent(parts.sublist(1).join('='));
    }
  }
  return '';
}

Future<void> saveStoredOpenAiKey(String key) async {
  final secure = html.window.location.protocol == 'https:' ? '; Secure' : '';
  html.document.cookie =
      '$_apiKeyCookieName=${Uri.encodeComponent(key.trim())}; Max-Age=31536000; Path=/; SameSite=Lax$secure';
}

Future<void> clearStoredOpenAiKey() async {
  html.document.cookie = '$_apiKeyCookieName=; Max-Age=0; Path=/; SameSite=Lax';
}
