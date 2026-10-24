import 'package:fermata_data/fermata_data.dart';
import 'package:pdfrx/pdfrx.dart';

/// Counts PDF pages with pdfrx's engine.
///
/// Import needs the page count of every picked PDF to flatten a multi-file
/// selection into one score, and this is the only piece of the import pipeline
/// that genuinely requires the native engine. Everything else in
/// [ImportService] runs against a plain Dart test double.
///
/// Fermata uses pdfrx as a document loader and page renderer only. Its bundled
/// viewer widgets are built on the separate `material_ui` package, which would
/// sit awkwardly alongside this app's Material 3 theme, so nothing here touches
/// them.
class PdfrxPdfPageCounter implements PdfPageCounter {
  @override
  Future<int> pageCount(String absolutePath) async {
    // pdfrx's native initialisation must have run before the first document
    // is opened. The renderer does this lazily; import can run first, so do
    // it here too rather than relying on ordering.
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(absolutePath);
    try {
      final count = document.pages.length;
      if (count < 1) {
        throw ImportException(
          'That PDF does not contain any pages.',
        );
      }
      return count;
    } finally {
      await document.dispose();
    }
  }
}
