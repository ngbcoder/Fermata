import 'dart:io';

import 'package:path/path.dart' as p;

/// Where Fermata keeps its files, and the layout inside it.
///
/// ```text
/// <root>/
///   db/fermata.sqlite
///   scores/<scoreId>/source/...      page sources, paths stored relative
///   scores/<scoreId>/recordings/...
///   midi/<midiId>.mid
///   thumbnails/<scoreId>.png
///   exports/                         backup archives
///   web/                             compiled companion web UI (milestone 12)
/// ```
///
/// Every path recorded in the database is relative to one of these roots, never
/// absolute, so a restored backup works from any install location.
class FermataLayout {
  FermataLayout(this.root);

  /// The library root, normally the app documents directory.
  final Directory root;

  String get dbDirectoryPath => p.join(root.path, 'db');
  String get databasePath => p.join(dbDirectoryPath, 'fermata.sqlite');

  String get scoresPath => p.join(root.path, 'scores');
  String get midiPath => p.join(root.path, 'midi');
  String get thumbnailsPath => p.join(root.path, 'thumbnails');
  String get exportsPath => p.join(root.path, 'exports');
  String get webPath => p.join(root.path, 'web');
  String get soundfontsPath => p.join(root.path, 'soundfonts');

  String scoreDirectory(String scoreId) => p.join(scoresPath, scoreId);
  String scoreSourceDirectory(String scoreId) =>
      p.join(scoreDirectory(scoreId), 'source');
  String scoreRecordingsDirectory(String scoreId) =>
      p.join(scoreDirectory(scoreId), 'recordings');

  String thumbnailFile(String scoreId) => p.join(thumbnailsPath, '$scoreId.png');

  String midiFile(String midiId) => p.join(midiPath, '$midiId.mid');

  String soundfontFile(String name) => p.join(soundfontsPath, name);

  /// Creates every directory the layout expects to exist.
  Future<void> ensureDirectories() async {
    for (final path in <String>[
      dbDirectoryPath,
      scoresPath,
      midiPath,
      thumbnailsPath,
      exportsPath,
      webPath,
      soundfontsPath,
    ]) {
      await Directory(path).create(recursive: true);
    }
  }
}
