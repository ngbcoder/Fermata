import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/material.dart';

import 'piano_visualizer.dart';

class MidiVisualizerScreen extends StatelessWidget {
  const MidiVisualizerScreen({
    super.key,
    required this.score,
    required this.currentTick,
  });

  final MidiScore score;
  final ValueNotifier<int> currentTick;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Piano visualizer')),
      body: ValueListenableBuilder<int>(
        valueListenable: currentTick,
        builder: (context, tick, _) {
          return PianoKeyboard(activeNotes: score.noteNumbersAt(tick));
        },
      ),
    );
  }
}