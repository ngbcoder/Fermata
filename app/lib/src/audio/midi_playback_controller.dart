import 'dart:async';

import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/foundation.dart';

import 'audio_engine.dart';

/// Drives an [AudioEngine] from a [MidiScore] using the score's own tempo map.
class MidiPlaybackController {
  MidiPlaybackController({
    required this.engine,
    required this.score,
    this.loop,
    this.countInBars = 0,
  });

  final AudioEngine engine;
  final MidiScore score;
  final LoopRange? loop;
  final int countInBars;

  Timer? _timer;
  DateTime? _startedAt;
  final Set<int> _active = <int>{};
  int _nextNote = 0;

  /// The tick currently being played, for visualizers.
  final ValueNotifier<int> currentTick = ValueNotifier<int>(0);

  bool get isPlaying => _timer != null;

  Duration get _countInDuration {
    if (countInBars <= 0) return Duration.zero;
    final signature = score.timeSignatureMap.isEmpty
        ? const TimeSignature(tick: 0, numerator: 4, denominator: 4)
        : score.timeSignatureMap.first;
    final ticksPerBar = signature.ticksPerBar(score.ticksPerQuarterNote);
    return score.tickToDuration(ticksPerBar * countInBars);
  }

  void play() {
    if (isPlaying) return;
    _active.clear();
    _nextNote = 0;
    currentTick.value = 0;
    _startedAt = DateTime.now().add(_countInDuration);
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final note in _active.toList()) {
      unawaited(engine.stopNote(note));
    }
    _active.clear();
  }

  void _resetNextNote(int minTick) {
    _nextNote = score.notes.indexWhere((n) => n.startTick >= minTick);
    if (_nextNote < 0) _nextNote = score.notes.length;
  }

  void _tick() {
    final now = DateTime.now();
    final elapsed = now.difference(_startedAt!);
    if (elapsed.isNegative) return;

    final tick = score.durationToTick(elapsed);
    currentTick.value = tick;

    // Handle A-B loop.
    if (loop != null && loop!.isValid && tick >= loop!.endTick) {
      for (final note in _active.toList()) {
        unawaited(engine.stopNote(note));
      }
      _active.clear();
      _startedAt = now.subtract(score.tickToDuration(loop!.startTick));
      _resetNextNote(loop!.startTick);
      return;
    }

    // Start notes whose time has come.
    while (_nextNote < score.notes.length &&
        score.tickToDuration(score.notes[_nextNote].startTick) <= elapsed) {
      final note = score.notes[_nextNote];
      // Respect loop range if set.
      if (loop == null || loop!.contains(note.startTick)) {
        unawaited(engine.playNote(note.noteNumber, velocity: note.velocity.clamp(1, 127), channel: note.channel));
        _active.add(note.noteNumber);
      }
      _nextNote++;
    }

    // Stop notes that have ended.
    for (final note in List<ScoreNote>.of(score.notes)) {
      if (note.endTick <= tick && _active.contains(note.noteNumber)) {
        unawaited(engine.stopNote(note.noteNumber, channel: note.channel));
        _active.remove(note.noteNumber);
      }
    }

    if (tick >= score.endTick) {
      stop();
    }
  }
}