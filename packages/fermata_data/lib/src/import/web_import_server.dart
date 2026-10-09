import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'import_service.dart';

/// One file offered by the browser, held in a staging directory until the batch
/// is committed.
///
/// Uploaded bytes land on disk rather than in memory: a scanned score is
/// routinely tens of megabytes, and the import pipeline hashes and copies the
/// file anyway, so buffering it here would double the peak memory for nothing.
/// The path handed to [ImportCandidate] is absolute and temporary, which is
/// exactly the shape it documents — a permission grant or a scratch file that
/// `FileStore` copies out of.
class _StagedUpload {
  _StagedUpload({
    required this.fileName,
    required this.path,
    required this.receivedBytes,
  });

  final String fileName;
  final String path;
  final int receivedBytes;
}

/// A batch of uploads the browser intends to become one score.
class _StagingBatch {
  _StagingBatch(this.id, this.directory);

  final String id;
  final Directory directory;
  final List<_StagedUpload> uploads = [];
}

/// Progress from a browser upload, for the app to show.
sealed class WebImportEvent {
  const WebImportEvent();
}

/// A browser connected, or an upload arrived.
class WebImportActivity extends WebImportEvent {
  const WebImportActivity({required this.message});

  final String message;
}

/// A batch was imported into the library.
class WebImportCommitted extends WebImportEvent {
  const WebImportCommitted({
    required this.scoreId,
    required this.title,
    required this.fileNames,
  });

  final String scoreId;
  final String title;
  final List<String> fileNames;
}

/// Something was rejected.
class WebImportRejected extends WebImportEvent {
  const WebImportRejected({required this.message});

  final String message;
}

/// A local HTTP server that imports files picked in a browser on the same
/// network.
///
/// ## Why this exists
///
/// The app's own picker uses the Android document picker, which is the right
/// tool for one or two files and a miserable one for a folder of forty scanned
/// pages: selecting them individually, then watching them import serially on a
/// phone. A browser gives multi-file drag-and-drop and a progress readout for
/// free, which is why this exists and why the browser side is deliberately
/// *only* the file picker — every check still runs here.
///
/// ## The security posture, stated plainly
///
/// This opens a port on the local network while it is running. Two consequences
/// the design does not get to hide behind:
///
///  * **The token is the only thing protecting the library.** Every endpoint
///    that can write requires it, and [token] is compared in constant time.
///    Without it, any device on the same network could write to the library, so
///    there is deliberately no way to construct this without one.
///  * **The token travels in cleartext.** Plain HTTP is what Android permits
///    here without certificate work, so anything sniffing the local network can
///    capture the token and then has exactly the access the holder had. This is
///    a trade, not a fix: the surface exists only while the user has the server
///    switched on, and it is not reachable from off-LAN. Anything stronger needs
///    TLS with a certificate the phone can present, which is a different feature.
///
/// The page itself is served without a token, deliberately: it is a static shell
/// that asks for one, and it contains no library data. Serving it authenticated
/// would only stop someone loading an empty form.
class WebImportServer {
  WebImportServer({
    required ImportService importService,
    required this.token,
    this.port = kDefaultPort,
    this.address = kBindAddress,
    this.maxUploadBytes = kMaxUploadBytes,
  }) : assert(token.length >= kMinTokenLength, 'token too short to be a secret'),
       _import = importService;

  /// Accepts uploads from anywhere on the local network.
  ///
  /// Binding loopback instead would make the feature do nothing, and the token
  /// is what guards the surface, not the interface.
  static const String kBindAddress = '0.0.0.0';

  /// 8099 is obscure enough not to collide with a dev server the user may be
  /// running, and it avoids 80, which needs root.
  static const int kDefaultPort = 8099;

  /// Caps a single upload. A score is not a video; this exists so a stray large
  /// POST cannot exhaust the phone's memory during the drain below.
  static const int kMaxUploadBytes = 256 * 1024 * 1024;

  /// A token shorter than this is not treated as a secret, and the constructor
  /// refuses it. 32 hex characters is what `Random.secure` gives us by default.
  static const int kMinTokenLength = 32;

  /// Bearer credential every write endpoint requires.
  final String token;

  final int port;
  final String address;
  final int maxUploadBytes;

  final ImportService _import;

  HttpServer? _server;
  final _batches = <String, _StagingBatch>{};
  final _events = StreamController<WebImportEvent>.broadcast();

  Stream<WebImportEvent> get events => _events.stream;

