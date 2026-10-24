import 'dart:async';
import 'dart:io';

import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/midi_playback_controller.dart';
import '../../providers/audio_providers.dart';
import '../../providers/library_providers.dart';
import '../library/library_screen.dart';
import '../midi/midi_visualizer_screen.dart';
import 'bar_navigation_bar.dart';
import 'brush_toolbar.dart';
import 'page_stack.dart';

/// The score viewer.
///
/// The page raster and the annotation overlay are siblings inside one [Stack],
/// and that [Stack] is what the zoom transforms. Because both layers resolve
/// their geometry through the same box, ink cannot drift out of alignment with
/// the music at any zoom, density or orientation.
class ScoreViewerScreen extends ConsumerStatefulWidget {
  const ScoreViewerScreen({
    super.key,
    required this.scoreId,
    required this.title,
  });

  final String scoreId;
  final String title;

  @override
  ConsumerState<ScoreViewerScreen> createState() => _ScoreViewerScreenState();
}

/// Bar navigation is opt-in via a control rather than automatic on open.
///
/// Two reasons. Bar detection reads the text layer of every page up front, which
/// is real work on a long score, and it has to happen before the first step can
/// be trusted. And on a score with no text layer it finds nothing, so running it
/// by default would mean every scan gets a "Looking for bars…" wait for no
/// benefit. The viewer is page-based until asked otherwise.
class _ScoreViewerScreenState extends ConsumerState<ScoreViewerScreen> {
  late final TransformationController _transformController;
  late final PageController _pageController;
  int _currentPage = 0;
  bool _drawingMode = false;
  bool _eraserMode = false;
  String? _activeLayerId;
  MidiPlaybackController? _midiController;
  bool _downloadingSoundfont = false;
  Timer? _autoScrollTimer;
  bool _autoScrolling = false;

  /// Undo/redo stacks for strokes committed on this score.
  final List<Stroke> _undoStack = <Stroke>[];
  final List<Stroke> _redoStack = <Stroke>[];

  /// Whether detection has run, and what it found.
  ///
  /// Null until the first detection finishes, which is also how the footer knows
  /// to show a spinner rather than claiming a bar count it does not have.
  ///
  /// This is deliberately *not* the same field as whether bar mode is on. They
  /// were one flag, which meant switching bar mode off wrote `false` here and the
  /// footer read that as "detection found no staff": one round trip through the
  /// toggle threw away what detection had learned. That was issue #5.
  bool? _detection;

  /// Whether the footer steps by bar instead of by page.
  ///
  /// Only ever true when detection found bars, so the viewer cannot offer bar
  /// stepping on a score where there is nothing to step to.
  bool _barMode = false;

  BarCursor _cursor = BarCursor.start;

  /// Bar layouts per page index, filled in as detection completes.
  ///
  /// Kept as a map rather than a list because pages arrive out of order and a
  /// hole has to be distinguishable from "no staff on this page".
  final Map<int, BarLayout> _barLayouts = {};

  

  @override
  void initState() {
    super.initState();
    _transformController = TransformationController();
    _pageController = PageController();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _autoScrollTimer?.cancel();
    _transformController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _step(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
      return true;
    }
    return false;
  }

  /// Asks the renderer for each page's bars, filling [barMode] in when they all
  /// answer.
  ///
  /// Deliberately all pages up front rather than the visible one on demand:
  /// stepping backwards off the front of a page has to know the last bar of the
  /// page before it, and discovering that only when the user steps back is how a
  /// control ends up enabled but dead.
  Future<void> _detectBars(List<ScorePage> pages) async {
    final renderer = await ref.read(pageRendererProvider.future);
    if (!mounted) return;

    final layouts = <int, BarLayout>{};
    for (final (index, page) in pages.indexed) {
      layouts[index] = await renderer.barLayout(page);
      if (!mounted) return;
    }

    _barLayouts
      ..clear()
      ..addAll(layouts);

    // `firstNavigable`, not `BarCursor.start`: the first page of a score is
    // often a title page with no staff on it, and parking the cursor on a bar
    // that does not exist is what made the very next frame throw. See #5.
    final navigable = BarNavigator.isNavigable(_orderedLayouts(pages));
    final cursor = BarNavigator.firstNavigable(_orderedLayouts(pages));

    setState(() {
      _detection = navigable;
      _barMode = navigable;
      _cursor = cursor;
    });
  }

