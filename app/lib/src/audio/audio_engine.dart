/// Minimal synthesis surface Fermata depends on.
///
/// Everything above this interface (scheduling, UI, edits) talks to the engine
/// through these methods, so the concrete synth can be swapped without touching
/// the rest of the app.
abstract interface class AudioEngine {
  Future<void> loadSoundfont(String path);

  Future<void> playNote(int note, {int velocity = 64, int channel = 0});

  Future<void> stopNote(int note, {int velocity = 64, int channel = 0});

  Future<void> stopAllNotes();
}