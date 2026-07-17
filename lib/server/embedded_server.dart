import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/transfer_item.dart';

// ── SSE client ────────────────────────────────────────
class _SseClient {
  final StreamController<List<int>> _ctrl;
  _SseClient(this._ctrl);
  void send(String event, Object data) {
    if (_ctrl.isClosed) return;
    try {
      _ctrl.add(utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n'));
    } catch (_) {}
  }
}

class EmbeddedServer {
  final AppState state;
  final int port;

  HttpServer? _server;
  final Map<String, List<_SseClient>> _sseClients = {};
  final Map<String, Map<String, dynamic>> _activeTransfers = {};
  final Map<String, Map<String, dynamic>> _rooms = {};

  // ── HISTORY ──────────────────────────────────────────
  List<Map<String, dynamic>> _history = [];
  static const String _historyKey = 'xorbit_history';

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _history = list.map((e) => Map<String, dynamic>.from(e)).toList();
        debugPrint('Loaded ${_history.length} history entries');
      }
    } catch (e) {
      debugPrint('History load error: $e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyKey, jsonEncode(_history));
    } catch (e) {
      debugPrint('History save error: $e');
    }
  }

  EmbeddedServer({required this.state, this.port = 3000});

  // ── START / STOP ──────────────────────────────────────

  Future<void> start() async {
    final router = Router();

    router.get('/',                _health);
    router.get('/info',            _info);
    router.get('/events',          _sseHandler);
    router.post('/connect-request',_connectRequest);
    router.post('/accept',         _accept);
    router.post('/decline',        _decline);
    router.post('/notify-declined',_notifyDeclined);
    router.post('/disconnect',     _disconnect);
    router.post('/chunk',          _chunkHandler);
    router.post('/transfer/cancel',_cancelTransfer);
    router.post('/clipboard',      _clipboardHandler);
    router.get('/incoming',        _incoming);
    router.get('/history',         _historyHandler);
    router.delete('/history',         _clearHistory);
    router.delete('/history/<id>', _deleteHistoryEntry);
    router.post('/room/create',    _roomCreate);
    router.post('/room/join',      _roomJoin);
    router.get('/room/<code>',     _roomGet);
    router.post('/room/leave',     _roomLeave);
    router.post('/room/kick',      _roomKick);

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addHandler(router.call);

    await _loadHistory();
    _server = await io.serve(handler, '0.0.0.0', port);
    debugPrint('Xorbit server running on port $port');
  }

  Future<void> stop() async => _server?.close(force: true);

  // ── CORS ─────────────────────────────────────────────

  Middleware _corsMiddleware() => (Handler inner) => (Request req) async {
    if (req.method == 'OPTIONS') return Response.ok('', headers: _cors);
    final res = await inner(req);
    return res.change(headers: _cors);
  };

  Map<String, String> get _cors => {
    'Access-Control-Allow-Origin':  '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  // ── SSE ───────────────────────────────────────────────

  void _pushSSE(String deviceId, String event, Object data) {
    for (final c in List.of(_sseClients[deviceId] ?? [])) {
      c.send(event, data);
    }
  }

  Future<Response> _sseHandler(Request req) async {
    final deviceId = req.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) return Response.badRequest(body: 'Missing deviceId');

    final ctrl = StreamController<List<int>>();
    final client = _SseClient(ctrl);

    final keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!ctrl.isClosed) ctrl.add(utf8.encode(': ping\n\n'));
    });

    _sseClients.putIfAbsent(deviceId, () => []).add(client);

    ctrl.onCancel = () {
      keepAlive.cancel();
      _sseClients[deviceId]?.remove(client);
    };

    return Response.ok(
      ctrl.stream,
      headers: {
        'Content-Type':                'text/event-stream',
        'Cache-Control':               'no-cache',
        'Connection':                  'keep-alive',
        'Access-Control-Allow-Origin': '*',
        'X-Accel-Buffering':           'no',
      },
    );
  }

  // ── SAVE FOLDER ───────────────────────────────────────
  // Saves to Xorbit/<Category> — visible in file manager same as Xender

  Future<String> _saveFolder(String category) async {
    String base;

    if (Platform.isAndroid) {
      // /storage/emulated/0 = main internal storage, visible in file manager
      const primary = '/storage/emulated/0';
      if (Directory(primary).existsSync()) {
        base = primary;
      } else {
        try {
          final ext = await getExternalStorageDirectory();
          if (ext != null) {
            final parts = ext.path.split('/');
            final idx   = parts.indexOf('Android');
            base = idx > 0 ? parts.sublist(0, idx).join('/') : primary;
          } else {
            base = primary;
          }
        } catch (_) { base = primary; }
      }
    } else if (Platform.isIOS) {
      // iOS: app documents — user can access via Files app
      final docs = await getApplicationDocumentsDirectory();
      base = docs.path;
    } else {
      // Windows/Mac/Linux: ~/Xorbit/
      base = Platform.environment['USERPROFILE'] ??
             Platform.environment['HOME'] ?? '';
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
      final docs = await getApplicationDocumentsDirectory();
      final fb = Directory(p.join(docs.path, 'Xorbit', category));
      if (!fb.existsSync()) fb.createSync(recursive: true);
      return fb.path;
    }
  }

  String _categoryFor(String filename) {
    final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
    if (['mp4','mov','avi','mkv','webm','flv'].contains(ext))              return 'Videos';
    if (['jpg','jpeg','png','gif','webp','heic','bmp'].contains(ext))      return 'Pictures';
    if (['pdf','doc','docx','xls','xlsx','ppt','pptx','txt','csv'].contains(ext)) return 'Documents';
    if (['mp3','wav','aac','flac','ogg','m4a'].contains(ext))              return 'Music';
    return 'Other';
  }

  // Android only — notify MediaStore so file appears in Gallery/VLC etc
  void _notifyMediaStore(String filePath) {
    if (!Platform.isAndroid) return; // iOS/Windows don't need this
    try {
      const channel = MethodChannel('com.williams.xorbit/media_scanner');
      channel.invokeMethod('scanFile', {'path': filePath});
    } catch (e) {
      debugPrint('MediaStore notify: $e');
    }
  }

  // ── BASIC HANDLERS ────────────────────────────────────

  Future<Response> _health(Request req) =>
      Future.value(Response.ok(
        jsonEncode({'status': 'online', 'id': state.myId}),
        headers: {'content-type': 'application/json'}));

  Future<Response> _info(Request req) =>
      Future.value(Response.ok(
        jsonEncode({'id': state.myId, 'name': state.myName}),
        headers: {'content-type': 'application/json'}));

  Future<Response> _connectRequest(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final fromId   = body['fromId']   as String? ?? '';
    final fromName = body['fromName'] as String? ?? 'Unknown';
    final fromIp   = body['fromIp']   as String? ?? '';
    final fromPort = body['fromPort'] as int?    ?? 3000;

    state.pendingRequests[state.myId] = fromId;
    state.pendingFromIp   = fromIp;
    state.pendingFromPort = fromPort;
    state.pendingFromName = fromName;
    state.notifyListeners();

    return _json({'message': 'request sent'});
  }

  Future<Response> _accept(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final peerId   = body['peerId']   as String? ?? '';
    final peerName = body['peerName'] as String? ?? '';
    final peerIp   = body['peerIp']   as String? ?? '';
    final peerPort = body['peerPort'] as int?    ?? 3000;

    if (peerId.isNotEmpty) {
      state.connect(XorbitDevice(
        id: peerId, name: peerName, ip: peerIp, port: peerPort));
      state.acceptedByName = peerName;
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
          debugPrint('Notify declined error: $e');
        }
      });
    }
    return _json({'message': 'declined'});
  }

  Future<Response> _notifyDeclined(Request req) async {
    final body   = jsonDecode(await req.readAsString()) as Map;
    final byName = body['byName'] as String? ?? 'Unknown';
    state.declinedByName = byName;
    state.notifyListeners();
    return _json({'ok': true});
  }

  Future<Response> _disconnect(Request req) async {
    state.disconnect();
    return _json({'message': 'disconnected'});
  }

  // ── CHUNK HANDLER ─────────────────────────────────────

  Future<Response> _chunkHandler(Request req) async {
    final contentType = req.headers['content-type'] ?? '';
    final boundary    = _extractBoundary(contentType);
    if (boundary == null) return Response.badRequest(body: 'No boundary');

    final bodyBytes = <int>[];
    await for (final chunk in req.read()) {
      bodyBytes.addAll(chunk);
    }
    final bodyData = Uint8List.fromList(bodyBytes);

    final fields    = <String, String>{};
    Uint8List? chunkBytes;

    for (final part in _parseMultipart(bodyData, boundary)) {
      final disp = (part['headers'] as Map)['content-disposition'] ?? '';
      final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(disp);
      final fname     = RegExp(r'filename="([^"]+)"').firstMatch(disp);
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

    debugPrint('Chunk fields: transferId=$transferId idx=$chunkIndex/$totalChunks '
      'size=$totalSize filename=$filename chunkBytes=${chunkBytes?.length ?? "NULL"}');

    if (transferId.isEmpty) {
      return Response.badRequest(body: 'Missing transferId');
    }
    if (chunkBytes == null || chunkBytes!.isEmpty) {
      return Response.badRequest(body: 'Missing file data in chunk');
    }

    if (chunkIndex == 0) {
      final category = _categoryFor(filename);
      final folder   = await _saveFolder(category);

      // Keep original filename — add (1),(2) etc if exists
      final base     = p.basenameWithoutExtension(filename);
      final ext      = p.extension(filename);
      String safeName = filename;
      int counter = 1;
      while (File(p.join(folder, safeName)).existsSync()) {
        safeName = '$base ($counter)$ext';
        counter++;
      }

      final finalPath = p.join(folder, safeName);
      final sink      = File(finalPath).openWrite();

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

      // Add receiving item to state so UI shows progress
      final item = TransferItem.receiving(
        transferId: transferId,
        filename:   filename,
        totalSize:  totalSize,
      );
      state.addTransfer(item);
    }

    final transfer = _activeTransfers[transferId];
    if (transfer == null) return Response.badRequest(body: 'Unknown transfer');

    final sink = transfer['sink'] as IOSink;
    sink.add(chunkBytes);
    transfer['received'] = (transfer['received'] as int) + chunkBytes.length;

    final progress = (transfer['received'] as int) / totalSize;
    state.updateTransfer(transferId, progress: progress);

    if (chunkIndex == totalChunks - 1) {
      await sink.flush();
      await sink.close();

      final fileRecord = {
        'name':     transfer['filename'],
        'original': transfer['original'],
        'size':     transfer['totalSize'],
        'category': transfer['category'],
        'savedTo':  transfer['finalPath'],
      };

      state.updateTransfer(transferId,
        status:    TransferStatus.done,
        progress:  1.0,
        savedPath: transfer['finalPath'] as String,
      );

      // Notify Android MediaStore — makes file visible in Gallery/VLC
      _notifyMediaStore(transfer['finalPath'] as String);

      state.pendingFiles.add(fileRecord);
      state.notifyListeners();

      _history.insert(0, {
        'id':        '${DateTime.now().millisecondsSinceEpoch}',
        'from':      fromId,
        'fromName':  fromName,
        'to':        state.myId,
        'toName':    state.myName,
        'files':     [fileRecord],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _saveHistory();

      _activeTransfers.remove(transferId);
    }

    return _json({'ok': true, 'received': transfer['received']});
  }

  Future<Response> _cancelTransfer(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map;
    final tid  = body['transferId'] as String? ?? '';
    final t    = _activeTransfers[tid];
    if (t != null) {
      try { await (t['sink'] as IOSink).close(); } catch (_) {}
      try { File(t['finalPath'] as String).deleteSync(); } catch (_) {}
      _activeTransfers.remove(tid);
      state.updateTransfer(tid, status: TransferStatus.cancelled);
    }
    return _json({'ok': true});
  }

  Future<Response> _clipboardHandler(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map;
    final text = body['text'] as String? ?? '';
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
    return _json({'history': _history});
  }

  Future<Response> _clearHistory(Request req) async {
    _history.clear();
    await _saveHistory();
    state.notifyListeners();
    return _json({'ok': true});
  }

  Future<Response> _deleteHistoryEntry(Request req, String id) async {
    _history.removeWhere((e) =>
      e['id']?.toString() == id || e['transferId']?.toString() == id);
    await _saveHistory();
    return _json({'ok': true});
  }

  // ── ROOMS ─────────────────────────────────────────────

  Future<Response> _roomCreate(Request req) async {
    final body     = jsonDecode(await req.readAsString()) as Map;
    final roomName = body['roomName'] as String? ?? "${state.myName}'s Room";
    final code     = _generateRoomCode();
    _rooms[code]   = {
      'code': code, 'name': roomName,
      'creatorId': state.myId,
      'members': [state.myId],
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    state.joinedRoom(
      code: code, name: roomName, creatorId: state.myId,
      members: [{'id': state.myId, 'name': state.myName}]);
    return _json({'code': code, 'room': _rooms[code]});
  }

  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    for (int i = 0; i < 6; i++) buf.write(chars[(rng + i * 7) % chars.length]);
    final code = buf.toString();
    return _rooms.containsKey(code) ? _generateRoomCode() : code;
  }

  Future<Response> _roomJoin(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map;
    final code = (body['code'] as String? ?? '').toUpperCase();
    final room = _rooms[code];
    if (room == null) return Response.notFound(jsonEncode({'error': 'Room not found'}));
    final members = List<String>.from(room['members']);
    if (members.length >= 20) return Response.forbidden(jsonEncode({'error': 'Room is full'}));
    if (!members.contains(state.myId)) { members.add(state.myId); room['members'] = members; }
    state.joinedRoom(
      code: code, name: room['name'], creatorId: room['creatorId'],
      members: members.map((id) => {'id': id, 'name': id == state.myId ? state.myName : id}).toList());
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
      if (members.isEmpty) { _rooms.remove(code); }
      else { _rooms[code]!['members'] = members; }
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
      state.updateRoomMembers(members.map((id) => {'id': id, 'name': id}).toList());
    }
    return _json({'ok': true});
  }

  // ── MULTIPART PARSER ──────────────────────────────────

  String? _extractBoundary(String ct) {
    final m = RegExp(r'boundary="?([^";\s]+)"?').firstMatch(ct);
    return m?.group(1);
  }

  List<Map<String, dynamic>> _parseMultipart(Uint8List data, String boundary) {
    final parts = <Map<String, dynamic>>[];
    final delim = utf8.encode('--$boundary');
    final end   = utf8.encode('--$boundary--');
    int pos = 0;

    while (pos < data.length) {
      final dp = _indexOf(data, delim, pos);
      if (dp == -1) break;
      pos = dp + delim.length;
      if (pos >= data.length) break;
      if (data[pos] == 13) pos++;
      if (pos < data.length && data[pos] == 10) pos++;
      if (_startsWith(data, end, dp)) break;

      final headers = <String, String>{};
      while (pos < data.length) {
        final le = _indexOf(data, utf8.encode('\r\n'), pos);
        if (le == -1 || le == pos) { pos += 2; break; }
        final line  = utf8.decode(data.sublist(pos, le));
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).toLowerCase().trim()] =
              line.substring(colon + 1).trim();
        }
        pos = le + 2;
      }

      final nd  = _indexOf(data, delim, pos);
      final end2 = nd == -1 ? data.length : nd - 2;
      parts.add({'headers': headers, 'data': Uint8List.fromList(data.sublist(pos, end2))});
      pos = nd == -1 ? data.length : nd;
    }
    return parts;
  }

  int _indexOf(Uint8List data, List<int> pat, int start) {
    outer:
    for (int i = start; i <= data.length - pat.length; i++) {
      for (int j = 0; j < pat.length; j++) {
        if (data[i + j] != pat[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  bool _startsWith(Uint8List data, List<int> pat, int start) {
    if (start + pat.length > data.length) return false;
    for (int i = 0; i < pat.length; i++) {
      if (data[start + i] != pat[i]) return false;
    }
    return true;
  }

  Response _json(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'});
}