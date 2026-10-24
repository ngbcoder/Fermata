import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_engine.dart';
import '../audio/flutter_midi_engine_adapter.dart';

final audioEngineProvider = Provider<AudioEngine>((ref) {
  return FlutterMidiEngineAdapter();
});