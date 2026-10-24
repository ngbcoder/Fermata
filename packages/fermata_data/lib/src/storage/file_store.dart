import 'dart:io';

import 'package:path/path.dart' as p;

import 'fermata_layout.dart';

/// Raised when a storage operation cannot complete.
class StorageException implements Exception {
  StorageException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'StorageException: $message'
      : 'StorageException: $message ($cause)';
}

/// File operations against the library layout.
///
/// Copies, never references. A path handed back by the Android document picker
/// is a temporary permission grant over a file the app does not own; keeping it
/// would leave the library broken after a reboot or a permission revoke, and
/// would make the score impossible to include in a backup.
class FileStore {
  FileStore(this.layout);

  final FermataLayout layout;

  /// Copies [source] into the score's source directory.
  ///
  /// Returns the path relative to that directory, which is what gets stored on
  /// the page row.
  Future<String> importScoreSource({
    required String scoreId,
    required File source,
    String? preferredName,
  }) async {
    final targetDirectory = Directory(layout.scoreSourceDirectory(scoreId));
    await targetDirectory.create(recursive: true);

    final name = _uniqueName(
      targetDirectory,
      preferredName ?? p.basename(source.path),
    );

    try {
      await source.copy(p.join(targetDirectory.path, name));
    } on FileSystemException catch (error) {
      throw StorageException('Could not copy ${source.path}', cause: error);
    }

    return name;
  }

  /// Absolute path of a page source, from its score-relative path.
  File resolveScoreSource(String scoreId, String relativePath) =>
      File(p.join(layout.scoreSourceDirectory(scoreId), relativePath));

  /// Writes a generated asset atomically.
  ///
  /// Write-to-temp-then-rename matters here: a thumbnail is written while the
  /// library screen may already be reading it, and a half-written PNG would
  /// surface as a broken image rather than a missing one.
  Future<File> writeAtomic(String targetPath, List<int> bytes) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);

    final temp = File('$targetPath.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } on FileSystemException catch (error) {
      if (temp.existsSync()) {
        await temp.delete();
      }
      throw StorageException('Could not write $targetPath', cause: error);
    }
    return target;
  }

  /// Deletes a score's directory and its thumbnail.
  ///
  /// The database rows go away via the foreign key cascade; this handles the
  /// bytes on disk, which the database knows nothing about.
  Future<void> deleteScoreAssets(String scoreId) async {
    final scoreDirectory = Directory(layout.scoreDirectory(scoreId));
    if (scoreDirectory.existsSync()) {
      await scoreDirectory.delete(recursive: true);
    }

    final thumbnail = File(layout.thumbnailFile(scoreId));
    if (thumbnail.existsSync()) {
      await thumbnail.delete();
    }
  }

  /// Copies [source] into the MIDI directory under [midiId].
  ///
  /// Returns the relative file name stored on the [MidiFile].
  Future<String> importMidiSource({
    required String midiId,
    required File source,
  }) async {
    final targetDirectory = Directory(layout.midiPath);
    await targetDirectory.create(recursive: true);

    final name = '$midiId.mid';
    final target = File(p.join(targetDirectory.path, name));
    try {
      await source.copy(target.path);
    } on FileSystemException catch (error) {
      throw StorageException('Could not copy ${source.path}', cause: error);
    }
    return name;
  }

  Future<void> deleteMidiAsset(String midiId) async {
    final file = File(layout.midiFile(midiId));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// Copies [bytes] into the exports directory under [fileName].
  Future<String> writeExport(String fileName, List<int> bytes) async {
    final directory = Directory(layout.exportsPath);
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  String _uniqueName(Directory directory, String desiredName) {
    if (!File(p.join(directory.path, desiredName)).existsSync()) {
      return desiredName;
    }

    final extension = p.extension(desiredName);
    final stem = p.basenameWithoutExtension(desiredName);
    var counter = 2;
    while (true) {
      final candidate = '$stem-$counter$extension';
      if (!File(p.join(directory.path, candidate)).existsSync()) {
        return candidate;
      }
      counter++;
    }
  }
}
