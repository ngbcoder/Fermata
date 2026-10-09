/// Persistence and file storage for Fermata.
///
/// Pure Dart by design: the host app supplies the drift [QueryExecutor], which
/// keeps this package free of Flutter and testable with `dart test` against an
/// in-memory database.
library;

export 'src/db/annotation_points_codec.dart';
export 'src/db/app_database.dart';
export 'src/db/tables.dart';
export 'src/import/import_service.dart';
export 'src/import/music_xml_rasteriser.dart';
export 'src/import/web_import_server.dart';
export 'src/repositories/annotation_repository.dart';
export 'src/repositories/organization_repositories.dart';
export 'src/repositories/score_repository.dart';
export 'src/storage/fermata_layout.dart';
export 'src/storage/file_hasher.dart';
export 'src/storage/file_store.dart';
