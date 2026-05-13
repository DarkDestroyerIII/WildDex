import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_key_store.dart';
import 'openai_config.dart';

const _consoleModeKey = 'wilddex.console_mode.v1';
const _cooldownMinutesKey = 'wilddex.cooldown_minutes.v1';

void main() {
  runApp(const WildDexApp());
}

class WildDexApp extends StatelessWidget {
  const WildDexApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff2f6f73);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WildDex',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff4f0e8),
        textTheme: Theme.of(context).textTheme.apply(
              bodyColor: const Color(0xff152323),
              displayColor: const Color(0xff152323),
            ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

ThemeData consoleTheme(ThemeData baseTheme) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff1ba6a6),
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xff50d8c8),
    secondary: const Color(0xff8fa7ff),
    tertiary: const Color(0xffd7c36a),
    surface: const Color(0xff17262e),
    onSurface: const Color(0xffedf8f7),
  );

  return baseTheme.copyWith(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xff071216),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xff0f3138),
      foregroundColor: Color(0xffedf8f7),
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xff0b1b22),
      indicatorColor: const Color(0xff214951),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    textTheme: baseTheme.textTheme.apply(
      bodyColor: const Color(0xffeefaf7),
      displayColor: const Color(0xffeefaf7),
    ),
    chipTheme: baseTheme.chipTheme.copyWith(
      backgroundColor: const Color(0xff18343a),
      selectedColor: const Color(0xff275f6a),
      labelStyle: const TextStyle(color: Color(0xffedf8f7)),
      secondaryLabelStyle: const TextStyle(color: Color(0xffedf8f7)),
      side: const BorderSide(color: Color(0xff50d8c8)),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _picker = ImagePicker();
  final _tts = FlutterTts();
  final _repository = EntryRepository();
  final _openAi = OpenAiEntryService();
  final _location = LocationHintService();
  final _wiki = WikipediaImageService();

  AnimalEntry? _currentEntry;
  Uint8List? _pickedPhotoBytes;
  List<AnimalEntry> _entries = const [];
  List<CritterCapture> _captures = const [];
  bool _loading = true;
  String? _status;
  int _selectedSection = 0;
  String _selectedCategory = 'All';
  String? _selectedTradeCaptureId;
  TradePackage? _incomingTrade;
  final Set<int> _activePointers = {};
  bool _threeFingerChordActive = false;
  int _threeFingerTapCount = 0;
  DateTime? _lastThreeFingerTap;
  bool _consoleMode = false;
  int _cooldownMinutes = 3;
  String _runtimeOpenAiKey = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _repository.load();
    final prefs = await SharedPreferences.getInstance();
    final storedApiKey = await loadStoredOpenAiKey();
    await _tts.setSpeechRate(0.47);
    await _tts.setPitch(1.06);
    await _tts.setVolume(1);

    setState(() {
      _entries = _repository.entries;
      _captures = _repository.captures;
      _currentEntry = _entries.isNotEmpty ? _entries.first : null;
      _consoleMode = prefs.getBool(_consoleModeKey) ?? false;
      _cooldownMinutes = prefs.getInt(_cooldownMinutesKey) ?? 3;
      _runtimeOpenAiKey =
          storedApiKey.trim().isNotEmpty ? storedApiKey : openAiApiKey;
      _loading = false;
    });
  }

  Future<void> _takePhoto() async {
    if (_runtimeOpenAiKey.trim().isEmpty) {
      await _openApiKeySheet();
      if (_runtimeOpenAiKey.trim().isEmpty) {
        setState(() {
          _status = 'Add an OpenAI API key before scanning.';
          _selectedSection = 0;
        });
        return;
      }
    }

    _openAi.apiKey = _runtimeOpenAiKey;

    final image = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 82,
      maxWidth: 1400,
    );
    if (image == null) return;

    final bytes = await image.readAsBytes();
    final photoBytes = Uint8List.fromList(bytes);
    final photoHash = sha1.convert(bytes).toString();

    setState(() {
      _pickedPhotoBytes = photoBytes;
      _loading = true;
      _selectedSection = 0;
      _status = 'Checking the local WildDex cache...';
    });

    try {
      final cached = _repository.entryForPhotoHash(photoHash);
      if (cached != null) {
        final updated =
            await _repository.recordScanForPhotoHash(photoHash) ?? cached;
        setState(() {
          _currentEntry = updated;
          _entries = _repository.entries;
          _captures = _repository.captures;
          _loading = false;
          _status =
              'Loaded from cache. Scan count is now ${updated.scanCount}.';
        });
        await _speak(updated);
        return;
      }

      setState(() {
        _status = 'Getting a rough location hint for range matching...';
      });

      final locationHint = await _location.currentHint();

      setState(() {
        _status = locationHint == null
            ? 'Identifying the animal without a location hint...'
            : 'Identifying the animal near ${locationHint.displayLabel}...';
      });

      final identity = await _openAi.identifyAnimal(
        bytes,
        locationHint: locationHint,
      );
      final existing = _repository.entryForIdentity(identity);

      if (existing != null) {
        final cooldown = _repository.cooldownRemaining(
          existing.speciesKey,
          Duration(minutes: _cooldownMinutes),
        );
        if (cooldown > Duration.zero) {
          setState(() {
            _currentEntry = existing;
            _entries = _repository.entries;
            _captures = _repository.captures;
            _loading = false;
            _status =
                '${existing.commonName} is cooling down for ${formatCooldown(cooldown)}.';
          });
          await _speak(existing);
          return;
        }

        setState(() {
          _status = 'Known species. Rolling capture stats...';
        });

        final captureStats = await _openAi.generateCaptureStats(
          bytes,
          entry: existing,
          locationHint: locationHint,
        );
        final updated = await _repository.recordCapture(
          photoHash: photoHash,
          entry: existing,
          stats: captureStats,
        );
        setState(() {
          _currentEntry = updated;
          _entries = _repository.entries;
          _captures = _repository.captures;
          _loading = false;
          _status = 'Captured ${updated.commonName} #${updated.scanCount}.';
        });
        await _speak(updated);
        return;
      }

      setState(() {
        _status = identity.isNotAnimal
            ? 'Saving this as the shared Not an animal entry...'
            : 'New animal found. Writing a full entry...';
      });

      var generated = identity.isNotAnimal
          ? AnimalEntry.notAnimal()
          : await _openAi.generateEntry(
              bytes,
              locationHint: locationHint,
              identity: identity,
            );

      setState(() {
        _status = generated.isNotAnimal
            ? 'Saving this as the shared Not an animal entry...'
            : 'Finding a reference image from Wikipedia...';
      });

      if (!generated.isNotAnimal) {
        final wikiImage = await _wiki.findImage(
          generated.commonName,
          generated.scientificName,
        );
        generated = generated.copyWith(
          imageUrl: wikiImage?.imageUrl,
          wikipediaTitle: wikiImage?.title,
        );
      }

      final saved = await _repository.saveEntry(generated, photoHash);
      if (!saved.isNotAnimal) {
        await _repository.addCapture(
          entry: saved,
          stats: saved.stats,
          label: 'First sighting',
        );
      }

      setState(() {
        _currentEntry = saved;
        _entries = _repository.entries;
        _captures = _repository.captures;
        _loading = false;
        _status = saved.isNotAnimal
            ? 'Not an animal cached. Future empty scans reuse this entry.'
            : 'New WildDex entry cached.';
      });
      await _speak(saved);
    } catch (error) {
      setState(() {
        _loading = false;
        _status = 'Scan failed: $error';
      });
    }
  }

  Future<void> _speak(AnimalEntry entry) async {
    await _tts.stop();
    await _tts.speak('${entry.voiceLine} ${entry.description}');
  }

  Future<void> _stopSpeaking() => _tts.stop();

  Future<void> _openApiKeySheet() async {
    final controller = TextEditingController(text: _runtimeOpenAiKey);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'OpenAI Key',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Paste an OpenAI API key for this browser. WildDex saves it in a cookie on web.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'OpenAI API key',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        await clearStoredOpenAiKey();
                        setState(() => _runtimeOpenAiKey = '');
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () async {
                        final key = controller.text.trim();
                        await saveStoredOpenAiKey(key);
                        setState(() => _runtimeOpenAiKey = key);
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
  }

  Future<void> _setConsoleMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consoleModeKey, enabled);
    setState(() => _consoleMode = enabled);
  }

  Future<void> _setCooldownMinutes(int minutes) async {
    final value = minutes.clamp(0, 60);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cooldownMinutesKey, value);
    setState(() => _cooldownMinutes = value);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length >= 3 && !_threeFingerChordActive) {
      _threeFingerChordActive = true;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty && _threeFingerChordActive) {
      _threeFingerChordActive = false;
      _registerThreeFingerTap();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      _threeFingerChordActive = false;
    }
  }

  void _registerThreeFingerTap() {
    final now = DateTime.now();
    final lastTap = _lastThreeFingerTap;
    if (lastTap == null ||
        now.difference(lastTap) > const Duration(milliseconds: 1200)) {
      _threeFingerTapCount = 0;
    }

    _threeFingerTapCount += 1;
    _lastThreeFingerTap = now;

    if (_threeFingerTapCount >= 3) {
      _threeFingerTapCount = 0;
      _lastThreeFingerTap = null;
      _openCacheManager();
    }
  }

  Future<void> _openCacheManager() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> removeOneScan(AnimalEntry entry) async {
              final updated = await _repository.removeOneScan(entry.speciesKey);
              setState(() {
                _entries = _repository.entries;
                if (updated == null &&
                    _currentEntry?.speciesKey == entry.speciesKey) {
                  _currentEntry = _entries.isNotEmpty ? _entries.first : null;
                } else if (updated != null &&
                    _currentEntry?.speciesKey == entry.speciesKey) {
                  _currentEntry = updated;
                }
              });
              setSheetState(() {});
            }

            Future<void> deleteEntry(AnimalEntry entry) async {
              await _repository.deleteEntry(entry.speciesKey);
              setState(() {
                _entries = _repository.entries;
                if (_currentEntry?.speciesKey == entry.speciesKey) {
                  _currentEntry = _entries.isNotEmpty ? _entries.first : null;
                }
              });
              setSheetState(() {});
            }

            return _CacheManagerSheet(
              entries: _entries,
              consoleMode: _consoleMode,
              cooldownMinutes: _cooldownMinutes,
              onRemoveScan: removeOneScan,
              onDeleteEntry: deleteEntry,
              onConsoleModeChanged: (enabled) async {
                await _setConsoleMode(enabled);
                setSheetState(() {});
              },
              onCooldownChanged: (minutes) async {
                await _setCooldownMinutes(minutes);
                setSheetState(() {});
              },
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final activeTheme = _consoleMode ? consoleTheme(baseTheme) : baseTheme;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: Theme(
        data: activeTheme,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_consoleMode ? 'WildDex Field Console' : 'WildDex'),
            actions: [
              IconButton(
                tooltip: 'OpenAI key',
                onPressed: _openApiKeySheet,
                icon: Icon(
                  _runtimeOpenAiKey.trim().isEmpty
                      ? Icons.key_off_outlined
                      : Icons.key_outlined,
                ),
              ),
              IconButton(
                tooltip: 'Stop voice',
                onPressed: _stopSpeaking,
                icon: const Icon(Icons.volume_off_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                if (_selectedSection == 0) return _buildScannerSection(wide);
                if (_selectedSection == 1) return _buildCollectionSection(wide);
                return _buildTradeSection(wide);
              },
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedSection,
            onDestinationSelected: (index) {
              setState(() => _selectedSection = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.photo_camera_outlined),
                selectedIcon: Icon(Icons.photo_camera),
                label: 'Scan',
              ),
              NavigationDestination(
                icon: Icon(Icons.grid_view_outlined),
                selectedIcon: Icon(Icons.grid_view),
                label: 'Collection',
              ),
              NavigationDestination(
                icon: Icon(Icons.qr_code_2_outlined),
                selectedIcon: Icon(Icons.qr_code_2),
                label: 'Trade',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScannerSection(bool wide) {
    if (wide) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _ScannerPanel(
                pickedPhotoBytes: _pickedPhotoBytes,
                loading: _loading,
                status: _status,
                onCamera: _takePhoto,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: _EntryPanel(
                entry: _currentEntry,
                onSpeak:
                    _currentEntry == null ? null : () => _speak(_currentEntry!),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ScannerPanel(
          pickedPhotoBytes: _pickedPhotoBytes,
          loading: _loading,
          status: _status,
          onCamera: _takePhoto,
        ),
        const SizedBox(height: 12),
        _EntryPanel(
          entry: _currentEntry,
          onSpeak: _currentEntry == null ? null : () => _speak(_currentEntry!),
        ),
      ],
    );
  }

  Widget _buildCollectionSection(bool wide) {
    final collection = _entries.where((entry) => !entry.isNotAnimal).toList();
    final categories = [
      'All',
      ...{
        for (final entry in collection)
          if (entry.animalGroup.trim().isNotEmpty) entry.animalGroup.trim(),
      },
    ]..sort((a, b) {
        if (a == 'All') return -1;
        if (b == 'All') return 1;
        return a.compareTo(b);
      });

    if (!categories.contains(_selectedCategory)) {
      _selectedCategory = 'All';
    }

    final filtered = _selectedCategory == 'All'
        ? collection
        : collection
            .where((entry) => entry.animalGroup == _selectedCategory)
            .toList();

    filtered.sort((a, b) {
      final countCompare = b.scanCount.compareTo(a.scanCount);
      if (countCompare != 0) return countCompare;
      return a.commonName.compareTo(b.commonName);
    });

    return Padding(
      padding: const EdgeInsets.all(16),
      child: _CollectionPanel(
        entries: filtered,
        captures: _captures,
        categories: categories,
        selectedCategory: _selectedCategory,
        onCategoryChanged: (category) {
          setState(() => _selectedCategory = category);
        },
        onSelect: (entry) {
          setState(() {
            _currentEntry = entry;
            _selectedSection = 0;
          });
        },
        onViewCaptures: _openCapturesSheet,
      ),
    );
  }

  Widget _buildTradeSection(bool wide) {
    final tradeCaptures = _captures
        .where((capture) =>
            _repository.entryForSpecies(capture.speciesKey) != null)
        .toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    final selectedCapture = tradeCaptures
        .where((capture) => capture.id == _selectedTradeCaptureId)
        .firstOrNull;
    final selectedEntry = selectedCapture == null
        ? null
        : _repository.entryForSpecies(selectedCapture.speciesKey);
    final outgoingPackage = selectedCapture != null && selectedEntry != null
        ? TradePackage(entry: selectedEntry, capture: selectedCapture)
        : null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: _TradePanel(
        captures: tradeCaptures,
        selectedCapture: selectedCapture,
        outgoingPackage: outgoingPackage,
        incomingPackage: _incomingTrade,
        onSelected: (capture) {
          setState(() => _selectedTradeCaptureId = capture?.id);
        },
        onScan: _scanTradeQr,
        onClearIncoming: () => setState(() => _incomingTrade = null),
        onCompleteTrade: _completeTrade,
      ),
    );
  }

  Future<void> _openCapturesSheet(AnimalEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return _CapturesSheet(
          entry: entry,
          captures: _repository.capturesForSpecies(entry.speciesKey),
          onTradeCapture: (capture) {
            Navigator.pop(context);
            setState(() {
              _selectedTradeCaptureId = capture.id;
              _selectedSection = 2;
            });
          },
        );
      },
    );
  }

  Future<void> _scanTradeQr() async {
    final package = await Navigator.of(context).push<TradePackage>(
      MaterialPageRoute(builder: (_) => const _TradeQrScannerScreen()),
    );
    if (package != null) {
      setState(() => _incomingTrade = package);
    }
  }

  Future<void> _completeTrade() async {
    final selectedCapture = _captures
        .where((capture) => capture.id == _selectedTradeCaptureId)
        .firstOrNull;

    if (selectedCapture == null && _incomingTrade == null) {
      setState(() => _status = 'Pick a capture or scan a trade QR first.');
      return;
    }

    if (_incomingTrade != null) {
      await _repository.importTradePackage(_incomingTrade!);
    }
    if (selectedCapture != null) {
      await _repository.deleteCapture(selectedCapture.id);
    }

    setState(() {
      _entries = _repository.entries;
      _captures = _repository.captures;
      _selectedTradeCaptureId = null;
      _incomingTrade = null;
      _status = 'Trade complete.';
    });
  }
}

