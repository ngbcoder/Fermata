import 'dart:async';
import 'dart:io';

import 'package:fermata_core/fermata_core.dart';
import 'package:path/path.dart' as p;

import '../repositories/annotation_repository.dart';
import '../storage/file_hasher.dart';
import '../storage/file_store.dart';
import 'music_xml_rasteriser.dart';

/// A file the user picked, before it has been inspected.
class ImportCandidate {
  const ImportCandidate({
    required this.sourcePath,
    this.title,
    this.composer,
  });

  /// Absolute path of the picked file, valid only for the duration of the
  /// import: it is a permission grant over someone else's file.
  final String sourcePath;

  /// Title override, typically parsed from a PDF's metadata.
  final String? title;

  final String? composer;

  String get fileName => p.basename(sourcePath);

  String get extension => p.extension(sourcePath).toLowerCase();

  bool get isPdf => extension == '.pdf';

  /// A MusicXML document, plain or in the zipped `.mxl` container.
  ///
  /// Both are accepted because `.mxl` is what every major notation editor
  /// actually writes (MuseScore, Sibelius, Finale, Dorico), so rejecting it
  /// would have made the format look broken for most real files. The container
  /// is read in pure Dart — no `archive` dependency and no native code.
  bool get isMusicXml => extension == '.musicxml' || extension == '.mxl';

  /// A Standard MIDI File.
  bool get isMidi => extension == '.mid' || extension == '.midi';

  /// Image formats the document picker is allowed to return.
  static const Set<String> supportedImageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.heic',
    '.heif',
  };

  static const Set<String> supportedExtensions = {
    '.pdf',
    '.musicxml',
    '.mxl',
    '.mid',
    '.midi',
    ...supportedImageExtensions,
  };

  bool get isSupported =>
      isPdf || isMusicXml || isMidi || supportedImageExtensions.contains(extension);
}

/// One file that was imported, and the pages it contributed.
class ImportedSource {
  const ImportedSource({
    required this.fileName,
    required this.storedPath,
    required this.pageCount,
    required this.contentHash,
    this.pageFiles = const [],
  });

  final String fileName;

  /// Path relative to the score's source directory.
  final String storedPath;

  final int pageCount;
  final String contentHash;

  /// Score-relative path of each rendered page, parallel to [pageCount].
  ///
  /// Empty for a PDF or a copied image, where [storedPath] *is* every page.
  /// Populated for MusicXML, whose pages are generated PNGs with no source file
  /// of their own: the `.musicxml` is still copied and kept as [storedPath] for
  /// provenance and a future re-render at higher resolution, but it is not what
  /// a page row points at.
  final List<String> pageFiles;
}

/// The result of a successful import.
class ImportResult {
  const ImportResult({
    required this.score,
    required this.pages,
    required this.sources,
    required this.duplicateWarning,
  });

  final Score score;
  final List<ScorePage> pages;
  final List<ImportedSource> sources;

  /// Existing scores that share a title and composer, if any. The import
  /// proceeded; this is advisory only.
  final List<Score> duplicateWarning;

  int get pageCount => pages.length;
}

/// Thrown when an import cannot proceed at all.
class ImportException implements Exception {
  ImportException(this.message);

  final String message;

  @override
  String toString() => 'ImportException: $message';
}

/// Supplies the number of pages in a PDF.
///
/// Declared as an interface because opening a real document needs pdfrx's
/// native engine, which cannot run in a plain Dart test. The import rules that
/// matter (page ordering, duplicate handling, multi-file combining) are
/// therefore testable against a stub.
abstract interface class PdfPageCounter {
  Future<int> pageCount(String absolutePath);
}

class NullPdfPageCounter implements PdfPageCounter {
  const NullPdfPageCounter();

  @override
  Future<int> pageCount(String absolutePath) async =>
      throw ImportException(
        'No PDF page counter configured; the app must supply one backed by '
        'pdfrx before importing PDFs.',
      );
}