  /// Runs detection, treating any failure as "nothing found".
  ///
  /// The footer reads `null` as "still looking", so an escaping exception would
  /// strand it on "Looking for bars..." for good. Landing on `false` instead
  /// means the viewer falls back to page turning, which is what it would have
  /// done anyway had the scan simply yielded no text.
  Future<void> _runDetection(List<ScorePage> pages) async {
    try {
      await _detectBars(pages);
    } on Object {
      if (!mounted) return;
      setState(() {
        _detection = false;
        _barMode = false;
      });
    }
  }

  /// [_barLayouts] in page order, for [BarNavigator].
  ///
  /// Indexed by position rather than looked up by [ScorePage.indexOf]: the pages
  /// list is already in order, and `indexOf` compares by value, so two identical
  /// pages would resolve to the first one every time.
  List<BarLayout> _orderedLayouts(List<ScorePage> pages) => [
    for (var i = 0; i < pages.length; i++)
      _barLayouts[i] ?? BarLayout.empty,
  ];

  /// Scrolls so [cursor]'s bar is the music in view.
  ///
  /// Both axes matter and they are coupled. Horizontally the bar's *left* edge
  /// is aligned to the left of the screen, so every step lands the music you are
  /// about to read in the same place. Vertically the *system* the bar is in is
  /// brought near the top, because a step that crosses into the next system of
  /// the same page has to move the view at all — the bar itself may already be
  /// on screen.
  ///
  /// The transform is rebuilt from identity rather than composed onto the
  /// current one: bar positions are page fractions, so a leftover pinch would
  /// scale the offset into the wrong place, and a leftover drag would compound.
  Future<void> _scrollToCursor() async {
    final size = context.size;
    if (size == null || size.isEmpty) return;

    final pages = ref.read(scorePagesProvider(widget.scoreId)).value;
    if (pages == null || _cursor.pageIndex >= pages.length) return;
    final page = pages[_cursor.pageIndex];

    final renderer = await ref.read(pageRendererProvider.future);
    if (!mounted) return;
    final geometry = await renderer.geometry(page);
    if (geometry == null || !mounted) return;

    final layout = _barLayouts[_cursor.pageIndex] ?? BarLayout.empty;
    if (_cursor.systemIndex >= layout.systems.length) return;
    final system = layout.systems[_cursor.systemIndex];
    if (_cursor.barIndex >= system.barCount) return;
    final range = system.barRange(_cursor.barIndex);

    final fitted = geometry.fitWithin(
      availableWidth: size.width,
      availableHeight: size.height,
    );
    if (fitted.width <= 0 || fitted.height <= 0) return;

    const scale = 2.2;
    final barX = range.start * fitted.width;
    final barY = system.bounds.top * fitted.height;

    // Center horizontally, position near upper quarter vertically
    final dx = (size.width / 2) - (barX * scale);
    final dy = (size.height / 4) - (barY * scale);

    _transformController.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  /// Switches between page stepping and bar stepping.
  ///
  /// Turning bar mode *on* resets the cursor to the start of the score: the
  /// layouts may have just been discovered, and carrying a cursor from a previous
  /// session's guess would put the first bar step somewhere arbitrary. Turning
  /// it off keeps the cursor, so switching back resumes where the user was.
  void _toggleBarMode(List<ScorePage> pages) async {
    final enabling = !_barMode;
    if (enabling && !BarNavigator.isNavigable(_orderedLayouts(pages))) return;

    // `firstNavigable`, not `BarCursor.start`. Detection finding nothing used to
    // leave the footer still offering "By bar", and enabling bar mode there
    // parked a cursor on a score with no bars in it at all, which threw on the
    // next frame. Refusing the switch keeps that state unreachable rather than
    // merely unlikely.
    final cursor = enabling
        ? BarNavigator.firstNavigable(_orderedLayouts(pages))
        : _cursor;

    setState(() {
      _barMode = enabling;
      _cursor = cursor;
    });
    if (enabling) {
      await _scrollToCursor();
    } else {
      _transformController.value = Matrix4.identity();
    }
  }

  void _stepBar(int delta, List<ScorePage> pages) async {
    final layouts = _orderedLayouts(pages);
    final next = delta > 0
        ? BarNavigator.forward(_cursor, layouts)
        : BarNavigator.back(_cursor, layouts);
    if (next == _cursor) return;

    final pageChanged = next.pageIndex != _cursor.pageIndex;
    setState(() => _cursor = next);

    if (pageChanged) {
      _transformController.value = Matrix4.identity();
      await _pageController.animateToPage(
        next.pageIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      if (mounted) await _scrollToCursor();
      return;
    }
    await _scrollToCursor();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pagesValue = ref.watch(scorePagesProvider(widget.scoreId));

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
        IconButton(
          tooltip: 'Undo',
          onPressed: _undoStack.isEmpty ? null : _undo,
          icon: const Icon(Icons.undo_rounded),
        ),
        IconButton(
          tooltip: 'Redo',
          onPressed: _redoStack.isEmpty ? null : _redo,
          icon: const Icon(Icons.redo_rounded),
        ),
        pagesValue.maybeWhen(
          data: (pages) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                '${_currentPage + 1}/${pages.length}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          orElse: () => const SizedBox.shrink(),
        ),
        IconButton(
          tooltip: 'Zoom out',
            onPressed: () => _zoom(0.8),
            icon: const Icon(Icons.zoom_out_rounded),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => _zoom(1.25),
            icon: const Icon(Icons.zoom_in_rounded),
          ),
          IconButton(
            tooltip: 'Reset zoom',
            onPressed: () => _transformController.value = Matrix4.identity(),
            icon: const Icon(Icons.center_focus_strong_rounded),
          ),
          IconButton(
            tooltip: 'Layers',
            onPressed: _showLayerPicker,
            icon: const Icon(Icons.layers_rounded),
          ),
        IconButton(
          tooltip: _autoScrolling ? 'Stop auto-scroll' : 'Auto-scroll',
          onPressed: _toggleAutoScroll,
          icon: Icon(
            _autoScrolling ? Icons.pause_rounded : Icons.play_circle_outline_rounded,
          ),
        ),
        IconButton(
          tooltip: 'Visualizer',
          onPressed: _openVisualizer,
          icon: const Icon(Icons.piano_rounded),
        ),
        IconButton(
          tooltip: _downloadingSoundfont
              ? 'Downloading soundfont...'
              : (_midiController?.isPlaying == true ? 'Stop' : 'Play MIDI'),
          onPressed: _downloadingSoundfont ? null : _toggleMidiPlayback,
          icon: _downloadingSoundfont
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _midiController?.isPlaying == true
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                ),
        ),
        IconButton(
          tooltip: _eraserMode ? 'Done erasing' : 'Eraser',
          isSelected: _eraserMode,
          onPressed: () => setState(() => _eraserMode = !_eraserMode),
          icon: const Icon(Icons.auto_fix_high_rounded),
        ),
        IconButton(
          tooltip: _drawingMode ? 'Done annotating' : 'Annotate',
            isSelected: _drawingMode,
            onPressed: pagesValue.maybeWhen(
              data: (pages) => pages.isEmpty
                  ? null
                  : () => setState(() => _drawingMode = !_drawingMode),
              orElse: () => null,
            ),
            icon: Icon(
              _drawingMode ? Icons.draw_rounded : Icons.edit_outlined,
            ),
          ),
        ],
      ),
      body: switch (pagesValue) {
        AsyncData(:final value) when value.isEmpty => const Center(
          child: Text('This score has no pages.'),
        ),
        AsyncData(:final value) => Stack(
          children: [
            PageStack(
              pages: value,
              pageController: _pageController,
              transformationController: _transformController,
              drawingMode: _drawingMode,
              eraserMode: _eraserMode,
              activeLayerId: _activeLayerId,
              onPageChanged: (index) => setState(() => _currentPage = index),
              onTapZone: (zone) => _onTapZone(zone, value),
              onStrokeCompleted: _persistStroke,
              onStrokeErased: _eraseStroke,
            ),
            if (_drawingMode) const _DrawingHint(),
          ],
        ),
        AsyncError(:final error) => Center(child: Text('$error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
      bottomNavigationBar: pagesValue.maybeWhen(
        data: (pages) => pages.isEmpty
            ? null
            : _ViewerFooter(
                currentPage: _currentPage,
                pageCount: pages.length,
                drawingMode: _drawingMode,
                barMode: _detection,
                barStepping: _barMode,
                cursor: _cursor,
                layouts: _orderedLayouts(pages),
                onStep: _step,
                onStepBar: (delta) => _stepBar(delta, pages),
                onJump: _jumpTo,
                onDetect: () => _runDetection(pages),
                onToggleMode: () => _toggleBarMode(pages),
              ),
        orElse: () => null,
      ),
    );
  }

  void _toggleAutoScroll() {
    if (_autoScrolling) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      setState(() => _autoScrolling = false);
      return;
    }
    _autoScrolling = true;
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final pages = ref.read(scorePagesProvider(widget.scoreId)).value;
      if (pages == null) return;
      if (_currentPage >= pages.length - 1) {
        _toggleAutoScroll();
        return;
      }
      _step(1);
    });
    setState(() {});
  }

  /// Steps the page when bar mode is off.
  void _step(int delta) {
    final pages = ref.read(scorePagesProvider(widget.scoreId)).value;
    if (pages == null || !_pageController.hasClients) return;
    final target = (_currentPage + delta).clamp(0, pages.length - 1);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _jumpTo(int index) {
    if (!_pageController.hasClients) return;
    _transformController.value = Matrix4.identity();
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// Tapping the outer thirds of the page steps forward.
  ///
  /// Bluetooth pedal support arrives in a later milestone as key events, and not
  /// every musician will have one, so a tap target is always available.
  ///
  /// In bar mode a tap steps one bar; otherwise one page. Same gesture, so
  /// nothing about reaching for the page changes when the mode does.
  void _onTapZone(TapZone zone, List<ScorePage> pages) {
    switch (zone) {
      case TapZone.previous:
        if (_barMode) {
          _stepBar(-1, pages);
        } else {
          _step(-1);
        }
      case TapZone.next:
        if (_barMode) {
          _stepBar(1, pages);
        } else {
          _step(1);
        }
      case TapZone.none:
        break;
    }
  }

  /// Scales the current transform about the viewport centre so zooming does not
  /// drift the page into a corner.
  void _zoom(double factor) {
    final size = context.size;
    if (size == null || size.isEmpty) return;
    final current = _transformController.value;
    final currentScale = current.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor).clamp(0.5, 8.0);
    final ratio = targetScale / currentScale;
    if (ratio == 1.0) return;

    final focal = Offset(size.width / 2, size.height / 2);
    final next = current.clone()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(ratio, ratio, ratio, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _transformController.value = next;
  }

  Future<void> _eraseStroke(String strokeId) async {
    final repository = await ref.read(annotationRepositoryProvider.future);
    // Find the stroke in undo stack to push to redo? We don't have full object.
    // Delete and record an undo entry is not possible without fetching; skip undo
    // for erased strokes for now.
    await repository.deleteStroke(strokeId);
  }

  Future<void> _showLayerPicker() async {
    final repository = await ref.read(annotationRepositoryProvider.future);
    final layers = await repository.getLayers(widget.scoreId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final layer in layers)
              ListTile(
                title: Text(layer.name),
                leading: Icon(
                  layer.visible
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                selected: layer.id == _activeLayerId,
                onTap: () {
                  setState(() => _activeLayerId = layer.id);
                  Navigator.of(sheetContext).pop();
                },
                trailing: IconButton(
                  icon: Icon(
                    layer.visible
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                  onPressed: () async {
                    final navigator = Navigator.of(sheetContext);
                    await repository.setLayerVisible(layer, visible: !layer.visible);
                    if (mounted) navigator.pop();
                  },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('New layer'),
              onTap: () async {
                final navigator = Navigator.of(sheetContext);
                await repository.createLayer(
                  scoreId: widget.scoreId,
                  name: 'Layer ${layers.length + 1}',
                );
                if (mounted) navigator.pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleMidiPlayback() async {
    if (_midiController?.isPlaying == true) {
      _midiController?.stop();
      if (mounted) setState(() {});
      return;
    }
    final score = await ref.read(scoreRepositoryProvider.future).then((r) => r.getScore(widget.scoreId));
    final midiId = score?.linkedMidiId;
    if (midiId == null) return;

    final fileStore = await ref.read(fileStoreProvider.future);
    final engine = ref.read(audioEngineProvider);

    // Ensure a soundfont is available, downloading on demand the first time.
    final soundfont = File(fileStore.layout.soundfontFile('Yamaha_C7_Normalized.sf2'));
    if (!soundfont.existsSync()) {
      if (mounted) setState(() => _downloadingSoundfont = true);
      try {
        final request = await HttpClient().getUrl(
          Uri.parse('https://musical-artifacts.com/artifacts/1896/Yamaha_C7__Normalized_.sf2'),
        );
        final response = await request.close();
        final sink = soundfont.openWrite();
        await response.pipe(sink);
        await sink.flush();
        await sink.close();
      } finally {
        if (mounted) setState(() => _downloadingSoundfont = false);
      }
    }
    if (soundfont.existsSync()) {
      await engine.loadSoundfont(soundfont.path);
    }

    final bytes = await File(fileStore.layout.midiFile(midiId)).readAsBytes();
    final midiScore = SmfMidiScore.fromBytes(bytes);
    _midiController = MidiPlaybackController(engine: engine, score: midiScore);
    _midiController!.play();
    if (mounted) setState(() {});
  }

  Future<void> _openVisualizer() async {
    if (_midiController == null) {
      final score = await ref.read(scoreRepositoryProvider.future).then((r) => r.getScore(widget.scoreId));
      final midiId = score?.linkedMidiId;
      if (midiId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No MIDI linked to this score.')),
          );
        }
        return;
      }
      final fileStore = await ref.read(fileStoreProvider.future);
      final bytes = await File(fileStore.layout.midiFile(midiId)).readAsBytes();
      final midiScore = SmfMidiScore.fromBytes(bytes);
      final engine = ref.read(audioEngineProvider);
      _midiController = MidiPlaybackController(engine: engine, score: midiScore);
      if (mounted) setState(() {});
    }
    if (!mounted || _midiController == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MidiVisualizerScreen(
          score: _midiController!.score,
          currentTick: _midiController!.currentTick,
        ),
      ),
    );
  }

  Future<void> _persistStroke(Stroke stroke) async {
    final repository = await ref.read(annotationRepositoryProvider.future);
    await repository.upsertStroke(stroke);
    if (!mounted) return;
    setState(() {
      _undoStack.add(stroke);
      _redoStack.clear();
    });
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    final stroke = _undoStack.removeLast();
    final repository = await ref.read(annotationRepositoryProvider.future);
    await repository.deleteStroke(stroke.id);
    if (!mounted) return;
    setState(() => _redoStack.add(stroke));
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    final stroke = _redoStack.removeLast();
    final repository = await ref.read(annotationRepositoryProvider.future);
    await repository.upsertStroke(stroke);
    if (!mounted) return;
    setState(() => _undoStack.add(stroke));
  }
}

class _DrawingHint extends StatelessWidget {
  const _DrawingHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.inverseSurface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(
              'Drag to annotate',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onInverseSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the page sits on screen, needed to turn a bar fraction into pixels.
class _ViewerFooter extends ConsumerWidget {
  const _ViewerFooter({
    required this.currentPage,
    required this.pageCount,
    required this.drawingMode,
    required this.barMode,
    required this.barStepping,
    required this.cursor,
    required this.layouts,
    required this.onStep,
    required this.onStepBar,
    required this.onJump,
    required this.onDetect,
    required this.onToggleMode,
  });

  final int currentPage;
  final int pageCount;
  final bool drawingMode;

  /// Null while detection has not run yet.
  final bool? barMode;

  /// Whether the footer is stepping by bar right now. Distinct from [barMode],
  /// which reports whether bars were *found*.
  final bool barStepping;
  final BarCursor cursor;
  final List<BarLayout> layouts;
  final ValueChanged<int> onStep;
  final ValueChanged<int> onStepBar;
  final ValueChanged<int> onJump;
  final VoidCallback onDetect;
  final VoidCallback onToggleMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      top: false,
      child: drawingMode
          ? BrushToolbar(
              selection: ref.watch(brushProvider),
              onChanged: (value) =>
                  ref.read(brushProvider.notifier).select(value),
            )
          : BarNavigationBar(
              currentPage: currentPage,
              pageCount: pageCount,
              barMode: barMode,
              barStepping: barStepping,
              cursor: cursor,
              layouts: layouts,
              onStepPage: onStep,
              onStepBar: onStepBar,
              onJumpToPage: onJump,
              onDetect: onDetect,
              onToggleMode: onToggleMode,
            ),
    );
  }
}



