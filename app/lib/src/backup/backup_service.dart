import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class BackupService {
  BackupService(this.root);

  final Directory root;

  Future<File> exportAll() async {
    final archive = Archive();
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root.path);
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(relative, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    final outDir = Directory(p.join(root.path, 'exports'));
    await outDir.create(recursive: true);
    final out = File(p.join(outDir.path, 'fermata-backup.zip'));
    await out.writeAsBytes(encoded, flush: true);
    return out;
  }

  Future<void> restoreFrom(File zipFile) async {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      if (!file.isFile) continue;
      final target = File(p.join(root.path, file.name));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content as List<int>, flush: true);
    }
  }
}