/// Turns picked files into a library entry.
class ImportService {
  ImportService({
    required ScoreRepository scoreRepository,
    required FileStore fileStore,
    PdfPageCounter pdfPageCounter = const NullPdfPageCounter(),
    MusicXmlPageRasteriser musicXmlRasteriser =
        const NullMusicXmlPageRasteriser(),
  }) : _scores = scoreRepository,
       _files = fileStore,
       _pdfPages = pdfPageCounter,
       _musicXml = musicXmlRasteriser;

  final ScoreRepository _scores;
  final FileStore _files;
  final PdfPageCounter _pdfPages;
  final MusicXmlPageRasteriser _musicXml;

  /// Reports progress as files are processed.
  final _progress = StreamController<ImportProgress>.broadcast();

  Stream<ImportProgress> get progress => _progress.stream;

  /// Checks [candidates] against the library without writing anything.
  ///
  /// Lets the import screen show a duplicate warning before the user commits,
  /// and lets an exact duplicate be refused without having copied any bytes.
  Future<ImportPreview> preview(List<ImportCandidate> candidates) async {
    final unsupported = candidates
        .where((c) => !c.isSupported)
        .map((c) => c.fileName)
        .toList(growable: false);

    if (candidates.any((c) => c.isSupported)) {
      final blocked = <DuplicateAssessment>[];
      for (final candidate in candidates.where((c) => c.isSupported)) {
        final hash = await FileHasher.sha256(File(candidate.sourcePath));
        blocked.add(
          assess(
            candidate: candidate,
            contentHash: hash,
            existing: await _scores.getScores(const ScoreQuery()),
          ),
        );
      }

      final exact = blocked.where((a) => a.isExactDuplicate).toList();
      if (exact.isNotEmpty) {
        return ImportPreview(
          unsupportedFiles: unsupported,
          assessments: blocked,
          exactDuplicate: exact.first,
        );
      }

      return ImportPreview(
        unsupportedFiles: unsupported,
        assessments: blocked,
        metadataMatches: {
          for (final assessment in blocked)
            ...assessment.metadataMatches,
        }.toList(growable: false),
      );
    }

    return ImportPreview(unsupportedFiles: unsupported, assessments: const []);
  }

