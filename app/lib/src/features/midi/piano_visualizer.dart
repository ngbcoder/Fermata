import 'package:flutter/material.dart';

/// A scrollable 88-key piano keyboard that highlights the given MIDI notes.
class PianoKeyboard extends StatelessWidget {
  const PianoKeyboard({
    super.key,
    required this.activeNotes,
  });

  final Set<int> activeNotes;

  static const int _firstKey = 21; // A0
  static const int _lastKey = 108; // C8

  bool _isBlack(int note) {
    final pc = note % 12;
    return pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final whiteKeys = <int>[
      for (var n = _firstKey; n <= _lastKey; n++)
        if (!_isBlack(n)) n,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final keyWidth = constraints.maxWidth / whiteKeys.length.clamp(1, 52);
        final height = constraints.maxHeight;
        return Stack(
          children: [
            Row(
              children: [
                for (final note in whiteKeys)
                  Container(
                    width: keyWidth,
                    height: height,
                    decoration: BoxDecoration(
                      color: activeNotes.contains(note)
                          ? theme.colorScheme.primary
                          : Colors.white,
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
              ],
            ),
            // Black keys overlaid.
            for (final note in [
              for (var n = _firstKey; n <= _lastKey; n++)
                if (_isBlack(n)) n,
            ])
              Positioned(
                left: _blackKeyOffset(note, whiteKeys, keyWidth),
                top: 0,
                child: Container(
                  width: keyWidth * 0.6,
                  height: height * 0.62,
                  decoration: BoxDecoration(
                    color: activeNotes.contains(note)
                        ? theme.colorScheme.primary
                        : Colors.black87,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  double _blackKeyOffset(int note, List<int> whiteKeys, double keyWidth) {
    // Find the white key just below this black key.
    var index = whiteKeys.indexWhere((w) => w > note) - 1;
    if (index < 0) index = 0;
    return (index + 0.65) * keyWidth;
  }
}