  /// The URL to show the user, once started.
  Uri get url => Uri(
    scheme: 'http',
    host: address == kBindAddress ? _lanAddress ?? 'localhost' : address,
    port: _server?.port ?? port,
  );

  String? _lanAddress;

  /// The device's own LAN address, so the page shows an address a *different*
  /// machine can reach.
  ///
  /// `InternetAddress.loopbackIPv4` would be useless here — it is what the phone
  /// itself would use, and it does not exist on the other side of the router.
  /// A phone on Wi-Fi always has a non-loopback IPv4 in normal use, so that is
  /// what is reported; failing to find one is not fatal, and [url] falls back to
  /// `localhost` rather than advertising an address that cannot be connected to.
  static Future<String?> findLanAddress() async {
    try {
      // `lookup` takes the type as a string, not the enum.
      for (final address in await InternetAddress.lookup('IPv4')) {
        if (address.isLoopback || address.address.startsWith('169.254.')) {
          continue;
        }
        return address.address;
      }
    } on SocketException {
      // No network at all. Reported as null rather than thrown: the server is
      // still useful over loopback, and a failed lookup should not stop it.
    }
    return null;
  }

  Future<void> start() async {
    if (_server != null) return;

    final server = await HttpServer.bind(
      address,
      port,
      shared: false,
    );
    // Uploads are large and sequential; the default backlog is fine but the
    // idle keep-alive window is not, because a browser holds the connection open
    // between the page load and the first upload.
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    _lanAddress = await findLanAddress();

    _events.add(
      WebImportActivity(message: 'Import server listening on ${url.host}:${url.port}'),
    );

    unawaited(
      server.forEach((request) async {
        try {
          await _handle(request);
        } on Object catch (error) {
          // One bad request must not take the listener down; the browser would
          // see a dropped connection with no explanation.
          _events.add(
            WebImportRejected(message: 'Request failed: $error'),
          );
        } finally {
          await request.response.close();
        }
      }),
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _lanAddress = null;

    for (final batch in _batches.values) {
      unawaited(_discard(batch));
    }
    _batches.clear();

    await server?.close(force: true);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;

    switch (request.method) {
      case 'GET' when path == '/':
        return _servePage(request);
      case 'GET' when path == '/status':
        return _serveStatus(request);
      case 'POST' when path == '/upload':
        return _upload(request);
      case 'POST' when path == '/commit':
        return _commit(request);
      case 'POST' when path == '/discard':
        return _discardBatch(request);
      default:
        return _respond(request, HttpStatus.notFound, 'application/json',
            '{"error":"no such endpoint"}');
    }
  }

  /// The static page. Unauthenticated on purpose; see the class doc.
  Future<void> _servePage(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(importPageHtml);
    return request.response.close();
  }

  /// What the browser needs to build its file list.
  Future<void> _serveStatus(HttpRequest request) async {
    return _respond(
      request,
      HttpStatus.ok,
      'application/json',
      jsonEncode({
        'app': 'Fermata',
        'extensions': ImportCandidate.supportedExtensions.toList()..sort(),
        'maxUploadBytes': maxUploadBytes,
        'requiresToken': true,
      }),
    );
  }

  /// Constant-time on purpose. A length-dependent `==` leaks the token a
  /// character at a time to anyone measuring responses, and this is the only
  /// thing standing between a stranger on the network and someone's library.
  bool _authorised(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    final offered = header.substring('Bearer '.length);
    if (offered.length != token.length) return false;

    var difference = 0;
    for (var i = 0; i < offered.length; i++) {
      difference |= offered.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _upload(HttpRequest request) async {
    if (!_authorised(request)) {
      _events.add(const WebImportRejected(message: 'Rejected an unauthenticated upload'));
      await _respond(
        request,
        HttpStatus.unauthorized,
        'application/json',
        '{"error":"bad or missing token"}',
      );
      return;
    }

    final batchId = request.uri.queryParameters['batch'] ?? _newBatchId();
    final rawName = request.uri.queryParameters['name'];
    if (rawName == null || rawName.isEmpty) {
      await _respond(
        request,
        HttpStatus.badRequest,
        'application/json',
        '{"error":"name is required"}',
      );
      return;
    }

    final batch = _batches.putIfAbsent(batchId, () {
      final dir = Directory.systemTemp.createTempSync('fermata_webimport_');
      return _StagingBatch(batchId, dir);
    });

    // The browser sends the file's own name, so it is untrusted: strip any path
    // and keep the basename only. Otherwise a crafted name could write outside
    // the staging directory.
    final fileName = rawName.replaceAll('\\', '/').split('/').last;

    final target = File('${batch.directory.path}${Platform.pathSeparator}$fileName');
    var received = 0;
    // Non-null between openWrite and the final close. Held nullable so the
    // failure paths can close it exactly once without a second flag tracking
    // whether that already happened.
    IOSink? sink;
    try {
      final out = sink = target.openWrite();
      await for (final chunk in request) {
        received += chunk.length;
        if (received > maxUploadBytes) {
          await out.close();
          sink = null;
          await target.delete();
          await _respond(
            request,
            HttpStatus.requestEntityTooLarge,
            'application/json',
            '{"error":"file is too large"}',
          );
          return;
        }
        out.add(chunk);
      }
      await sink?.flush();
      await sink?.close();
      sink = null;

      batch.uploads.add(
        _StagedUpload(
          fileName: fileName,
          path: target.path,
          receivedBytes: received,
        ),
      );

      _events.add(
        WebImportActivity(
          message: 'Received $fileName (${_formatBytes(received)})',
        ),
      );

      await _respond(
        request,
        HttpStatus.ok,
        'application/json',
        jsonEncode({'batch': batchId, 'staged': batch.uploads.length}),
      );
    } on Object {
      if (sink != null) await sink.close();
      if (target.existsSync()) await target.delete();
      rethrow;
    }
  }

  Future<void> _commit(HttpRequest request) async {
    if (!_authorised(request)) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        'application/json',
        '{"error":"bad or missing token"}',
      );
      return;
    }

    final batchId = request.uri.queryParameters['batch'];
    final batch = batchId == null ? null : _batches[batchId];
    if (batch == null || batch.uploads.isEmpty) {
      await _respond(
        request,
        HttpStatus.badRequest,
        'application/json',
        '{"error":"nothing staged for that batch"}',
      );
      return;
    }

    final candidates = [
      for (final upload in batch.uploads)
        ImportCandidate(sourcePath: upload.path, title: _stem(upload.fileName)),
    ];

    try {
      // Ordered by arrival, so a folder of phone photos imports in the order
      // they were shot — the same rule the in-app picker relies on.
      final result = await _import.importScore(candidates);
      _events.add(
        WebImportCommitted(
          scoreId: result.score.id,
          title: result.score.title,
          fileNames: [for (final upload in batch.uploads) upload.fileName],
        ),
      );
      await _discard(batch);
      _batches.remove(batchId);

      await _respond(
        request,
        HttpStatus.ok,
        'application/json',
        jsonEncode({
          'ok': true,
          'scoreId': result.score.id,
          'title': result.score.title,
          'pages': result.pageCount,
        }),
      );
    } on ImportException catch (error) {
      // The staged files are deliberately *not* discarded: the import may have
      // failed on one file among several, and making the user pick them all
      // again would lose the ones that were fine.
      _events.add(WebImportRejected(message: 'Import failed: ${error.message}'));
      await _respond(
        request,
        HttpStatus.unprocessableEntity,
        'application/json',
        jsonEncode({'error': error.message}),
      );
    }
  }

  Future<void> _discardBatch(HttpRequest request) async {
    if (!_authorised(request)) {
      await _respond(
        request,
        HttpStatus.unauthorized,
        'application/json',
        '{"error":"bad or missing token"}',
      );
      return;
    }
    final batchId = request.uri.queryParameters['batch'];
    final batch = batchId == null ? null : _batches.remove(batchId);
    if (batch != null) await _discard(batch);
    await _respond(request, HttpStatus.ok, 'application/json', '{"ok":true}');
  }

  Future<void> _discard(_StagingBatch batch) async {
    try {
      if (batch.directory.existsSync()) {
        await batch.directory.delete(recursive: true);
      }
    } on FileSystemException {
      // A temp directory that will not delete is the operating system's problem,
      // not a reason to fail an import that has already succeeded.
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    String contentType,
    String body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.parse(contentType)
      ..write(body);
    return request.response.close();
  }

  static String _newBatchId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String _stem(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The import page, as one self-contained string.
///
/// Self-contained is the point: it has to work over a LAN with no internet, so
/// there is no CDN, no web font and no build step. Everything is inline, and the
/// CSS is written to be legible on a phone-sized window because the browser is
/// usually on a desktop but not always.
const String importPageHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fermata — import</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    margin: 0; padding: 1.5rem;
    max-width: 46rem; margin-inline: auto; line-height: 1.5;
  }
  h1 { font-size: 1.35rem; margin: 0 0 .25rem; }
  p.sub { margin: 0 0 1.5rem; opacity: .7; font-size: .9rem; }
  fieldset { border: 1px solid currentColor; border-radius: .6rem; padding: 1rem; margin: 0 0 1rem; }
  legend { padding: 0 .4rem; font-size: .85rem; opacity: .75; }
  label { display: block; font-size: .9rem; margin: .5rem 0 .25rem; }
  input[type=text] {
    width: 100%; padding: .55rem; border-radius: .4rem;
    border: 1px solid currentColor; font-size: 1rem;
  }
  #drop {
    border: 2px dashed currentColor; border-radius: .6rem;
    padding: 2rem 1rem; text-align: center; opacity: .8; cursor: pointer;
  }
  #drop.hot { opacity: 1; border-style: solid; }
  button {
    padding: .6rem 1.1rem; font-size: 1rem; border-radius: .4rem;
    border: 1px solid currentColor; cursor: pointer;
  }
  button[disabled] { opacity: .5; cursor: default; }
  #log { margin-top: 1rem; font-size: .85rem; white-space: pre-wrap; opacity: .85; }
  .err { color: #c0392b; }
  .ok { color: #1e8449; }
</style>
</head>
<body>
<h1>Import to Fermata</h1>
<p class="sub">Files are sent to this phone and imported as one score. They stay on the device.</p>

<fieldset>
  <legend>Pairing token</legend>
  <label for="token">Shown in the app under Settings &rarr; Import from browser</label>
  <input id="token" type="text" placeholder="paste the token" autocomplete="off" spellcheck="false">
</fieldset>

<fieldset>
  <legend>Files</legend>
  <div id="drop">Drop files here, or click to choose</div>
  <input id="picker" type="file" multiple hidden>
  <p id="list" class="sub"></p>
  <button id="go" disabled>Import as one score</button>
</fieldset>

<div id="log"></div>

<script>
const log = document.getElementById('log');
const list = document.getElementById('list');
const go = document.getElementById('go');
const tokenField = document.getElementById('token');
const drop = document.getElementById('drop');
const picker = document.getElementById('picker');
let chosen = [];

function say(text, cls) {
  const line = document.createElement('div');
  if (cls) line.className = cls;
  line.textContent = text;
  log.appendChild(line);
}

function refresh() {
  list.textContent = chosen.length
    ? chosen.length + ' file(s): ' + chosen.map(f => f.name).join(', ')
    : '';
  go.disabled = chosen.length === 0;
}

function accept(files) {
  chosen = Array.from(files);
  refresh();
}

drop.onclick = () => picker.click();
picker.onchange = () => accept(picker.files);

['dragenter', 'dragover'].forEach(name =>
  drop.addEventListener(name, e => { e.preventDefault(); drop.classList.add('hot'); }));
['dragleave', 'drop'].forEach(name =>
  drop.addEventListener(name, e => { e.preventDefault(); drop.classList.remove('hot'); }));
drop.addEventListener('drop', e => accept(e.dataTransfer.files));

go.onclick = async () => {
  const token = tokenField.value.trim();
  if (!token) { say('Paste the pairing token first.', 'err'); return; }
  go.disabled = true;

  const batch = crypto.randomUUID();
  const headers = { 'Authorization': 'Bearer ' + token };

  try {
    let n = 0;
    for (const file of chosen) {
      say('Sending ' + file.name + '…');
      // Raw bytes rather than multipart: the server already knows the name from
      // the query string, so a multipart parser here would be a parser with
      // nothing to do.
      const url = 'upload?batch=' + encodeURIComponent(batch) +
                  '&name=' + encodeURIComponent(file.name);
      const res = await fetch(url, { method: 'POST', headers, body: file });
      if (!res.ok) {
        const detail = await res.text();
        throw new Error(file.name + ' — ' + res.status + ' ' + detail);
      }
      n++;
    }

    say('Importing ' + n + ' file(s)…');
    const res = await fetch('commit?batch=' + encodeURIComponent(batch),
      { method: 'POST', headers });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error || res.statusText);

    say('Imported “' + body.title + '” — ' + body.pages + ' page(s).', 'ok');
    chosen = [];
    refresh();
  } catch (error) {
    say('Failed: ' + error.message, 'err');
  } finally {
    go.disabled = false;
  }
};
</script>
</body>
</html>
''';