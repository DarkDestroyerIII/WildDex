import 'package:flutter_test/flutter_test.dart';

import 'package:pokedex_animal_app/main.dart';

void main() {
  test('OpenAI non-animal response becomes one shared entry', () {
    final entry = AnimalEntry.fromGeneratedJson({
      'is_animal': false,
      'common_name': 'Desk',
      'scientific_name': 'Furniture',
    });

    expect(entry.commonName, 'Not an animal');
    expect(entry.speciesKey, 'not an animal');
    expect(entry.dexNumber, 0);
    expect(entry.scanCount, 1);
    expect(entry.isNotAnimal, isTrue);
  });

  test('uncertain scientific suffixes reuse the same pill bug identity', () {
    final speciesEntry = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Pill bug',
      'scientific_name': 'Armadillidium vulgare',
      'animal_group': 'Crustacean',
      'taxonomy': {'class': 'Malacostraca', 'order': 'Isopoda'},
      'stats': {'Power': 8, 'Speed': 12, 'Stealth': 55},
    });
    final uncertainEntry = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Pill bug',
      'scientific_name': 'Armadillidium spp.',
      'animal_group': 'Crustacean',
      'taxonomy': {'class': 'Malacostraca', 'order': 'Isopoda'},
      'stats': {'Power': 9, 'Speed': 13, 'Stealth': 54},
    });

    expect(uncertainEntry.speciesKey, 'pill bug');
    expect(entriesShouldMerge(speciesEntry, uncertainEntry), isTrue);
  });

  test('minimal identity can match a cached full entry', () {
    final cached = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Pill bug',
      'scientific_name': 'Armadillidium vulgare',
      'animal_group': 'Crustacean',
      'taxonomy': {'class': 'Malacostraca', 'order': 'Isopoda'},
      'stats': {'Power': 8, 'Speed': 12, 'Stealth': 55},
    });
    final identity = AnimalIdentity.fromJson({
      'is_animal': true,
      'common_name': 'Pill bug',
      'scientific_name': 'Armadillidium sp.',
      'animal_group': 'Crustacean',
      'taxonomy': {'class': 'Malacostraca', 'order': 'Isopoda'},
    });

    expect(entryMatchesIdentity(cached, identity), isTrue);
  });

  test('identity prompt treats location as a regional range filter', () {
    final prompt = debugIdentityPromptForTests(
      const LocationHint(
        latitude: 37.4,
        longitude: -122.1,
        accuracyMeters: 1000,
      ),
    );

    expect(prompt, contains('hard range filter'));
    expect(prompt, contains('brown recluse'));
    expect(prompt, contains('do not return "Loxosceles reclusa"'));
  });

  test('trade package round trips through QR payload', () {
    final entry = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Eastern Gray Squirrel',
      'scientific_name': 'Sciurus carolinensis',
      'animal_group': 'Mammal',
      'taxonomy': {'class': 'Mammalia', 'order': 'Rodentia'},
      'stats': {'Power': 35, 'Speed': 72, 'Stealth': 68},
    });
    final capture = CritterCapture(
      id: 'capture-1',
      speciesKey: entry.speciesKey,
      commonName: entry.commonName,
      scientificName: entry.scientificName,
      label: 'Wild capture',
      stats: entry.stats,
      capturedAt: DateTime.utc(2026, 5, 12),
      source: 'local',
    );

    final encoded = TradePackage(entry: entry, capture: capture).toQrData();
    final decoded = TradePackage.fromQrData(encoded);

    expect(decoded.entry.speciesKey, entry.speciesKey);
    expect(decoded.capture.commonName, capture.commonName);
    expect(decoded.capture.stats['Speed'], 72);
  });

  testWidgets('WildDex renders scanner controls', (WidgetTester tester) async {
    await tester.pumpWidget(const WildDexApp());
    await tester.pump();

    expect(find.text('WildDex'), findsOneWidget);
    expect(find.text('Scan with camera'), findsOneWidget);
    expect(find.text('Gallery'), findsNothing);
  });
}