class _ScannerPanel extends StatefulWidget {
  const _ScannerPanel({
    required this.pickedPhotoBytes,
    required this.loading,
    required this.status,
    required this.onCamera,
  });

  final Uint8List? pickedPhotoBytes;
  final bool loading;
  final String? status;
  final VoidCallback onCamera;

  @override
  State<_ScannerPanel> createState() => _ScannerPanelState();
}

class _ScannerPanelState extends State<_ScannerPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    );
    if (widget.loading) {
      _scanController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _ScannerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading && !_scanController.isAnimating) {
      _scanController.repeat();
    } else if (!widget.loading && _scanController.isAnimating) {
      _scanController.stop();
    }
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff132725),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.pickedPhotoBytes == null
                        ? const _EmptyLens()
                        : Image.memory(
                            widget.pickedPhotoBytes!,
                            fit: BoxFit.cover,
                          ),
                    if (widget.loading && widget.pickedPhotoBytes != null)
                      _ScanningOverlay(
                        animation: _scanController,
                        accentColor:
                            dark ? const Color(0xff50d8c8) : colors.primary,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.loading ? null : widget.onCamera,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Scan with camera'),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: widget.loading
                ? LinearProgressIndicator(color: colors.primary)
                : const SizedBox(height: 4),
          ),
          if (widget.status != null) ...[
            const SizedBox(height: 10),
            Text(
              widget.status!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}

class _ScanningOverlay extends StatelessWidget {
  const _ScanningOverlay({
    required this.animation,
    required this.accentColor,
  });

  final Animation<double> animation;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final value = Curves.easeInOut.transform(animation.value);
        final reverseValue = (animation.value * 2) % 1;
        final pulse = 0.5 + (0.5 - (animation.value - 0.5).abs());
        return CustomPaint(
          painter: _ScanOverlayPainter(
            progress: value,
            secondaryProgress: reverseValue,
            pulse: pulse,
            accentColor: accentColor,
          ),
          child: Align(
            alignment: const Alignment(0, -0.9),
            child: Opacity(
              opacity: 0.78 + pulse * 0.18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: accentColor.withOpacity(0.72)),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withOpacity(0.22),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.radar, color: accentColor, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'ANALYZING',
                        style: TextStyle(
                          color: accentColor,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  const _ScanOverlayPainter({
    required this.progress,
    required this.secondaryProgress,
    required this.pulse,
    required this.accentColor,
  });

  final double progress;
  final double secondaryProgress;
  final double pulse;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = Colors.black.withOpacity(0.15);
    canvas.drawRect(Offset.zero & size, overlayPaint);

    final gridPaint = Paint()
      ..color = accentColor.withOpacity(0.12)
      ..strokeWidth = 1;
    const spacing = 32.0;
    for (var x = secondaryProgress * spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = secondaryProgress * spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    _paintReticle(canvas, size);
    _paintDataParticles(canvas, size);

    final scanY = size.height * progress;
    final glowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accentColor.withOpacity(0),
          accentColor.withOpacity(0.33),
          accentColor.withOpacity(0),
        ],
      ).createShader(Rect.fromLTWH(0, scanY - 52, size.width, 104));
    canvas.drawRect(Rect.fromLTWH(0, scanY - 52, size.width, 104), glowPaint);

    final linePaint = Paint()
      ..color = accentColor.withOpacity(0.78)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, scanY), Offset(size.width, scanY), linePaint);
    canvas.drawLine(
      Offset(size.width * 0.18, scanY + 11),
      Offset(size.width * 0.82, scanY + 11),
      Paint()
        ..color = Colors.white.withOpacity(0.28)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(size.width * 0.28, scanY - 14),
      Offset(size.width * 0.72, scanY - 14),
      Paint()
        ..color = accentColor.withOpacity(0.36)
        ..strokeWidth = 1,
    );

    final cornerPaint = Paint()
      ..color = accentColor.withOpacity(0.58 + pulse * 0.18)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const corner = 22.0;
    canvas.drawPath(
      Path()
        ..moveTo(10, corner)
        ..lineTo(10, 10)
        ..lineTo(corner, 10)
        ..moveTo(size.width - corner, 10)
        ..lineTo(size.width - 10, 10)
        ..lineTo(size.width - 10, corner)
        ..moveTo(size.width - 10, size.height - corner)
        ..lineTo(size.width - 10, size.height - 10)
        ..lineTo(size.width - corner, size.height - 10)
        ..moveTo(corner, size.height - 10)
        ..lineTo(10, size.height - 10)
        ..lineTo(10, size.height - corner),
      cornerPaint,
    );
  }

  void _paintReticle(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * (0.2 + pulse * 0.045);
    final reticlePaint = Paint()
      ..color = accentColor.withOpacity(0.4 + pulse * 0.18)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, radius, reticlePaint);
    canvas.drawCircle(center, radius * 0.58, reticlePaint..strokeWidth = 0.8);
    canvas.drawLine(
      Offset(center.dx - radius - 14, center.dy),
      Offset(center.dx - radius * 0.35, center.dy),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(center.dx + radius * 0.35, center.dy),
      Offset(center.dx + radius + 14, center.dy),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 14),
      Offset(center.dx, center.dy - radius * 0.35),
      reticlePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + radius * 0.35),
      Offset(center.dx, center.dy + radius + 14),
      reticlePaint,
    );
  }

  void _paintDataParticles(Canvas canvas, Size size) {
    final particlePaint = Paint()..style = PaintingStyle.fill;
    const points = [
      Offset(0.18, 0.24),
      Offset(0.76, 0.28),
      Offset(0.33, 0.39),
      Offset(0.64, 0.48),
      Offset(0.22, 0.62),
      Offset(0.79, 0.68),
      Offset(0.46, 0.76),
    ];

    for (var i = 0; i < points.length; i++) {
      final phase = ((secondaryProgress + i * 0.17) % 1.0);
      final opacity = 0.08 + (phase < 0.5 ? phase : 1 - phase) * 0.55;
      particlePaint.color = accentColor.withOpacity(opacity);
      final point = points[i];
      canvas.drawCircle(
        Offset(point.dx * size.width, point.dy * size.height),
        2.0 + phase * 2.5,
        particlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScanOverlayPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.secondaryProgress != secondaryProgress ||
        oldDelegate.pulse != pulse ||
        oldDelegate.accentColor != accentColor;
  }
}

class _EmptyLens extends StatelessWidget {
  const _EmptyLens();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.center_focus_strong,
        color: Colors.white.withOpacity(0.82),
        size: 72,
      ),
    );
  }
}

