import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/transfer_item.dart';

// ── SSE client — wraps a sink so we can push events ──
class _SseClient {
  final StreamController<String> _ctrl;
  _SseClient(this._ctrl);
  void send(String event, Object data) {
    try {
      _ctrl.add('event: $event\ndata: ${jsonEncode(data)}\n\n');
    } catch (_) {}
  }
}

class EmbeddedServer {
  final AppState state;
  final int port;

  HttpServer? _server;
  final Map<String, List<_SseClient>> _sseClients = {};

  // Active chunked transfers: transferId → metadata + IOSink
  final Map<String, Map<String, dynamic>> _activeTransfers = {};

  // History — loaded from SharedPreferences on start, saved on every transfer
  List<Map<String, dynamic>> _history = [];
  static const String _historyKey = 'xorbit_history';

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_historyKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _history   = list.map((e) => Map<String, dynamic>.from(e)).toList();
        debugPrint('Loaded \${_history.length} history entries');
      }
    } catch (e) {
      debugPrint('History load error: \$e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyKey, jsonEncode(_history));
    } catch (e) {
      debugPrint('History save error: \$e');
    }
  }

  // Rooms: code → room data
  final Map<String, Map<String, dynamic>> _rooms = {};

  EmbeddedServer({required this.state, this.port = 3000});

  // ── START / STOP ──────────────────────────────────────

  Future<void> start() async {
    final router = Router();

    // Health
    router.get('/', _health);

    // Device info
    router.get('/info', _info);

    // SSE
    router.get('/events', _sseHandler);

    // Connection
    router.post('/connect-request', _connectRequest);
    router.post('/accept',          _accept);
    router.post('/decline',          _decline);
    router.post('/notify-declined',  _notifyDeclined);
    router.post('/disconnect',       _disconnect);

    // Chunked upload
    router.post('/chunk', _chunkHandler);

    // Transfer control
    router.post('/transfer/cancel', _cancelTransfer);

    // Clipboard
    router.post('/clipboard', _clipboardHandler);

    // Incoming files poll
    router.get('/incoming', _incoming);

    // History
    router.get('/history', _historyHandler);

    // Rooms (premium)
    router.post('/room/create', _roomCreate);
    router.post('/room/join',   _roomJoin);
    router.get('/room/<code>',  _roomGet);
    router.post('/room/leave',  _roomLeave);
    router.post('/room/kick',   _roomKick);

    // Room SSE events
    router.get('/room/events', _roomSseHandler);

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addHandler(router.call);

    await _loadHistory();
    _server = await io.serve(handler, '0.0.0.0', port);
    debugPrint('Xorbit server running on port $port — address: 0.0.0.0');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  // ── CORS MIDDLEWARE ───────────────────────────────────

  Middleware _corsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final response = await handler(request);
        return response.change(headers: _corsHeaders);
      };
    };
  }

  Map<String, String> get _corsHeaders => {
    'Access-Control-Allow-Origin':  '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  // ── SSE HELPER ────────────────────────────────────────

  void _pushSSE(String deviceId, String event, Object data) {
    for (final client in (_sseClients[deviceId] ?? [])) {
      client.send(event, data);
    }
  }

  void _pushSSEToRoom(String code, String? excludeId, String event, Object data) {
    final room = _rooms[code];
    if (room == null) return;
    for (final memberId in List<String>.from(room['members'])) {
      if (memberId != excludeId) _pushSSE(memberId, event, data);
    }
  }

  // ── SYSTEM SAVE FOLDER ────────────────────────────────

  // Returns Xorbit/<Category> folder on any platform.
  // Android: external storage Downloads/Xorbit/<Category> (visible in file manager)
  // Windows/Mac/Linux: ~/Xorbit/<Category> inside home folder
  Future<String> _saveFolder(String category) async {
    String base;

    if (Platform.isAndroid) {
      // Use external storage so it shows up in Files/file manager
      // getExternalStorageDirectory points to app-specific external dir.
      // We go two levels up to get the real external storage root.
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          // Navigate to /storage/emulated/0 from app-specific path
          final parts = ext.path.split('/');
          final rootIdx = parts.indexOf('Android');
          if (rootIdx > 0) {
            base = parts.sublist(0, rootIdx).join('/');
          } else {
            base = ext.path;
          }
        } else {
          final docs = await getApplicationDocumentsDirectory();
          base = docs.path;
        }
      } catch (_) {
        final docs = await getApplicationDocumentsDirectory();
        base = docs.path;
      }
    } else if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      base = docs.path;
    } else {
      // Desktop: use home directory
      base = Platform.environment['USERPROFILE'] ??
             Platform.environment['HOME']        ?? '';
      if (base.isEmpty) {
        final docs = await getApplicationDocumentsDirectory();
        base = docs.path;
      }
    }

    final folder = Directory(p.join(base, 'Xorbit', category));
    try {
      if (!folder.existsSync()) folder.createSync(recursive: true);
      return folder.path;
    } catch (_) {
      // Final fallback
      final docs = await getApplicationDocumentsDirectory();
      final fallback = Directory(p.join(docs.path, 'Xorbit', category));
      if (!fallback.existsSync()) fallback.createSync(recursive: true);
      return fallback.path;
    }
  }

  String _categoryFor(String filename) {
    final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
    if (['mp4','mov','avi','mkv','webm','flv'].contains(ext)) return 'Videos';
    if (['jpg','jpeg','png','gif','webp','heic','bmp'].contains(ext)) return 'Pictures';
    if (['pdf','doc','docx','xls','xlsx','ppt','pptx','txt','csv'].contains(ext)) return 'Documents';
    if (['mp3','wav','aac','flac','ogg','m4a'].contains(ext)) return 'Music';
    return 'Other';
  }

  // ── HANDLERS ──────────────────────────────────────────

  Future<Response> _health(Request req) =>
      Future.value(Response.ok(jsonEncode({'status': 'online', 'id': state.myId}),
          headers: {'content-type': 'application/json'}));

  Future<Response> _info(Request req) =>
      Future.value(Response.ok(jsonEncode({
        'id':   state.myId,
        'name': state.myName,
      }), headers: {'content-type': 'application/json'}));

  // SSE — persistent connection for real-time push to a device
  Future<Response> _sseHandler(Request req) async {
    final deviceId = req.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      return Response.badRequest(body: 'Missing deviceId');
    }

    final ctrl = StreamController<List<int>>();

    // Keep-alive ping every 15s
    final keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!ctrl.isClosed) {
        ctrl.add(utf8.encode(': ping\n\n'));
      }
    });

    // Register SSE client
    final client = _SseClient(StreamController<String>());
    // Bridge: when client sends, write to HTTP stream
    final bridgeCtrl = StreamController<String>();
    final bridgeClient = _SseClient(bridgeCtrl);
    bridgeCtrl.stream.listen((event) {
      if (!ctrl.isClosed) ctrl.add(utf8.encode(event));
    });

    if (!_sseClients.containsKey(deviceId)) _sseClients[deviceId] = [];
    _sseClients[deviceId]!.add(bridgeClient);

    // Cleanup when connection closes
    ctrl.onCancel = () {
      keepAlive.cancel();
      bridgeCtrl.close();
      _sseClients[deviceId]?.remove(bridgeClient);
    };

    return Response.ok(
      ctrl.stream,
      headers: {
        'Content-Type':                     'text/event-stream',
        'Cache-Control':                    'no-cache',
        'Connection':                       'keep-alive',
        'Access-Control-Allow-Origin':      '*',
        'X-Accel-Buffering':               'no',
      },
    );
  }

  // Connect request — sender calls this on receiver's server
  Future<Response> _connectRequest(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final fromId   = body['fromId']   as String? ?? '';
    final fromName = body['fromName'] as String? ?? 'Unknown';
    final fromIp   = body['fromIp']   as String? ?? '';
    final fromPort = body['fromPort'] as int?    ?? 3000;

    // Store full sender info so decline/accept can reach them back
    state.pendingRequests[state.myId] = fromId;
    state.pendingFromIp   = fromIp;
    state.pendingFromPort = fromPort;
    state.pendingFromName = fromName;
    state.notifyListeners();

    return _json({'message': 'request sent'});
  }

  // Accept — called on the SENDER's server by the acceptor.
  // Connects the sender side only. Acceptor connects themselves in Flutter.
  Future<Response> _accept(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final peerId   = body['peerId']   as String? ?? '';
    final peerName = body['peerName'] as String? ?? '';
    final peerIp   = body['peerIp']   as String? ?? '';
    final peerPort = body['peerPort'] as int?    ?? 3000;

    if (peerId.isNotEmpty) {
      // Connect sender to acceptor
      state.connect(XorbitDevice(
        id: peerId, name: peerName, ip: peerIp, port: peerPort));
      state.pendingRequests.clear();
      state.notifyListeners();
    }

    return _json({'message': 'connected'});
  }

  Future<Response> _decline(Request req) async {
    final fromIp   = state.pendingFromIp   ?? '';
    final fromPort = state.pendingFromPort ?? port;
    final myName   = state.myName;

    state.pendingRequests.remove(state.myId);
    state.pendingFromIp   = null;
    state.pendingFromPort = null;
    state.pendingFromName = null;
    state.notifyListeners();

    // Notify the SENDER (not us) that their request was declined
    if (fromIp.isNotEmpty) {
      Future.microtask(() async {
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 3);
          final request = await client.postUrl(
            Uri.parse('http://$fromIp:$fromPort/notify-declined'));
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'byName': myName}));
          await request.close();
          client.close();
        } catch (e) {
          debugPrint('Could not notify declined: $e');
        }
      });
    }

    return _json({'message': 'declined'});
  }

  Future<Response> _notifyDeclined(Request req) async {
    final body   = jsonDecode(await req.readAsString()) as Map;
    final byName = body['byName'] as String? ?? 'Unknown';
    // Store so UI can show snackbar
    state.declinedByName = byName;
    state.notifyListeners();
    return _json({'ok': true});
  }

  Future<Response> _disconnect(Request req) async {
    state.disconnect();
    return _json({'message': 'disconnected'});
  }

  // Chunked upload — receiver's server handles incoming chunks
  Future<Response> _chunkHandler(Request req) async {
    // Parse multipart
    final contentType = req.headers['content-type'] ?? '';
    if (!contentType.contains('multipart')) {
      return Response.badRequest(body: 'Expected multipart');
    }

    final boundary = _extractBoundary(contentType);
    if (boundary == null) return Response.badRequest(body: 'No boundary');

    // Stream body directly into memory — avoid multiple list copies
    final bodyBytes = <int>[];
    await for (final chunk in req.read()) {
      bodyBytes.addAll(chunk);
    }
    final bodyData = Uint8List.fromList(bodyBytes);

    final fields = <String, String>{};
    Uint8List? chunkBytes;

    // Parse multipart manually
    final parts = _parseMultipart(bodyData, boundary);
    for (final part in parts) {
      final disposition = part['headers']?['content-disposition'] ?? '';
      final nameMatch   = RegExp(r'name="([^"]+)"').firstMatch(disposition);
      final fname       = RegExp(r'filename="([^"]+)"').firstMatch(disposition);

      if (nameMatch != null) {
        final fieldName = nameMatch.group(1)!;
        if (fname != null) {
          chunkBytes = part['data'] as Uint8List;
        } else {
          fields[fieldName] = utf8.decode(part['data'] as Uint8List);
        }
      }
    }

    final transferId  = fields['transferId']  ?? '';
    final chunkIndex  = int.tryParse(fields['chunkIndex']  ?? '') ?? 0;
    final totalChunks = int.tryParse(fields['totalChunks'] ?? '') ?? 1;
    final totalSize   = int.tryParse(fields['totalSize']   ?? '') ?? 0;
    final filename    = fields['filename'] ?? 'file';
    final fromId      = fields['fromId']   ?? '';
    final fromName    = fields['fromName'] ?? 'Unknown';

    if (transferId.isEmpty || chunkBytes == null) {
      return Response.badRequest(body: 'Missing data');
    }

    // First chunk — set up transfer
    if (chunkIndex == 0) {
      final category    = _categoryFor(filename);
      final folder      = await _saveFolder(category);
      final safeName    = '${DateTime.now().millisecondsSinceEpoch}-${p.basename(filename)}';
      final finalPath   = p.join(folder, safeName);
      final sink        = File(finalPath).openWrite();

      _activeTransfers[transferId] = {
        'filename':  safeName,
        'original':  filename,
        'category':  category,
        'finalPath': finalPath,
        'totalSize': totalSize,
        'received':  0,
        'sink':      sink,
        'fromId':    fromId,
        'fromName':  fromName,
      };

      // Notify local UI that a transfer is starting
      final item = TransferItem.receiving(
        transferId: transferId,
        filename:   filename,
        totalSize:  totalSize,
      );
      state.addTransfer(item);
    }

    final transfer = _activeTransfers[transferId];
    if (transfer == null) return Response.badRequest(body: 'Unknown transfer');

    // Write chunk directly to file — no extra copy
    final sink = transfer['sink'] as IOSink;
    sink.add(chunkBytes);
    transfer['received'] = (transfer['received'] as int) + chunkBytes.length;

    final progress = transfer['received'] / transfer['totalSize'];

    // Update local state for receiver progress bar
    state.updateTransfer(transferId, progress: progress);

    // Last chunk
    if (chunkIndex == totalChunks - 1) {
      final finalSink = transfer['sink'] as IOSink;
      await finalSink.flush();
      await finalSink.close();

      final fileRecord = {
        'name':     transfer['filename'],
        'original': transfer['original'],
        'size':     transfer['totalSize'],
        'category': transfer['category'],
        'savedTo':  transfer['finalPath'],
      };

      // Mark done in state
      state.updateTransfer(transferId,
        status: TransferStatus.done, progress: 1.0);

      // Add to pending files for UI notification
      state.pendingFiles.add(fileRecord);
      state.notifyListeners();

      // Add to history
      _history.insert(0, {
        'transferId': transferId,
        'id': '${DateTime.now().millisecondsSinceEpoch}',
        'from':     fromId,
        'fromName': fromName,
        'to':       state.myId,
        'toName':   state.myName,
        'files':    [fileRecord],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _saveHistory(); // persist immediately

      _activeTransfers.remove(transferId);
    }

    return _json({'ok': true, 'received': transfer['received']});
  }

  Future<Response> _cancelTransfer(Request req) async {
    final body      = jsonDecode(await req.readAsString()) as Map;
    final tid       = body['transferId'] as String? ?? '';
    final transfer  = _activeTransfers[tid];
    if (transfer != null) {
      try { await (transfer['sink'] as IOSink).close(); } catch (_) {}
      try { File(transfer['finalPath'] as String).deleteSync(); } catch (_) {}
      _activeTransfers.remove(tid);
      state.updateTransfer(tid, status: TransferStatus.cancelled);
    }
    return _json({'ok': true});
  }

  Future<Response> _clipboardHandler(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map;
    final text = body['text'] as String? ?? '';
    // Push to local state — the UI will apply it to the system clipboard
    state.pendingFiles.add({'__clipboard__': text});
    state.notifyListeners();
    return _json({'ok': true});
  }

  Future<Response> _incoming(Request req) async {
    final files = List<Map<String, dynamic>>.from(state.pendingFiles);
    state.pendingFiles.clear();
    return _json({'files': files});
  }

  Future<Response> _historyHandler(Request req) async {
    final sorted = List<Map<String, dynamic>>.from(_history)
      ..sort((a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));
    return _json({'history': sorted});
  }

  // ── ROOM HANDLERS ─────────────────────────────────────

  Future<Response> _roomCreate(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final roomName = body['roomName'] as String? ?? "${state.myName}'s Room";

    final code = _generateRoomCode();
    _rooms[code] = {
      'code':      code,
      'name':      roomName,
      'creatorId': state.myId,
      'members':   [state.myId],
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };

    state.joinedRoom(
      code:      code,
      name:      roomName,
      creatorId: state.myId,
      members:   [{'id': state.myId, 'name': state.myName}],
    );

    return _json({'code': code, 'room': _rooms[code]});
  }

  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buf.write(chars[(rng + i * 7) % chars.length]);
    }
    final code = buf.toString();
    return _rooms.containsKey(code) ? _generateRoomCode() : code;
  }

  Future<Response> _roomJoin(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map;
    final code = (body['code'] as String? ?? '').toUpperCase();

    final room = _rooms[code];
    if (room == null) return Response.notFound(jsonEncode({'error': 'Room not found'}));

    final members = List<String>.from(room['members']);
    if (members.length >= 20) {
      return Response.forbidden(jsonEncode({'error': 'Room is full'}));
    }
    if (!members.contains(state.myId)) {
      members.add(state.myId);
      room['members'] = members;
    }

    state.joinedRoom(
      code:      code,
      name:      room['name'],
      creatorId: room['creatorId'],
      members:   members.map((id) => {
        'id': id, 'name': state.myId == id ? state.myName : id,
      }).toList(),
    );

    return _json({'code': code, 'room': room});
  }

  Future<Response> _roomGet(Request req, String code) async {
    final room = _rooms[code.toUpperCase()];
    if (room == null) return Response.notFound(jsonEncode({'error': 'Not found'}));
    return _json(room);
  }

  Future<Response> _roomLeave(Request req) async {
    final code = state.roomCode;
    if (code != null && _rooms.containsKey(code)) {
      final members = List<String>.from(_rooms[code]!['members']);
      members.remove(state.myId);
      if (members.isEmpty) {
        _rooms.remove(code);
      } else {
        _rooms[code]!['members'] = members;
      }
    }
    state.leftRoom();
    return _json({'ok': true});
  }

  Future<Response> _roomKick(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final targetId = body['targetId'] as String? ?? '';
    final code     = state.roomCode ?? '';

    if (_rooms.containsKey(code)) {
      final members = List<String>.from(_rooms[code]!['members']);
      members.remove(targetId);
      _rooms[code]!['members'] = members;
      state.updateRoomMembers(members.map((id) =>
        {'id': id, 'name': id}).toList());
    }
    return _json({'ok': true});
  }

  Future<Response> _roomSseHandler(Request req) async {
    // Same as regular SSE but for room events
    // Reuse regular SSE for simplicity — room events use same channel
    return _sseHandler(req);
  }

  // ── MULTIPART PARSER ──────────────────────────────────

  String? _extractBoundary(String contentType) {
    final match = RegExp(r'boundary=([^\s;]+)').firstMatch(contentType);
    return match?.group(1);
  }

  List<Map<String, dynamic>> _parseMultipart(Uint8List data, String boundary) {
    final parts     = <Map<String, dynamic>>[];
    final delimiter = utf8.encode('--$boundary');
    final end       = utf8.encode('--$boundary--');

    int pos = 0;
    while (pos < data.length) {
      // Find delimiter
      final delimPos = _indexOf(data, delimiter, pos);
      if (delimPos == -1) break;

      pos = delimPos + delimiter.length;
      if (pos >= data.length) break;

      // Skip CRLF after delimiter
      if (data[pos] == 13) pos++;
      if (pos < data.length && data[pos] == 10) pos++;

      // Check if end delimiter
      if (_startsWith(data, end, delimPos)) break;

      // Parse headers
      final headers = <String, String>{};
      while (pos < data.length) {
        final lineEnd = _indexOf(data, utf8.encode('\r\n'), pos);
        if (lineEnd == -1 || lineEnd == pos) { pos += 2; break; }
        final line = utf8.decode(data.sublist(pos, lineEnd));
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).toLowerCase().trim()] =
              line.substring(colon + 1).trim();
        }
        pos = lineEnd + 2;
      }

      // Find next delimiter for body end
      final nextDelim = _indexOf(data, delimiter, pos);
      final bodyEnd   = nextDelim == -1 ? data.length : nextDelim - 2;

      parts.add({
        'headers': headers,
        'data':    Uint8List.fromList(data.sublist(pos, bodyEnd)),
      });

      pos = nextDelim == -1 ? data.length : nextDelim;
    }

    return parts;
  }

  int _indexOf(Uint8List data, List<int> pattern, int start) {
    outer:
    for (int i = start; i <= data.length - pattern.length; i++) {
      for (int j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  bool _startsWith(Uint8List data, List<int> pattern, int start) {
    if (start + pattern.length > data.length) return false;
    for (int i = 0; i < pattern.length; i++) {
      if (data[start + i] != pattern[i]) return false;
    }
    return true;
  }

  // ── JSON RESPONSE HELPER ──────────────────────────────

  Response _json(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );
}