import 'package:shared_preferences/shared_preferences.dart';

const _apiKeyPrefsKey = 'wilddex.openai_api_key.v1';

Future<String> loadStoredOpenAiKey() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_apiKeyPrefsKey) ?? '';
}

Future<void> saveStoredOpenAiKey(String key) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_apiKeyPrefsKey, key.trim());
}

Future<void> clearStoredOpenAiKey() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_apiKeyPrefsKey);
}
