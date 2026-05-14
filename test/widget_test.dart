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

  test('OpenAI key paste cleanup accepts common copied formats', () {
    const key = 'sk-proj-abc_123-XYZ4567890';

    expect(normalizeOpenAiApiKey('Bearer $key'), key);
    expect(normalizeOpenAiApiKey('Authorization: Bearer $key'), key);
    expect(normalizeOpenAiApiKey("const String openAiApiKey = '$key';"), key);
    expect(normalizeOpenAiApiKey('OPENAI_API_KEY=$key'), key);
    expect(normalizeOpenAiApiKey(' $key\n'), key);
    expect(looksLikeOpenAiKey(key), isTrue);
    expect(looksLikeOpenAiKey('not a key'), isFalse);
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

  test('trade package reassembles from flashing QR chunks', () {
    final entry = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Eastern Gray Squirrel',
      'scientific_name': 'Sciurus carolinensis',
      'animal_group': 'Mammal',
      'taxonomy': {'class': 'Mammalia', 'order': 'Rodentia'},
      'habitat': 'Parks and forests with many tall trees',
      'diet': 'Nuts, seeds, buds, fungi, and occasional insects',
      'range': 'Eastern North America',
      'abilities': ['Climbing', 'Caching food', 'Agile jumping'],
      'stats': {'Power': 35, 'Speed': 72, 'Stealth': 68},
      'description':
          'A long enough description to force the trade payload into multiple QR chunks for safer scanning.',
    });
    final capture = CritterCapture(
      id: 'capture-2',
      speciesKey: entry.speciesKey,
      commonName: entry.commonName,
      scientificName: entry.scientificName,
      label: 'Wild capture',
      stats: entry.stats,
      capturedAt: DateTime.utc(2026, 5, 12),
      source: 'local',
    );
    final package = TradePackage(entry: entry, capture: capture);
    final chunks = package.toQrChunks();
    final assembler = TradeQrAssembler();
    TradePackage? decoded;

    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks.reversed) {
      decoded = assembler.addQrData(chunk.toQrData());
    }

    expect(decoded?.entry.speciesKey, entry.speciesKey);
    expect(decoded?.capture.id, capture.id);
  });

  test('battle package reassembles and simulates deterministically', () {
    final rabbit = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Desert Cottontail',
      'scientific_name': 'Sylvilagus audubonii',
      'animal_group': 'Mammal',
      'taxonomy': {'class': 'Mammalia', 'order': 'Lagomorpha'},
      'stats': {
        'Power': 22,
        'Speed': 80,
        'Stealth': 70,
        'Defense': 25,
        'Intelligence': 45,
        'Rarity': 30,
      },
    });
    final beetle = AnimalEntry.fromGeneratedJson({
      'is_animal': true,
      'common_name': 'Darkling Beetle',
      'scientific_name': 'Eleodes sp.',
      'animal_group': 'Insect',
      'taxonomy': {'class': 'Insecta', 'order': 'Coleoptera'},
      'stats': {
        'Power': 36,
        'Speed': 28,
        'Stealth': 52,
        'Defense': 76,
        'Intelligence': 18,
        'Rarity': 38,
      },
    });
    final rabbitCapture = CritterCapture(
      id: 'rabbit-1',
      speciesKey: rabbit.speciesKey,
      commonName: rabbit.commonName,
      scientificName: rabbit.scientificName,
      label: 'Wild capture',
      stats: rabbit.stats,
      capturedAt: DateTime.utc(2026, 5, 13),
      source: 'local',
    );
    final beetleCapture = CritterCapture(
      id: 'beetle-1',
      speciesKey: beetle.speciesKey,
      commonName: beetle.commonName,
      scientificName: beetle.scientificName,
      label: 'Wild capture',
      stats: beetle.stats,
      capturedAt: DateTime.utc(2026, 5, 13),
      source: 'local',
    );
    final rabbitPackage = BattlePackage(
      battleId: 'battle-123',
      entry: rabbit,
      capture: rabbitCapture,
    );
    final beetlePackage = BattlePackage(
      battleId: 'battle-123',
      entry: beetle,
      capture: beetleCapture,
    );
    final assembler = BattleQrAssembler();
    BattlePackage? decoded;

    for (final chunk in beetlePackage.toQrChunks().reversed) {
      decoded = assembler.addQrData(chunk.toQrData());
    }

    final first = simulateBattle(
      ownPackage: rabbitPackage,
      opponentPackage: decoded!,
    );
    final second = simulateBattle(
      ownPackage: decoded,
      opponentPackage: rabbitPackage,
    );

    expect(decoded.battleId, 'battle-123');
    expect(first.statusLine, second.statusLine);
    expect(first.events, second.events);
    expect(first.ownWon, isNot(second.ownWon));
    expect(first.winnerCapturedLoser, second.winnerCapturedLoser);
  });

  testWidgets('WildDex renders scanner controls', (WidgetTester tester) async {
    await tester.pumpWidget(const WildDexApp());
    await tester.pump();

    expect(find.text('WildDex'), findsOneWidget);
    expect(find.text('Scan with camera'), findsOneWidget);
    expect(find.text('Gallery'), findsNothing);
  });
}