class _EntryPanel extends StatelessWidget {
  const _EntryPanel({required this.entry, required this.onSpeak});

  final AnimalEntry? entry;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    if (entry == null) {
      return const _Panel(
        child: Center(
          child: Text('Take a photo to create the first entry.'),
        ),
      );
    }

    final item = entry!;
    return _Panel(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'No. ${item.dexNumber.toString().padLeft(4, '0')}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(
                        item.commonName,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        item.scientificName,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontStyle: FontStyle.italic,
                                ),
                      ),
                      const SizedBox(height: 6),
                      Chip(
                        avatar: const Icon(Icons.repeat, size: 18),
                        label: Text('Scanned ${item.scanCount}x'),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Read entry',
                  onPressed: onSpeak,
                  icon: const Icon(Icons.volume_up_outlined),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (item.imageUrl != null)
              AspectRatio(
                aspectRatio: 16 / 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: item.imageUrl!,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => const ColoredBox(
                      color: Color(0xffd8ded8),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    errorWidget: (context, url, error) => const ColoredBox(
                      color: Color(0xffd8ded8),
                      child: Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Text(
              item.description,
              style:
                  Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.35),
            ),
            const SizedBox(height: 14),
            _InfoGrid(entry: item),
            const SizedBox(height: 14),
            _StatsBlock(stats: item.stats),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: item.abilities
                  .map(
                    (ability) => Chip(
                      label: Text(ability),
                      avatar: const Icon(Icons.auto_awesome, size: 18),
                    ),
                  )
                  .toList(),
            ),
            if (item.wikipediaTitle != null) ...[
              const SizedBox(height: 10),
              Text(
                'Reference image: Wikipedia, ${item.wikipediaTitle}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.entry});

  final AnimalEntry entry;

  @override
  Widget build(BuildContext context) {
    final rows = {
      'Group': entry.animalGroup,
      'Habitat': entry.habitat,
      'Diet': entry.diet,
      'Range': entry.range,
      'Class': entry.taxonomy['class'] ?? 'Unknown',
      'Order': entry.taxonomy['order'] ?? 'Unknown',
    };

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: rows.entries
          .map((row) => _InfoTile(label: row.key, value: row.value))
          .toList(),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xffb9c7bf)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsBlock extends StatelessWidget {
  const _StatsBlock({required this.stats});

  final Map<String, int> stats;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Field Stats',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        ...stats.entries
            .map((stat) => _StatBar(label: stat.key, value: stat.value)),
      ],
    );
  }
}

class _StatBar extends StatelessWidget {
  const _StatBar({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: safeValue / 100,
                minHeight: 10,
                backgroundColor: const Color(0xffd7ded7),
              ),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              safeValue.toString(),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionPanel extends StatelessWidget {
  const _CollectionPanel({
    required this.entries,
    required this.captures,
    required this.categories,
    required this.selectedCategory,
    required this.onCategoryChanged,
    required this.onSelect,
    required this.onViewCaptures,
  });

  final List<AnimalEntry> entries;
  final List<CritterCapture> captures;
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<AnimalEntry> onSelect;
  final ValueChanged<AnimalEntry> onViewCaptures;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Scanned Animals',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          Text(
            '${entries.length} shown',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categories
                  .map(
                    (category) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(category),
                        selected: selectedCategory == category,
                        onSelected: (_) => onCategoryChanged(category),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text('No scanned animals in this category.'))
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        leading: CircleAvatar(
                          child:
                              Text(entry.dexNumber.toString().padLeft(4, '0')),
                        ),
                        title: Text(entry.commonName),
                        subtitle: Text(
                            '${entry.animalGroup} - ${entry.scientificName}'),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.repeat, size: 18),
                              label: Text(
                                  '${capturesForEntry(entry, captures).length}x'),
                            ),
                            IconButton(
                              tooltip: 'View captures',
                              onPressed: () => onViewCaptures(entry),
                              icon: const Icon(Icons.inventory_2_outlined),
                            ),
                          ],
                        ),
                        onTap: () => onSelect(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CacheManagerSheet extends StatelessWidget {
  const _CacheManagerSheet({
    required this.entries,
    required this.consoleMode,
    required this.cooldownMinutes,
    required this.onRemoveScan,
    required this.onDeleteEntry,
    required this.onConsoleModeChanged,
    required this.onCooldownChanged,
  });

  final List<AnimalEntry> entries;
  final bool consoleMode;
  final int cooldownMinutes;
  final Future<void> Function(AnimalEntry entry) onRemoveScan;
  final Future<void> Function(AnimalEntry entry) onDeleteEntry;
  final Future<void> Function(bool enabled) onConsoleModeChanged;
  final Future<void> Function(int minutes) onCooldownChanged;

  @override
  Widget build(BuildContext context) {
    final sortedEntries = entries.toList()
      ..sort((a, b) => a.commonName.compareTo(b.commonName));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manage Cache',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                'Remove one scan count or delete a cached entry.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.science_outlined),
                title: const Text('Field console style'),
                subtitle: const Text('More game-like scientific scanner UI.'),
                value: consoleMode,
                onChanged: onConsoleModeChanged,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Species cooldown'),
                subtitle: Text(
                  cooldownMinutes == 0
                      ? 'Off'
                      : '$cooldownMinutes minutes between same-species captures',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Lower cooldown',
                      onPressed: () async =>
                          onCooldownChanged(cooldownMinutes - 1),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Raise cooldown',
                      onPressed: () async =>
                          onCooldownChanged(cooldownMinutes + 1),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: sortedEntries.isEmpty
                    ? const Center(child: Text('No cached entries.'))
                    : ListView.separated(
                        itemCount: sortedEntries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = sortedEntries[index];
                          return ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 6),
                            title: Text(entry.commonName),
                            subtitle: Text(
                              '${entry.scientificName} - ${entry.scanCount} scans',
                            ),
                            trailing: Wrap(
                              spacing: 6,
                              children: [
                                IconButton.filledTonal(
                                  tooltip: 'Remove one scan',
                                  onPressed: () async => onRemoveScan(entry),
                                  icon: const Icon(Icons.exposure_minus_1),
                                ),
                                IconButton.filled(
                                  tooltip: 'Delete cached entry',
                                  style: IconButton.styleFrom(
                                    backgroundColor:
                                        Theme.of(context).colorScheme.error,
                                    foregroundColor:
                                        Theme.of(context).colorScheme.onError,
                                  ),
                                  onPressed: () async {
                                    final shouldDelete = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Delete entry?'),
                                        content: Text(
                                          'Remove ${entry.commonName} from the cache completely?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (shouldDelete == true) {
                                      await onDeleteEntry(entry);
                                    }
                                  },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapturesSheet extends StatelessWidget {
  const _CapturesSheet({
    required this.entry,
    required this.captures,
    required this.onTradeCapture,
  });

  final AnimalEntry entry;
  final List<CritterCapture> captures;
  final ValueChanged<CritterCapture> onTradeCapture;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${entry.commonName} Captures',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              Text(
                'No. ${entry.dexNumber.toString().padLeft(4, '0')} - ${captures.length} saved',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: captures.isEmpty
                    ? const Center(child: Text('No captures saved yet.'))
                    : ListView.separated(
                        itemCount: captures.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final capture = captures[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            capture.label,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                          Text(
                                            '${formatDateTime(capture.capturedAt)} - ${capture.source}',
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton.filledTonal(
                                      tooltip: 'Trade this capture',
                                      onPressed: () => onTradeCapture(capture),
                                      icon:
                                          const Icon(Icons.swap_horiz_outlined),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _StatsBlock(stats: capture.stats),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TradePanel extends StatelessWidget {
  const _TradePanel({
    required this.captures,
    required this.selectedCapture,
    required this.outgoingPackage,
    required this.incomingPackage,
    required this.onSelected,
    required this.onScan,
    required this.onClearIncoming,
    required this.onCompleteTrade,
  });

  final List<CritterCapture> captures;
  final CritterCapture? selectedCapture;
  final TradePackage? outgoingPackage;
  final TradePackage? incomingPackage;
  final ValueChanged<CritterCapture?> onSelected;
  final VoidCallback onScan;
  final VoidCallback onClearIncoming;
  final VoidCallback onCompleteTrade;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final children = [
            Expanded(child: _buildOutgoing(context)),
            SizedBox(width: wide ? 16 : 0, height: wide ? 0 : 16),
            Expanded(child: _buildIncoming(context)),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Trade',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Pick a capture to offer, scan a friend code if you want something back, then continue.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: children)
                    : Column(children: children),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: selectedCapture == null && incomingPackage == null
                    ? null
                    : onCompleteTrade,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Continue trade'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOutgoing(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final menuColor = dark ? const Color(0xff17262e) : const Color(0xfffffcf4);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your Offer',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: selectedCapture?.id,
            isExpanded: true,
            dropdownColor: menuColor,
            borderRadius: BorderRadius.circular(8),
            style: theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
            iconEnabledColor: colors.primary,
            decoration: InputDecoration(
              filled: true,
              fillColor: menuColor,
              border: const OutlineInputBorder(),
              labelText: 'Capture',
              labelStyle: TextStyle(color: colors.onSurfaceVariant),
            ),
            items: captures
                .map(
                  (capture) => DropdownMenuItem(
                    value: capture.id,
                    child: Text(
                      '${capture.commonName} - ${formatDateTime(capture.capturedAt)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: captures.isEmpty
                ? null
                : (id) {
                    onSelected(
                      captures.where((capture) => capture.id == id).firstOrNull,
                    );
                  },
          ),
          const SizedBox(height: 12),
          if (outgoingPackage == null)
            const Text('Choose a saved capture to make its trade QR.')
          else ...[
            _TradeQrPreview(
              package: outgoingPackage!,
              onOpenFullScreen: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        _FullScreenTradeQrScreen(package: outgoingPackage!),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            _CaptureSummary(capture: outgoingPackage!.capture),
          ],
        ],
      ),
    );
  }

  Widget _buildIncoming(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Friend Offer',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner_outlined),
            label: const Text('Scan trade QR'),
          ),
          const SizedBox(height: 12),
          if (incomingPackage == null)
            const Text('No friend capture scanned. You can still continue.')
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Incoming ${incomingPackage!.entry.commonName}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear friend offer',
                  onPressed: onClearIncoming,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            _CaptureSummary(capture: incomingPackage!.capture),
          ],
        ],
      ),
    );
  }
}

class _TradeQrPreview extends StatelessWidget {
  const _TradeQrPreview({
    required this.package,
    required this.onOpenFullScreen,
  });

  final TradePackage package;
  final VoidCallback onOpenFullScreen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth - 32 : 240.0;
        final size = min(240.0, max(128.0, availableWidth));

        return Center(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onOpenFullScreen,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.primary, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _FlashingTradeQrCode(
                      package: package,
                      size: size,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap to enlarge - ${package.toQrChunks().length} QR pieces',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FullScreenTradeQrScreen extends StatelessWidget {
  const _FullScreenTradeQrScreen({required this.package});

  final TradePackage package;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(package.capture.commonName),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = min(
              constraints.maxWidth - 32,
              constraints.maxHeight - 150,
            ).clamp(220.0, 520.0);

            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _FlashingTradeQrCode(
                        package: package,
                        size: size,
                        labelColor: Colors.black,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    children: [
                      Text(
                        package.capture.scientificName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_fullscreen),
                        label: const Text('Close full screen'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FlashingTradeQrCode extends StatefulWidget {
  const _FlashingTradeQrCode({
    required this.package,
    required this.size,
    this.labelColor = Colors.black87,
  });

  final TradePackage package;
  final double size;
  final Color labelColor;

  @override
  State<_FlashingTradeQrCode> createState() => _FlashingTradeQrCodeState();
}

class _FlashingTradeQrCodeState extends State<_FlashingTradeQrCode> {
  late List<TradeQrChunk> _chunks;
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _resetChunks();
  }

  @override
  void didUpdateWidget(covariant _FlashingTradeQrCode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.package.capture.id != widget.package.capture.id) {
      _resetChunks();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetChunks() {
    _timer?.cancel();
    _chunks = widget.package.toQrChunks();
    _index = 0;
    if (_chunks.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 850), (_) {
        if (!mounted) return;
        setState(() => _index = (_index + 1) % _chunks.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chunk = _chunks[_index];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        QrImageView(
          data: chunk.toQrData(),
          version: QrVersions.auto,
          size: widget.size,
          backgroundColor: Colors.white,
        ),
        const SizedBox(height: 8),
        Text(
          'Part ${chunk.label}',
          style: TextStyle(
            color: widget.labelColor,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _CaptureSummary extends StatelessWidget {
  const _CaptureSummary({required this.capture});

  final CritterCapture capture;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              capture.commonName,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            Text(
              capture.scientificName,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 8),
            _StatsBlock(stats: capture.stats),
          ],
        ),
      ),
    );
  }
}

class _TradeQrScannerScreen extends StatefulWidget {
  const _TradeQrScannerScreen();

  @override
  State<_TradeQrScannerScreen> createState() => _TradeQrScannerScreenState();
}

class _TradeQrScannerScreenState extends State<_TradeQrScannerScreen> {
  final _assembler = TradeQrAssembler();
  bool _handled = false;
  String _status = 'Point the camera at the flashing WildDex trade QR.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Trade QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              final raw = capture.barcodes
                  .map((barcode) => barcode.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (raw == null) return;
              try {
                final package = _assembler.addQrData(raw);
                if (package == null) {
                  setState(() => _status = _assembler.progressLabel);
                } else {
                  _handled = true;
                  Navigator.pop(context, package);
                }
              } catch (error) {
                setState(() => _status = error.toString());
              }
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.68),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xff17262e) : const Color(0xfffffcf4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: dark ? const Color(0xff50d8c8) : const Color(0xffd5cdc0),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: dark ? 22 : 16,
            offset: const Offset(0, 6),
            color: dark ? const Color(0x4d50d8c8) : const Color(0x17162522),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }
}

class EntryRepository {
  static const _entriesKey = 'wilddex.entries.v1';
  static const _photoMapKey = 'wilddex.photo_species_map.v1';
  static const _capturesKey = 'wilddex.captures.v1';

  late SharedPreferences _prefs;
  final Map<String, AnimalEntry> _entries = {};
  final Map<String, String> _photoToSpecies = {};
  final Map<String, String> _speciesAliases = {};
  final List<CritterCapture> _captures = [];

  List<AnimalEntry> get entries {
    final values = _entries.values.toList()
      ..sort((a, b) => a.dexNumber.compareTo(b.dexNumber));
    return values;
  }

  List<CritterCapture> get captures {
    final values = _captures.toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return values;
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _entries.clear();
    _photoToSpecies.clear();
    _speciesAliases.clear();
    _captures.clear();

    final rawEntries = _prefs.getString(_entriesKey);
    if (rawEntries != null && rawEntries.isNotEmpty) {
      final list = jsonDecode(rawEntries) as List<dynamic>;
      for (final item in list) {
        final entry = AnimalEntry.fromJson(item as Map<String, dynamic>);
        _storeEntry(entry);
      }
    }

    final rawMap = _prefs.getString(_photoMapKey);
    if (rawMap != null && rawMap.isNotEmpty) {
      final map = jsonDecode(rawMap) as Map<String, dynamic>;
      _photoToSpecies
        ..clear()
        ..addAll(
          map.map(
            (key, value) => MapEntry(
              key,
              _resolveSpeciesKey(value as String) ?? value,
            ),
          ),
        );
    }

    final rawCaptures = _prefs.getString(_capturesKey);
    if (rawCaptures != null && rawCaptures.isNotEmpty) {
      final list = jsonDecode(rawCaptures) as List<dynamic>;
      for (final item in list) {
        final capture = CritterCapture.fromJson(item as Map<String, dynamic>);
        final resolved = _resolveSpeciesKey(capture.speciesKey);
        if (resolved == null) continue;
        _captures.add(capture.copyWith(speciesKey: resolved));
      }
    }

    _migrateLegacyCaptures();
    _syncAllScanCounts();
    await _persist();
  }

  AnimalEntry? entryForPhotoHash(String hash) {
    final species = _resolveSpeciesKey(_photoToSpecies[hash]);
    if (species == null) return null;
    return _entries[species];
  }

  AnimalEntry? entryForSpecies(String speciesKey) {
    final resolved = _resolveSpeciesKey(speciesKey);
    if (resolved == null) return null;
    return _entries[resolved];
  }

  AnimalEntry? entryForGenerated(AnimalEntry generated) {
    final exact = entryForSpecies(generated.speciesKey);
    if (exact != null) return exact;

    for (final entry in _entries.values) {
      if (entriesShouldMerge(entry, generated)) return entry;
    }
    return null;
  }

  AnimalEntry? entryForIdentity(AnimalIdentity identity) {
    final exact = entryForSpecies(identity.speciesKey);
    if (exact != null) return exact;

    for (final entry in _entries.values) {
      if (entryMatchesIdentity(entry, identity)) return entry;
    }
    return null;
  }

  Future<AnimalEntry?> recordScanForPhotoHash(String photoHash) async {
    final speciesKey = _resolveSpeciesKey(_photoToSpecies[photoHash]);
    if (speciesKey == null) return null;
    final entry = _entries[speciesKey];
    if (entry == null) return null;
    final updated = _syncScanCount(speciesKey);
    await _persist();
    return updated ?? entry;
  }

  Future<AnimalEntry> attachPhotoToSpecies(
    String photoHash,
    String speciesKey,
  ) async {
    final resolved = _resolveSpeciesKey(speciesKey) ?? speciesKey;
    _photoToSpecies[photoHash] = resolved;
    final entry = _entries[resolved];
    if (entry == null) {
      throw StateError('No cached entry for $resolved.');
    }
    final updated = _syncScanCount(resolved) ?? entry;
    await _persist();
    return updated;
  }

  Future<AnimalEntry> saveEntry(AnimalEntry entry, String photoHash) async {
    final withResolvedNumber = entry.copyWith(
      dexNumber: entry.isNotAnimal
          ? entry.dexNumber
          : _uniqueDexNumber(entry.scientificName, entry.speciesKey),
      scanCount: entry.scanCount < 1 ? 1 : entry.scanCount,
    );
    final saved = _storeEntry(withResolvedNumber);
    _photoToSpecies[photoHash] = saved.speciesKey;
    await _persist();
    return saved;
  }

  List<CritterCapture> capturesForSpecies(String speciesKey) {
    final resolved = _resolveSpeciesKey(speciesKey);
    if (resolved == null) return const [];
    return _captures
        .where((capture) => _resolveSpeciesKey(capture.speciesKey) == resolved)
        .toList()
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  Duration cooldownRemaining(String speciesKey, Duration cooldown) {
    if (cooldown <= Duration.zero) return Duration.zero;
    final speciesCaptures = capturesForSpecies(speciesKey);
    if (speciesCaptures.isEmpty) return Duration.zero;

    final lastCapture = speciesCaptures.first.capturedAt;
    final elapsed = DateTime.now().difference(lastCapture);
    if (elapsed >= cooldown) return Duration.zero;
    return cooldown - elapsed;
  }

  Future<CritterCapture> addCapture({
    required AnimalEntry entry,
    required Map<String, int> stats,
    String label = 'Wild capture',
    String source = 'local',
  }) async {
    final resolved = _resolveSpeciesKey(entry.speciesKey) ?? entry.speciesKey;
    final capture = CritterCapture(
      id: newCaptureId(),
      speciesKey: resolved,
      commonName: entry.commonName,
      scientificName: entry.scientificName,
      label: label,
      stats: AnimalEntry._statsMap(stats),
      capturedAt: DateTime.now(),
      source: source,
    );
    _captures.add(capture);
    _syncScanCount(resolved);
    await _persist();
    return capture;
  }

  Future<AnimalEntry> recordCapture({
    required String photoHash,
    required AnimalEntry entry,
    required Map<String, int> stats,
  }) async {
    final resolved = _resolveSpeciesKey(entry.speciesKey) ?? entry.speciesKey;
    _photoToSpecies[photoHash] = resolved;
    await addCapture(entry: entry, stats: stats);
    return _entries[resolved] ?? entry;
  }

  Future<void> deleteCapture(String captureId) async {
    final capture = _captures.where((item) => item.id == captureId).firstOrNull;
    if (capture == null) return;
    _captures.removeWhere((item) => item.id == captureId);
    _syncScanCount(capture.speciesKey);
    await _persist();
  }

  Future<void> importTradePackage(TradePackage package) async {
    final savedEntry = saveEntryWithoutScan(package.entry);
    final imported = package.capture.copyWith(
      id: newCaptureId(),
      speciesKey: savedEntry.speciesKey,
      commonName: savedEntry.commonName,
      scientificName: savedEntry.scientificName,
      source: 'trade',
      capturedAt: DateTime.now(),
    );
    _captures.add(imported);
    _syncScanCount(savedEntry.speciesKey);
    await _persist();
  }

  AnimalEntry saveEntryWithoutScan(AnimalEntry entry) {
    final withResolvedNumber = entry.copyWith(
      dexNumber: entry.isNotAnimal
          ? entry.dexNumber
          : _uniqueDexNumber(entry.scientificName, entry.speciesKey),
    );
    return _storeEntry(withResolvedNumber);
  }

  Future<AnimalEntry?> removeOneScan(String speciesKey) async {
    final resolved = _resolveSpeciesKey(speciesKey);
    if (resolved == null) return null;

    final entry = _entries[resolved];
    if (entry == null) return null;

    final speciesCaptures = capturesForSpecies(resolved);
    if (speciesCaptures.isNotEmpty) {
      _captures.removeWhere((item) => item.id == speciesCaptures.first.id);
      final updated = _syncScanCount(resolved);
      await _persist();
      return updated;
    }

    if (entry.scanCount <= 0) {
      return entry;
    }

    final updated = entry.copyWith(scanCount: entry.scanCount - 1);
    _entries[resolved] = updated;
    _rebuildAliases();
    await _persist();
    return updated;
  }

  Future<void> deleteEntry(String speciesKey) async {
    final resolved = _resolveSpeciesKey(speciesKey);
    if (resolved == null) return;

    _entries.remove(resolved);
    _captures.removeWhere((capture) {
      return (_resolveSpeciesKey(capture.speciesKey) ?? capture.speciesKey) ==
          resolved;
    });
    _photoToSpecies.removeWhere((_, value) {
      return (_resolveSpeciesKey(value) ?? value) == resolved;
    });
    _rebuildAliases();
    await _persist();
  }

  int _uniqueDexNumber(String scientificName, String speciesKey) {
    var number = dexNumberForScientificName(scientificName);
    final occupied = _entries.values
        .where((entry) => entry.speciesKey != speciesKey)
        .map((entry) => entry.dexNumber)
        .toSet();
    while (occupied.contains(number)) {
      number = number == 9999 ? 1 : number + 1;
    }
    return number;
  }

  Future<void> _persist() async {
    final data = jsonEncode(entries.map((entry) => entry.toJson()).toList());
    await _prefs.setString(_entriesKey, data);
    final normalizedPhotoMap = _photoToSpecies.map(
      (hash, key) => MapEntry(hash, _resolveSpeciesKey(key) ?? key),
    );
    await _prefs.setString(_photoMapKey, jsonEncode(normalizedPhotoMap));
    await _prefs.setString(
      _capturesKey,
      jsonEncode(_captures.map((capture) => capture.toJson()).toList()),
    );
  }

  AnimalEntry _storeEntry(AnimalEntry entry) {
    final mergeKey = _findMergeKey(entry);
    if (mergeKey == null) {
      _entries[entry.speciesKey] = entry;
      _registerAliases(entry, entry.speciesKey);
      return entry;
    }

    final merged = _entries[mergeKey]!.mergeWith(entry);
    _entries.remove(mergeKey);
    _entries[merged.speciesKey] = merged;
    for (var index = 0; index < _captures.length; index++) {
      final capture = _captures[index];
      if ((_resolveSpeciesKey(capture.speciesKey) ?? capture.speciesKey) ==
          mergeKey) {
        _captures[index] = capture.copyWith(
          speciesKey: merged.speciesKey,
          commonName: merged.commonName,
          scientificName: merged.scientificName,
        );
      }
    }
    _rebuildAliases();
    _syncScanCount(merged.speciesKey);
    return merged;
  }

  String? _findMergeKey(AnimalEntry entry) {
    final exact = _resolveSpeciesKey(entry.speciesKey);
    if (exact != null) return exact;

    for (final existing in _entries.entries) {
      if (entriesShouldMerge(existing.value, entry)) return existing.key;
    }
    return null;
  }

  String? _resolveSpeciesKey(String? key) {
    if (key == null || key.trim().isEmpty) return null;
    final normalized = normalizeSpecies(key);
    if (_entries.containsKey(normalized)) return normalized;
    final alias = _speciesAliases[normalized];
    if (alias != null) return alias;

    final generic = genericScientificKey(key);
    if (generic.isEmpty) return null;
    for (final entry in _entries.values) {
      final entryScientific = normalizeSpecies(entry.scientificName);
      if (entry.aliasKeys.contains(generic) ||
          entryScientific.startsWith('$generic ')) {
        return entry.speciesKey;
      }
    }
    return null;
  }

  void _registerAliases(AnimalEntry entry, String targetKey) {
    for (final alias in entry.aliasKeys) {
      _speciesAliases[alias] = targetKey;
    }
  }

  void _rebuildAliases() {
    _speciesAliases.clear();
    for (final entry in _entries.values) {
      _registerAliases(entry, entry.speciesKey);
    }
  }

  void _migrateLegacyCaptures() {
    if (_captures.isNotEmpty) return;

    for (final entry in _entries.values) {
      if (entry.isNotAnimal) continue;
      final count = entry.scanCount <= 0 ? 1 : entry.scanCount;
      for (var index = 0; index < count; index++) {
        _captures.add(
          CritterCapture(
            id: newCaptureId(),
            speciesKey: entry.speciesKey,
            commonName: entry.commonName,
            scientificName: entry.scientificName,
            label: index == 0 ? 'Legacy sighting' : 'Saved sighting',
            stats: entry.stats,
            capturedAt: entry.createdAt.add(Duration(seconds: index)),
            source: 'legacy',
          ),
        );
      }
    }
  }

  void _syncAllScanCounts() {
    for (final speciesKey in _entries.keys.toList()) {
      _syncScanCount(speciesKey);
    }
  }

  AnimalEntry? _syncScanCount(String speciesKey) {
    final resolved = _resolveSpeciesKey(speciesKey) ?? speciesKey;
    final entry = _entries[resolved];
    if (entry == null) return null;
    if (entry.isNotAnimal) return entry;

    final count = _captures.where((capture) {
      return (_resolveSpeciesKey(capture.speciesKey) ?? capture.speciesKey) ==
          resolved;
    }).length;
    final updated = entry.copyWith(scanCount: count);
    _entries[resolved] = updated;
    _rebuildAliases();
    return updated;
  }
}

class OpenAiEntryService {
  String apiKey = openAiApiKey;

  Future<AnimalIdentity> identifyAnimal(
    List<int> imageBytes, {
    LocationHint? locationHint,
  }) async {
    final payload = await _sendVisionRequest(
      imageBytes,
      prompt: _identityPromptWithLocation(locationHint),
      maxOutputTokens: 450,
    );
    return AnimalIdentity.fromJson(payload);
  }

  Future<AnimalEntry> generateEntry(
    List<int> imageBytes, {
    LocationHint? locationHint,
    AnimalIdentity? identity,
  }) async {
    final payload = await _sendVisionRequest(
      imageBytes,
      prompt: _fullPromptWithLocation(locationHint, identity),
      maxOutputTokens: 1400,
    );
    return AnimalEntry.fromGeneratedJson(payload);
  }

  Future<Map<String, int>> generateCaptureStats(
    List<int> imageBytes, {
    required AnimalEntry entry,
    LocationHint? locationHint,
  }) async {
    final payload = await _sendVisionRequest(
      imageBytes,
      prompt: _captureStatsPrompt(entry, locationHint),
      maxOutputTokens: 350,
    );
    return AnimalEntry._statsMap(payload['stats']);
  }

  Future<Map<String, dynamic>> _sendVisionRequest(
    List<int> imageBytes, {
    required String prompt,
    required int maxOutputTokens,
  }) async {
    final uri = Uri.parse('https://api.openai.com/v1/responses');
    final body = {
      'model': openAiModel,
      'input': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_text',
              'text': prompt,
            },
            {
              'type': 'input_image',
              'image_url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
              'detail': 'low',
            },
          ],
        },
      ],
      'max_output_tokens': maxOutputTokens,
    };

    final response = await http
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          'OpenAI returned ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = _extractOutputText(decoded);
    if (text == null || text.trim().isEmpty) {
      throw Exception('OpenAI response did not include text.');
    }

    final payload = _decodeJsonObject(text);
    return payload;
  }

  String? _extractOutputText(Map<String, dynamic> response) {
    final direct = response['output_text'];
    if (direct is String) return direct;

    final output = response['output'];
    if (output is! List) return null;

    final buffer = StringBuffer();
    for (final item in output) {
      if (item is! Map<String, dynamic>) continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is Map<String, dynamic> && part['text'] is String) {
          buffer.write(part['text']);
        }
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> _decodeJsonObject(String text) {
    final trimmed = text.trim();
    try {
      return jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start == -1 || end <= start) rethrow;
      return jsonDecode(trimmed.substring(start, end + 1))
          as Map<String, dynamic>;
    }
  }
}

String _captureStatsPrompt(AnimalEntry entry, LocationHint? locationHint) {
  final locationText = locationHint == null
      ? 'No reliable location hint is available.'
      : locationHint.promptText;
  return '''
$locationText

The animal is already cached in WildDex:
common_name: "${entry.commonName}"
scientific_name: "${entry.scientificName}"
animal_group: "${entry.animalGroup}"
baseline_stats: ${jsonEncode(entry.stats)}

Generate only individual capture stats for this one photo. Do not identify a new species, do not write a description, and do not change the common or scientific name.

Stats should stay biologically consistent with the baseline species but may vary slightly for the individual animal, pose, apparent size, condition, and visibility. Usually stay within 15 points of the baseline. Keep each value from 0 to 100.

Return only valid JSON with this exact shape:
{
  "stats": {
    "Power": 35,
    "Speed": 72,
    "Stealth": 68,
    "Defense": 28,
    "Intelligence": 61,
    "Rarity": 24
  }
}
''';
}

class LocationHintService {
  static const _channel = MethodChannel('wilddex/location');

  Future<LocationHint?> currentHint() async {
    try {
      final data = await _channel
          .invokeMapMethod<String, dynamic>('getRoundedLocation')
          .timeout(const Duration(seconds: 10));
      if (data == null) return null;
      return LocationHint.fromMap(data);
    } catch (_) {
      return null;
    }
  }
}

class LocationHint {
  const LocationHint({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;

  factory LocationHint.fromMap(Map<String, dynamic> data) {
    double rounded(double value) => (value * 10).roundToDouble() / 10;
    final latitude = data['latitude'];
    final longitude = data['longitude'];
    final accuracy = data['accuracyMeters'];

    if (latitude is! num || longitude is! num) {
      throw const FormatException('Location payload missing coordinates.');
    }

    return LocationHint(
      latitude: rounded(latitude.toDouble()),
      longitude: rounded(longitude.toDouble()),
      accuracyMeters: accuracy is num ? accuracy.toDouble() : double.nan,
    );
  }

  String get displayLabel => '$latitude, $longitude';

  String get promptText {
    final accuracy = accuracyMeters.isFinite
        ? ' Device-reported accuracy before rounding was about ${accuracyMeters.round()} meters.'
        : '';
    return 'The photo was taken near latitude $latitude, longitude $longitude, rounded to one decimal degree.$accuracy';
  }
}

String _identityPromptWithLocation(LocationHint? locationHint) {
  final locationText = locationHint == null
      ? '''
No reliable location hint is available for this scan.
Because range cannot be checked, avoid narrow species-level IDs for animals with important regional lookalikes. Use genus, family, or a cautious common group when location would matter.
'''
      : '''
${locationHint.promptText}
This location is a hard range filter for species-level guesses. Prefer animals native, introduced, or otherwise established near this region. If a visual match is outside its known range, do not choose it; choose a regional lookalike or a conservative genus/family-level ID instead.
''';

  return '''
$locationText

Identify only the animal identity. Do not write an encyclopedia entry, description, abilities, or stats.

Regional rule:
- Do not identify an animal as a species that is not known from the scan region.
- If a spider resembles a brown recluse but the location is outside brown recluse range, do not return "Loxosceles reclusa"; return a plausible local lookalike or a cautious ID such as genus/family/common group.
- If the visual evidence and regional range disagree, mark the species as uncertain rather than overclaiming.

Return only valid JSON with this exact shape:
{
  "is_animal": true,
  "common_name": "Eastern gray squirrel",
  "scientific_name": "Sciurus carolinensis",
  "animal_group": "Mammal",
  "taxonomy": {
    "class": "Mammalia",
    "order": "Rodentia",
    "family": "Sciuridae",
    "genus": "Sciurus"
  }
}

If no animal is visible, return:
{
  "is_animal": false,
  "common_name": "Not an animal",
  "scientific_name": "not-an-animal",
  "animal_group": "None",
  "taxonomy": {}
}

Use one stable scientific name. If the exact species is uncertain, use a stable genus-level name like "Armadillidium sp." or a family-level/common-group ID, and do not switch between "sp." and "spp.".
''';
}

String debugIdentityPromptForTests(LocationHint? locationHint) {
  return _identityPromptWithLocation(locationHint);
}

String _fullPromptWithLocation(
    LocationHint? locationHint, AnimalIdentity? identity) {
  if (locationHint == null) {
    return '''
No reliable location hint is available for this scan.

${identity?.promptText ?? ''}

$_prompt
''';
  }

  return '''
${locationHint.promptText}

Use this location as a strong species-range constraint. Prefer species native, introduced, or established near this region. Do not return a species that is outside its known range; use a regional lookalike or conservative genus/family-level ID instead.

${identity?.promptText ?? ''}

$_prompt
''';
}

const _prompt = '''
Identify whether this photo contains a real animal.

If no animal is visible, or the image is too unclear to identify an animal, return a shared non-animal entry using:
common_name: "Not an animal"
scientific_name: "not-an-animal"
animal_group: "None"
description: "No animal was detected in this scan."

Return only valid JSON with this exact shape:
{
  "is_animal": true,
  "common_name": "Eastern gray squirrel",
  "scientific_name": "Sciurus carolinensis",
  "animal_group": "Mammal",
  "taxonomy": {
    "kingdom": "Animalia",
    "phylum": "Chordata",
    "class": "Mammalia",
    "order": "Rodentia",
    "family": "Sciuridae",
    "genus": "Sciurus",
    "species": "S. carolinensis"
  },
  "habitat": "Deciduous and mixed forests, parks, and suburbs",
  "diet": "Nuts, seeds, buds, fungi, and occasional insects",
  "range": "Eastern North America and introduced regions",
  "abilities": ["Climbing", "Caching food", "Agile jumping"],
  "stats": {
    "Power": 35,
    "Speed": 72,
    "Stealth": 68,
    "Defense": 28,
    "Intelligence": 61,
    "Rarity": 24
  },
  "voice_line": "Eastern gray squirrel. The acorn caching animal.",
  "description": "A concise, animated natural-history description suitable for text-to-speech. Do not mention Pokemon, Pokedex, Bulbapedia, or copyrighted franchises."
}

Use title case for common_name. Use the best species-level scientific name only when the visual evidence and regional range both support it. If an animal is present but the exact species is uncertain, use a stable genus-level name like "Armadillidium sp." or a family-level/common-group ID instead of switching between "sp.", "spp.", and species guesses. Do not invent an animal when the photo does not show one.

Never choose a famous but out-of-region species just because it is a close visual match. For example, do not identify a brown-recluse-like spider as "Loxosceles reclusa" when the scan location is outside brown recluse range; choose a local lookalike or cautious higher-level ID.

Keep stats stable for the biological animal, not the individual photo. If the same common animal is scanned again, reuse the same style of stats instead of inventing a new stat profile.
''';

class WikipediaImageService {
  Future<WikiImage?> findImage(String commonName, String scientificName) async {
    for (final title in [commonName, scientificName]) {
      final image = await _summaryImage(title);
      if (image != null) return image;
    }
    return null;
  }

  Future<WikiImage?> _summaryImage(String title) async {
    final normalized = title.trim().replaceAll(' ', '_');
    if (normalized.isEmpty) return null;

    final uri = Uri.parse(
      'https://en.wikipedia.org/api/rest_v1/page/summary/'
      '${Uri.encodeComponent(normalized)}',
    );

    final response = await http.get(
      uri,
      headers: const {
        'User-Agent': 'WildDex personal Flutter app (local development)',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final thumbnail = data['thumbnail'];
    if (thumbnail is! Map<String, dynamic>) return null;
    final source = thumbnail['source'];
    if (source is! String || source.isEmpty) return null;

    return WikiImage(
      title: (data['title'] as String?) ?? title,
      imageUrl: source,
    );
  }
}

class WikiImage {
  const WikiImage({required this.title, required this.imageUrl});

  final String title;
  final String imageUrl;
}

class CritterCapture {
  const CritterCapture({
    required this.id,
    required this.speciesKey,
    required this.commonName,
    required this.scientificName,
    required this.label,
    required this.stats,
    required this.capturedAt,
    required this.source,
  });

  final String id;
  final String speciesKey;
  final String commonName;
  final String scientificName;
  final String label;
  final Map<String, int> stats;
  final DateTime capturedAt;
  final String source;

  CritterCapture copyWith({
    String? id,
    String? speciesKey,
    String? commonName,
    String? scientificName,
    String? label,
    Map<String, int>? stats,
    DateTime? capturedAt,
    String? source,
  }) {
    return CritterCapture(
      id: id ?? this.id,
      speciesKey: speciesKey ?? this.speciesKey,
      commonName: commonName ?? this.commonName,
      scientificName: scientificName ?? this.scientificName,
      label: label ?? this.label,
      stats: stats ?? this.stats,
      capturedAt: capturedAt ?? this.capturedAt,
      source: source ?? this.source,
    );
  }

  factory CritterCapture.fromJson(Map<String, dynamic> json) {
    return CritterCapture(
      id: AnimalEntry._string(json['id'], fallback: newCaptureId()),
      speciesKey: AnimalEntry._string(json['speciesKey']),
      commonName:
          AnimalEntry._string(json['commonName'], fallback: 'Unknown Animal'),
      scientificName:
          AnimalEntry._string(json['scientificName'], fallback: 'Unknown'),
      label: AnimalEntry._string(json['label'], fallback: 'Wild capture'),
      stats: AnimalEntry._statsMap(json['stats']),
      capturedAt: DateTime.tryParse(AnimalEntry._string(json['capturedAt'])) ??
          DateTime.now(),
      source: AnimalEntry._string(json['source'], fallback: 'local'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'speciesKey': speciesKey,
      'commonName': commonName,
      'scientificName': scientificName,
      'label': label,
      'stats': stats,
      'capturedAt': capturedAt.toIso8601String(),
      'source': source,
    };
  }
}

class TradePackage {
  const TradePackage({required this.entry, required this.capture});

  static const prefix = 'wilddex_trade_v1:';
  static const chunkPrefix = 'wilddex_trade_chunk_v1:';
  static const chunkSize = 650;

  final AnimalEntry entry;
  final CritterCapture capture;

  String get encodedPayload =>
      base64Url.encode(utf8.encode(jsonEncode(toJson())));

  String toQrData() {
    return '$prefix$encodedPayload';
  }

  List<TradeQrChunk> toQrChunks() {
    final encoded = encodedPayload;
    final checksum = sha1.convert(utf8.encode(encoded)).toString();
    final tradeId = checksum.substring(0, 12);
    final total = max(1, (encoded.length / chunkSize).ceil());

    return [
      for (var index = 0; index < total; index++)
        TradeQrChunk(
          tradeId: tradeId,
          index: index,
          total: total,
          checksum: checksum,
          payload: encoded.substring(
            index * chunkSize,
            min(encoded.length, (index + 1) * chunkSize),
          ),
        ),
    ];
  }

  Map<String, dynamic> toJson() {
    return {
      'entry': entry.toJson(),
      'capture': capture.toJson(),
    };
  }

  static TradePackage fromQrData(String data) {
    if (!data.startsWith(prefix)) {
      throw const FormatException('That QR code is not a WildDex trade.');
    }
    return fromEncodedPayload(data.substring(prefix.length));
  }

  static TradePackage fromEncodedPayload(String encoded) {
    final decoded = utf8.decode(base64Url.decode(encoded));
    final payload = jsonDecode(decoded) as Map<String, dynamic>;
    return TradePackage(
      entry: AnimalEntry.fromJson(payload['entry'] as Map<String, dynamic>),
      capture:
          CritterCapture.fromJson(payload['capture'] as Map<String, dynamic>),
    );
  }
}

class TradeQrChunk {
  const TradeQrChunk({
    required this.tradeId,
    required this.index,
    required this.total,
    required this.checksum,
    required this.payload,
  });

  final String tradeId;
  final int index;
  final int total;
  final String checksum;
  final String payload;

  String get label => '${index + 1}/$total';

  String toQrData() {
    return '${TradePackage.chunkPrefix}$tradeId:$index:$total:$checksum:$payload';
  }

  static TradeQrChunk fromQrData(String data) {
    if (!data.startsWith(TradePackage.chunkPrefix)) {
      throw const FormatException('That QR code is not a WildDex trade chunk.');
    }

    final body = data.substring(TradePackage.chunkPrefix.length);
    final parts = body.split(':');
    if (parts.length != 5) {
      throw const FormatException('WildDex trade chunk is malformed.');
    }

    final index = int.tryParse(parts[1]);
    final total = int.tryParse(parts[2]);
    if (index == null || total == null || index < 0 || total <= 0) {
      throw const FormatException('WildDex trade chunk has bad numbering.');
    }
    if (index >= total) {
      throw const FormatException('WildDex trade chunk index is out of range.');
    }

    return TradeQrChunk(
      tradeId: parts[0],
      index: index,
      total: total,
      checksum: parts[3],
      payload: parts[4],
    );
  }
}

class TradeQrAssembler {
  final Map<int, String> _parts = {};
  String? _tradeId;
  String? _checksum;
  int? _total;

  int get collected => _parts.length;

  int get total => _total ?? 0;

  String get progressLabel {
    final expected = total;
    if (expected == 0) return 'Scanning trade pieces...';
    return 'Captured $collected of $expected trade pieces.';
  }

  TradePackage? addQrData(String data) {
    if (data.startsWith(TradePackage.prefix)) {
      return TradePackage.fromQrData(data);
    }

    final chunk = TradeQrChunk.fromQrData(data);
    if (_tradeId != null && _tradeId != chunk.tradeId) {
      reset();
    }

    _tradeId = chunk.tradeId;
    _checksum = chunk.checksum;
    _total = chunk.total;
    _parts[chunk.index] = chunk.payload;

    if (_parts.length != chunk.total) return null;

    final encoded = [
      for (var index = 0; index < chunk.total; index++) _parts[index] ?? '',
    ].join();
    final checksum = sha1.convert(utf8.encode(encoded)).toString();
    if (checksum != _checksum) {
      reset();
      throw const FormatException('WildDex trade pieces did not match.');
    }

    return TradePackage.fromEncodedPayload(encoded);
  }

  void reset() {
    _parts.clear();
    _tradeId = null;
    _checksum = null;
    _total = null;
  }
}

const _notAnimalSpeciesKey = 'not an animal';

class AnimalIdentity {
  const AnimalIdentity({
    required this.isAnimal,
    required this.commonName,
    required this.scientificName,
    required this.animalGroup,
    required this.taxonomy,
  });

  final bool isAnimal;
  final String commonName;
  final String scientificName;
  final String animalGroup;
  final Map<String, String> taxonomy;

  String get speciesKey => canonicalSpeciesKey(commonName, scientificName);

  bool get isNotAnimal => !isAnimal || speciesKey == _notAnimalSpeciesKey;

  Set<String> get aliasKeys {
    return {
      speciesKey,
      normalizeSpecies(commonName),
      normalizeSpecies(scientificName),
      genericScientificKey(scientificName),
    }..removeWhere((key) => key.isEmpty || key == 'unknown');
  }

  String get promptText {
    if (isNotAnimal) {
      return 'Preliminary identification found no animal.';
    }

    return '''
Preliminary identification:
common_name: "$commonName"
scientific_name: "$scientificName"
animal_group: "$animalGroup"

Use this identity as the starting point for the full entry. Keep the same common and scientific identity unless the image clearly contradicts it.
''';
  }

  factory AnimalIdentity.fromJson(Map<String, dynamic> json) {
    final isAnimal = json['is_animal'] == true;
    final commonName = AnimalEntry._string(
      json['common_name'],
      fallback: isAnimal ? 'Unknown Animal' : 'Not an animal',
    );
    final scientificName = AnimalEntry._string(
      json['scientific_name'],
      fallback: isAnimal ? 'Unknown' : 'not-an-animal',
    );
    final normalizedCommonName = normalizeSpecies(commonName);
    final normalizedScientificName = normalizeSpecies(scientificName);

    if (!isAnimal ||
        normalizedCommonName == _notAnimalSpeciesKey ||
        normalizedScientificName == _notAnimalSpeciesKey) {
      return const AnimalIdentity(
        isAnimal: false,
        commonName: 'Not an animal',
        scientificName: 'not-an-animal',
        animalGroup: 'None',
        taxonomy: {},
      );
    }

    return AnimalIdentity(
      isAnimal: true,
      commonName: commonName,
      scientificName: scientificName,
      animalGroup:
          AnimalEntry._string(json['animal_group'], fallback: 'Animal'),
      taxonomy: AnimalEntry._stringMap(json['taxonomy']),
    );
  }
}

class AnimalEntry {
  const AnimalEntry({
    required this.dexNumber,
    required this.commonName,
    required this.scientificName,
    required this.animalGroup,
    required this.taxonomy,
    required this.habitat,
    required this.diet,
    required this.range,
    required this.abilities,
    required this.stats,
    required this.voiceLine,
    required this.description,
    required this.createdAt,
    required this.scanCount,
    this.imageUrl,
    this.wikipediaTitle,
  });

  final int dexNumber;
  final String commonName;
  final String scientificName;
  final String animalGroup;
  final Map<String, String> taxonomy;
  final String habitat;
  final String diet;
  final String range;
  final List<String> abilities;
  final Map<String, int> stats;
  final String voiceLine;
  final String description;
  final DateTime createdAt;
  final int scanCount;
  final String? imageUrl;
  final String? wikipediaTitle;

  String get speciesKey => canonicalSpeciesKey(commonName, scientificName);

  Set<String> get aliasKeys {
    return {
      speciesKey,
      normalizeSpecies(commonName),
      normalizeSpecies(scientificName),
      genericScientificKey(scientificName),
    }..removeWhere((key) => key.isEmpty || key == 'unknown');
  }

  bool get isNotAnimal => speciesKey == _notAnimalSpeciesKey;

  factory AnimalEntry.notAnimal() {
    return AnimalEntry(
      dexNumber: 0,
      commonName: 'Not an animal',
      scientificName: 'not-an-animal',
      animalGroup: 'None',
      taxonomy: const {
        'kingdom': 'None',
        'phylum': 'None',
        'class': 'None',
        'order': 'None',
      },
      habitat: 'No animal detected',
      diet: 'None',
      range: 'None',
      abilities: const ['False alarm', 'Empty scan', 'Reusable entry'],
      stats: const {
        'Power': 0,
        'Speed': 0,
        'Stealth': 0,
        'Defense': 0,
        'Intelligence': 0,
        'Rarity': 0,
      },
      voiceLine: 'Not an animal.',
      description: 'No animal was detected in this scan.',
      createdAt: DateTime.now(),
      scanCount: 1,
    );
  }

  factory AnimalEntry.fromGeneratedJson(Map<String, dynamic> json) {
    final isAnimal = json['is_animal'];
    final commonName = _string(json['common_name'], fallback: 'Unknown Animal');
    final scientificName =
        _string(json['scientific_name'], fallback: 'Unknown');
    final normalizedCommonName = normalizeSpecies(commonName);
    final normalizedScientificName = normalizeSpecies(scientificName);

    if (isAnimal == false ||
        normalizedCommonName == _notAnimalSpeciesKey ||
        normalizedScientificName == _notAnimalSpeciesKey) {
      return AnimalEntry.notAnimal();
    }

    return AnimalEntry(
      dexNumber: dexNumberForScientificName(scientificName),
      commonName: commonName,
      scientificName: scientificName,
      animalGroup: _string(json['animal_group'], fallback: 'Animal'),
      taxonomy: _stringMap(json['taxonomy']),
      habitat: _string(json['habitat'], fallback: 'Unknown'),
      diet: _string(json['diet'], fallback: 'Unknown'),
      range: _string(json['range'], fallback: 'Unknown'),
      abilities: _stringList(json['abilities']),
      stats: _statsMap(json['stats']),
      voiceLine: _string(json['voice_line'], fallback: 'Wild entry recorded.'),
      description: _string(
        json['description'],
        fallback: 'A real animal entry could not be confidently generated.',
      ),
      createdAt: DateTime.now(),
      scanCount: 1,
    );
  }

  factory AnimalEntry.fromJson(Map<String, dynamic> json) {
    return AnimalEntry(
      dexNumber: (json['dexNumber'] as num?)?.toInt() ?? 0,
      commonName: _string(json['commonName'], fallback: 'Unknown Animal'),
      scientificName: _string(json['scientificName'], fallback: 'Unknown'),
      animalGroup: _string(json['animalGroup'], fallback: 'Animal'),
      taxonomy: _stringMap(json['taxonomy']),
      habitat: _string(json['habitat'], fallback: 'Unknown'),
      diet: _string(json['diet'], fallback: 'Unknown'),
      range: _string(json['range'], fallback: 'Unknown'),
      abilities: _stringList(json['abilities']),
      stats: _statsMap(json['stats']),
      voiceLine: _string(json['voiceLine'], fallback: 'Wild entry recorded.'),
      description: _string(json['description'], fallback: ''),
      createdAt:
          DateTime.tryParse(_string(json['createdAt'])) ?? DateTime.now(),
      scanCount: (json['scanCount'] as num?)?.toInt() ?? 1,
      imageUrl: json['imageUrl'] as String?,
      wikipediaTitle: json['wikipediaTitle'] as String?,
    );
  }

  AnimalEntry copyWith({
    int? dexNumber,
    int? scanCount,
    String? imageUrl,
    String? wikipediaTitle,
  }) {
    return AnimalEntry(
      dexNumber: dexNumber ?? this.dexNumber,
      commonName: commonName,
      scientificName: scientificName,
      animalGroup: animalGroup,
      taxonomy: taxonomy,
      habitat: habitat,
      diet: diet,
      range: range,
      abilities: abilities,
      stats: stats,
      voiceLine: voiceLine,
      description: description,
      createdAt: createdAt,
      scanCount: scanCount ?? this.scanCount,
      imageUrl: imageUrl ?? this.imageUrl,
      wikipediaTitle: wikipediaTitle ?? this.wikipediaTitle,
    );
  }

  AnimalEntry mergeWith(AnimalEntry other) {
    final preferred = moreSpecificScientificName(
      other.scientificName,
      scientificName,
    )
        ? other
        : this;
    final fallback = identical(preferred, this) ? other : this;

    return AnimalEntry(
      dexNumber: minPositiveDexNumber(dexNumber, other.dexNumber),
      commonName: preferred.commonName,
      scientificName: preferred.scientificName,
      animalGroup: preferred.animalGroup,
      taxonomy: preferred.taxonomy.isNotEmpty
          ? preferred.taxonomy
          : fallback.taxonomy,
      habitat: preferred.habitat,
      diet: preferred.diet,
      range: preferred.range,
      abilities: preferred.abilities.isNotEmpty
          ? preferred.abilities
          : fallback.abilities,
      stats: preferred.stats,
      voiceLine: preferred.voiceLine,
      description: preferred.description,
      createdAt:
          createdAt.isBefore(other.createdAt) ? createdAt : other.createdAt,
      scanCount: scanCount + other.scanCount,
      imageUrl: preferred.imageUrl ?? fallback.imageUrl,
      wikipediaTitle: preferred.wikipediaTitle ?? fallback.wikipediaTitle,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dexNumber': dexNumber,
      'commonName': commonName,
      'scientificName': scientificName,
      'animalGroup': animalGroup,
      'taxonomy': taxonomy,
      'habitat': habitat,
      'diet': diet,
      'range': range,
      'abilities': abilities,
      'stats': stats,
      'voiceLine': voiceLine,
      'description': description,
      'createdAt': createdAt.toIso8601String(),
      'scanCount': scanCount,
      'imageUrl': imageUrl,
      'wikipediaTitle': wikipediaTitle,
    };
  }

  static String _string(Object? value, {String fallback = ''}) {
    final string = value?.toString().trim();
    return string == null || string.isEmpty ? fallback : string;
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return value.map(
      (key, item) => MapEntry(key.toString().toLowerCase(), item.toString()),
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static Map<String, int> _statsMap(Object? value) {
    const defaults = {
      'Power': 50,
      'Speed': 50,
      'Stealth': 50,
      'Defense': 50,
      'Intelligence': 50,
      'Rarity': 50,
    };
    if (value is! Map) return defaults;
    final stats = <String, int>{};
    for (final stat in defaults.keys) {
      final raw = value[stat] ?? value[stat.toLowerCase()];
      stats[stat] =
          raw is num ? raw.round().clamp(0, 100).toInt() : defaults[stat]!;
    }
    return stats;
  }
}

String normalizeSpecies(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

String canonicalSpeciesKey(String commonName, String scientificName) {
  final normalizedScientific = normalizeSpecies(scientificName);
  final normalizedCommon = normalizeSpecies(commonName);

  if (normalizedScientific == _notAnimalSpeciesKey ||
      normalizedCommon == _notAnimalSpeciesKey) {
    return _notAnimalSpeciesKey;
  }

  if (isUncertainScientificName(scientificName)) {
    return normalizedCommon.isNotEmpty
        ? normalizedCommon
        : genericScientificKey(scientificName);
  }

  return normalizedScientific.isNotEmpty
      ? normalizedScientific
      : normalizedCommon;
}

String genericScientificKey(String scientificName) {
  final tokens = normalizeSpecies(scientificName)
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return '';

  final stopTokens = {
    'sp',
    'spp',
    'species',
    'cf',
    'aff',
    'complex',
    'group',
    'unknown',
  };

  while (tokens.isNotEmpty && stopTokens.contains(tokens.last)) {
    tokens.removeLast();
  }

  return tokens.join(' ');
}

bool isUncertainScientificName(String scientificName) {
  final tokens = normalizeSpecies(scientificName)
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return true;
  if (tokens.length == 1) return true;

  const uncertainTokens = {
    'sp',
    'spp',
    'species',
    'cf',
    'aff',
    'complex',
    'group',
    'unknown',
  };
  return tokens.any(uncertainTokens.contains);
}

bool moreSpecificScientificName(String candidate, String current) {
  final candidateUncertain = isUncertainScientificName(candidate);
  final currentUncertain = isUncertainScientificName(current);
  if (candidateUncertain != currentUncertain) return !candidateUncertain;
  return normalizeSpecies(candidate).split(' ').length >
      normalizeSpecies(current).split(' ').length;
}

bool entriesShouldMerge(AnimalEntry first, AnimalEntry second) {
  if (first.speciesKey == second.speciesKey) return true;

  final firstCommon = normalizeSpecies(first.commonName);
  final secondCommon = normalizeSpecies(second.commonName);
  if (firstCommon.isEmpty || firstCommon == 'unknown animal') return false;
  if (firstCommon != secondCommon) return false;

  final firstClass = first.taxonomy['class'];
  final secondClass = second.taxonomy['class'];
  final firstOrder = first.taxonomy['order'];
  final secondOrder = second.taxonomy['order'];

  return first.animalGroup == second.animalGroup ||
      (firstClass != null && firstClass == secondClass) ||
      (firstOrder != null && firstOrder == secondOrder) ||
      isUncertainScientificName(first.scientificName) ||
      isUncertainScientificName(second.scientificName);
}

bool entryMatchesIdentity(AnimalEntry entry, AnimalIdentity identity) {
  if (entry.aliasKeys.intersection(identity.aliasKeys).isNotEmpty) return true;

  final entryCommon = normalizeSpecies(entry.commonName);
  final identityCommon = normalizeSpecies(identity.commonName);
  if (entryCommon.isEmpty || identityCommon.isEmpty) return false;
  if (entryCommon != identityCommon) return false;

  final entryClass = entry.taxonomy['class'];
  final identityClass = identity.taxonomy['class'];
  final entryOrder = entry.taxonomy['order'];
  final identityOrder = identity.taxonomy['order'];

  return entry.animalGroup == identity.animalGroup ||
      (entryClass != null && entryClass == identityClass) ||
      (entryOrder != null && entryOrder == identityOrder) ||
      isUncertainScientificName(entry.scientificName) ||
      isUncertainScientificName(identity.scientificName);
}

int minPositiveDexNumber(int first, int second) {
  if (first <= 0) return second;
  if (second <= 0) return first;
  return first < second ? first : second;
}

int dexNumberForScientificName(String scientificName) {
  final normalized = genericScientificKey(scientificName);
  if (normalized.isEmpty || normalized == 'unknown') return 0;

  const fnvPrime = 16777619;
  var hash = 2166136261;
  for (final codeUnit in normalized.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * fnvPrime) & 0xffffffff;
  }
  return (hash % 9999) + 1;
}

final _captureRandom = Random();

String newCaptureId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final randomPart = _captureRandom.nextInt(0x7fffffff);
  return '$timestamp-$randomPart';
}

List<CritterCapture> capturesForEntry(
  AnimalEntry entry,
  List<CritterCapture> captures,
) {
  return captures
      .where((capture) => capture.speciesKey == entry.speciesKey)
      .toList();
}

String formatCooldown(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds <= 0) return '0 seconds';
  final minutes = duration.inMinutes;
  if (minutes <= 0) return '$seconds seconds';
  final remainingSeconds = seconds % 60;
  if (remainingSeconds == 0) return '$minutes minutes';
  return '$minutes minutes $remainingSeconds seconds';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  final date =
      '${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return '$date $time';
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