  /// Imports [candidates] as a single score.
  ///
  /// A PDF contributes every page it contains; an image contributes one. The
  /// picker's order is preserved, so a user selecting a folder of phone photos
  /// gets them in the order they were shot.
  ///
  /// Throws [ImportException] if nothing importable remains, or if the primary
  /// file is an exact duplicate of an existing score.
  Future<ImportResult> importScore(
    List<ImportCandidate> candidates, {
    String? title,
    String? composer,
  }) async {
    final importable = candidates.where((c) => c.isSupported).toList();
    if (importable.isEmpty) {
      throw ImportException(
        candidates.isEmpty
            ? 'No files were selected.'
            : 'None of the selected files are a supported score, image, MusicXML or MIDI.',
      );
    }

    final existing = await _scores.getScores(const ScoreQuery());
    final scoreId = newId();

    final hashes = <String, String>{};
    for (var i = 0; i < importable.length; i++) {
      final candidate = importable[i];
      hashes[candidate.sourcePath] = await FileHasher.sha256(
        File(candidate.sourcePath),
      );
      _progress.add(
        ImportProgress(
          completed: i + 1,
          total: importable.length,
          currentFile: candidate.fileName,
          phase: ImportPhase.hashing,
        ),
      );
    }

    final primaryHash = hashes[importable.first.sourcePath]!;
    final resolvedTitle = _resolveTitle(importable, title);
    final resolvedComposer = _resolveComposer(importable, composer);

    final assessment = assess(
      candidate: importable.first,
      contentHash: primaryHash,
      existing: existing,
    );
    if (assessment.isExactDuplicate) {
      throw ImportException(
        'This score is already in your library as '
        '"${assessment.blockingScore!.title}".',
      );
    }

    // Copy first, then write rows: a row pointing at a file that failed to copy
    // is worse than a failed import, because it looks like success.
    final sources = <ImportedSource>[];
    for (var i = 0; i < importable.length; i++) {
      final candidate = importable[i];
      _progress.add(
        ImportProgress(
          completed: i,
          total: importable.length,
          currentFile: candidate.fileName,
          phase: ImportPhase.copying,
        ),
      );

      final storedPath = await _files.importScoreSource(
        scoreId: scoreId,
        source: File(candidate.sourcePath),
        preferredName: candidate.fileName,
      );

      // A MusicXML document is rendered to page images rather than displayed,
      // so it contributes generated PNGs. The `.musicxml` itself stays copied as
      // [storedPath]: it is the only record of what was rendered, and it is what
      // a future higher-resolution re-render would read.
      final List<String> renderedPageFiles;
      final int pageCount;
      if (candidate.isMidi) {
        // A MIDI file is not a page image, but importing it as a library entry
        // still requires it to be a well-formed Standard MIDI File: a truncated
        // or damaged file must be refused rather than stored as a dead score.
        try {
          const SmfParser().parse(
            await File(candidate.sourcePath).readAsBytes(),
          );
        } on MidiFormatException catch (error) {
          throw ImportException(
            '"${candidate.fileName}" is not a valid MIDI file: $error',
          );
        }
        pageCount = 1;
        renderedPageFiles = const [];
      } else if (candidate.isMusicXml) {
        final render = await _renderMusicXml(candidate);
        if (render.pages.isEmpty) {
          throw ImportException(
            '"${candidate.fileName}" rendered no pages.',
          );
        }
        pageCount = render.pages.length;
        renderedPageFiles = await _writeRenderedPages(
          scoreId: scoreId,
          storedPath: storedPath,
          pages: render.pages,
        );
      } else {
        pageCount = candidate.isPdf
            ? await _pdfPages.pageCount(candidate.sourcePath)
            : 1;
        renderedPageFiles = const [];
      }
      if (pageCount < 1) {
        throw ImportException(
          '"${candidate.fileName}" does not contain any pages.',
        );
      }

      sources.add(
        ImportedSource(
          fileName: candidate.fileName,
          storedPath: storedPath,
          pageCount: pageCount,
          contentHash: hashes[candidate.sourcePath]!,
          pageFiles: renderedPageFiles,
        ),
      );
    }

    final pages = <ScorePage>[];
    var pageIndex = 0;
    for (final source in sources) {
      final isPdf = source.fileName.toLowerCase().endsWith('.pdf');
      for (var page = 1; page <= source.pageCount; page++) {
        // A rendered source has one generated file per page; every other source
        // points every page at the single copied file.
        final pagePath =
            page <= source.pageFiles.length ? source.pageFiles[page - 1] : source.storedPath;
        pages.add(
          ScorePage(
            id: newId(),
            scoreId: scoreId,
            index: pageIndex++,
            kind: isPdf ? PageSourceKind.pdf : PageSourceKind.bitmap,
            sourcePath: pagePath,
            pdfPageNumber: isPdf ? page : null,
          ),
        );
      }
    }

    final now = DateTime.now().toUtc();
    final score = Score(
      id: scoreId,
      title: resolvedTitle,
      composer: resolvedComposer,
      dateAdded: now,
      pageCount: pages.length,
      contentHash: primaryHash,
    );

    final defaultLayer = AnnotationLayer(
      id: newId(),
      scoreId: scoreId,
      name: kDefaultLayerName,
      visible: true,
      sortOrder: 0,
      createdAt: now,
    );

    await _scores.createScore(
      score: score,
      pages: pages,
      layers: [defaultLayer],
    );

    _progress.add(
      ImportProgress(
        completed: importable.length,
        total: importable.length,
        currentFile: null,
        phase: ImportPhase.done,
      ),
    );

    return ImportResult(
      score: score,
      pages: pages,
      sources: sources,
      duplicateWarning: assessment.metadataMatches,
    );
  }

