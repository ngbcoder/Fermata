import 'package:flutter_midi_engine/flutter_midi_engine.dart';

import 'audio_engine.dart';

/// Adapts `flutter_midi_engine` to Fermata's [AudioEngine].
class FlutterMidiEngineAdapter implements AudioEngine {
  FlutterMidiEngineAdapter({FlutterMidiEngine? engine})
      : _engine = engine ?? FlutterMidiEngine();

  final FlutterMidiEngine _engine;

  @override
  Future<void> loadSoundfont(String path) async {
    await _engine.loadSoundfont(path);
  }

  @override
  Future<void> playNote(int note, {int velocity = 64, int channel = 0}) {
    return _engine.playNote(note: note, velocity: velocity, channel: channel);
  }

  @override
  Future<void> stopNote(int note, {int velocity = 64, int channel = 0}) {
    return _engine.stopNote(note: note, velocity: velocity, channel: channel);
  }

  @override
  Future<void> stopAllNotes() {
    return _engine.stopAllNotes();
  }
}