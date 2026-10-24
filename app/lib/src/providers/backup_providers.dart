import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup_service.dart';
import 'library_providers.dart';

final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  final store = await ref.watch(fileStoreProvider.future);
  return BackupService(store.layout.root);
});