  /// Renders [candidate], converting a rasteriser failure into an
/// [ImportException] so the caller sees one error type.
Future<MusicXmlRender> _renderMusicXml(ImportCandidate candidate) async {
  try {
    return await _musicXml.render(candidate.sourcePath);
  } on MusicXmlRenderException catch (error) {
    throw ImportException(error.message);
  } on FormatException catch (error) {
    // The reader throws this on a document it cannot represent. Naming the file
    // matters more than the parser's wording: the user picked several files and
    // needs to know which one to replace.
    throw ImportException(
      '"${candidate.fileName}" is not MusicXML that can be rendered: $error',
    );
  }
}

/// Writes rendered pages next to [storedPath] and returns their relative names.
///
/// Named after the source file rather than `page-1.png` so that a score whose
/// pages were re-rendered later has the new images sit beside the ones they
/// replace rather than colliding with them — and so a user browsing the score
/// directory can tell which document a page came from.
Future<List<String>> _writeRenderedPages({
  required String scoreId,
  required String storedPath,
  required List<RenderedPage> pages,
}) async {
  final directory = _files.layout.scoreSourceDirectory(scoreId);
  final stem = p.basenameWithoutExtension(storedPath);
  final written = <String>[];

  for (var i = 0; i < pages.length; i++) {
    final name = '$stem-page-${i + 1}.png';
    // writeAtomic, not a plain write: a thumbnail-style read may already be
    // racing this, and a half-written PNG surfaces as a broken image rather than
    // a missing one.
    await _files.writeAtomic(p.join(directory, name), pages[i].pngBytes);
    written.add(name);
  }
  return written;
}

DuplicateAssessment assess({
    required ImportCandidate candidate,
    required String contentHash,
    required List<Score> existing,
  }) {
    return assessDuplicates(
      contentHash: contentHash,
      title: _resolveTitle([candidate], null),
      composer: _resolveComposer([candidate], null),
      existingScores: existing,
    );
  }

  String _resolveTitle(List<ImportCandidate> candidates, String? override) {
    final trimmed = override?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;

    final explicit = candidates
        .map((c) => c.title?.trim())
        .firstWhere((t) => t != null && t.isNotEmpty, orElse: () => null);
    if (explicit != null) return explicit;

    // Fall back to the filename with its extension removed, which is far more
    // recognisable in a list than a generated placeholder.
    if (candidates.length == 1) {
      return p.basenameWithoutExtension(candidates.first.fileName);
    }
    return '${candidates.first.fileName} + ${candidates.length - 1} more';
  }

  String _resolveComposer(List<ImportCandidate> candidates, String? override) {
    final trimmed = override?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;

    final explicit = candidates
        .map((c) => c.composer?.trim())
        .firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
    return explicit ?? '';
  }

  void dispose() => _progress.close();
}

class ImportProgress {
  const ImportProgress({
    required this.completed,
    required this.total,
    required this.phase,
    this.currentFile,
  });

  final int completed;
  final int total;
  final ImportPhase phase;
  final String? currentFile;

  double get fraction => total == 0 ? 0 : completed / total;
}

enum ImportPhase { hashing, copying, done }

/// What [ImportService.preview] found, before anything is written.
class ImportPreview {
  const ImportPreview({
    required this.unsupportedFiles,
    required this.assessments,
    this.exactDuplicate,
    this.metadataMatches = const [],
  });

  final List<String> unsupportedFiles;
  final List<DuplicateAssessment> assessments;

  /// Set when the import would duplicate existing content and must be refused.
  final DuplicateAssessment? exactDuplicate;

  final List<Score> metadataMatches;

  bool get hasExactDuplicate => exactDuplicate != null;

  bool get hasMetadataSuggestion => metadataMatches.isNotEmpty;

  bool get canImport => !hasExactDuplicate && assessments.isNotEmpty;
}
