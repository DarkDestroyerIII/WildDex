# WildDex

WildDex is a Flutter app for Android and iOS. Take a photo of an animal, and the app asks OpenAI to identify it and generate a compact field-guide entry with taxonomy, habitat, diet, range, abilities, and stats. It then pulls a reference image from Wikipedia and reads the entry aloud using the phone's default text-to-speech voice.

## Add Your OpenAI Key

Open `lib/openai_config.dart` and paste your key:

```dart
const String openAiApiKey = 'sk-...';
```

The app uses the OpenAI Responses API with a vision-capable model. For personal testing this is convenient, but do not ship a public app with the API key compiled into it. Use a small backend proxy before distributing it.

## Cache Behavior

Entries are cached on-device with `shared_preferences`.

- The same photo hash reopens the cached entry without calling OpenAI again.
- A new photo of an already-known species reuses the existing species entry after identification.
- The entry number is deterministic from the scientific name, so the same species keeps the same number across scans.

## Build Android APK

From this folder:

```powershell
$env:JAVA_HOME='C:\Program Files\Java\jdk-17'
$env:PATH="$env:JAVA_HOME\bin;$env:PATH"
flutter build apk --debug
```

The APK will be created at:

```text
build\app\outputs\flutter-apk\app-debug.apk
```

Install it on a connected Android phone with:

```powershell
flutter install
```

## iOS

The iOS project is included in `ios/`, but iOS builds require macOS with Xcode:

```bash
flutter build ios
```
