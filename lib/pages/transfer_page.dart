import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/models/transfer_item.dart';
import 'package:xorbit/widgets/reusable/transfer_item_card.dart';

class _SharedFile {
  final String path;
  final String name;
  final int size;
  Stream<List<int>>? get readStream => File(path).openRead();
  _SharedFile({required this.path, required this.name, required this.size});
}

class TransferPage extends StatefulWidget {
  final String targetName;
  final List<String> sharedPaths; // files shared from other apps
  const TransferPage({
    super.key,
    required this.targetName,
    this.sharedPaths = const [],
  });

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  bool _isRunning = false;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    if (widget.sharedPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _queueSharedPaths(widget.sharedPaths);
      });
    }
  }

  // Call this before _runQueue()
  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'xorbit_transfer',
        channelName: 'Xorbit Transfer',
        channelDescription: 'Keeps file transfers running in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
      ),
    );

    await FlutterForegroundTask.startService(
      notificationTitle: 'Xorbit',
      notificationText: 'Transfer in progress...',
    );
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
  }

  Future<void> _queueSharedPaths(List<String> paths) async {
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final name = p.basename(path);
      final size = file.lengthSync();
      // Create a minimal PlatformFile-compatible wrapper
      final pf = _SharedFile(path: path, name: name, size: size);
      final item =
          TransferItem.sending(transferId: const Uuid().v4(), file: pf);
      appState.addTransfer(item);
    }
    _runQueue();
  }

  List<TransferItem> get _filtered {
    switch (_filter) {
      case 'sending':
        return appState.transfers
            .where((t) => t.direction == TransferDirection.sending)
            .toList();
      case 'receiving':
        return appState.transfers
            .where((t) => t.direction == TransferDirection.receiving)
            .toList();
      default:
        return appState.transfers;
    }
  }

  // ── FILE PICK ──────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      withReadStream: true,
    );
    if (result == null) return;

    final valid = result.files
        .where((f) => f.path != null || f.readStream != null)
        .toList();
    if (valid.isEmpty) return;

    for (final f in valid) {
      final item = TransferItem.sending(transferId: const Uuid().v4(), file: f);
      appState.addTransfer(item);
    }

    await _startForegroundService();
    // Always call _runQueue — it checks _isRunning internally
    // so duplicate calls are safe. This ensures newly added items
    // start immediately even if the queue was idle.
    _runQueue();
  }

  Future<void> _runQueue() async {
    // If already running, the while loop below will naturally pick up
    // any newly added items — no need to start a second loop.
    if (_isRunning) return;
    _isRunning = true;

    try {
      while (true) {
        // Always re-query the list — items may have been added since last loop
        final next = appState.transfers
            .where(
              (t) =>
                  t.direction == TransferDirection.sending &&
                  t.status == TransferStatus.waiting,
            )
            .firstOrNull;

        if (next == null) {
          // No waiting items — wait a bit longer before giving up.
          // This handles the case where addTransfer() was called
          // in the same async frame and hasn't propagated yet.
          await Future.delayed(const Duration(milliseconds: 300));
          final recheck = appState.transfers
              .where(
                (t) =>
                    t.direction == TransferDirection.sending &&
                    t.status == TransferStatus.waiting,
              )
              .firstOrNull;
          if (recheck == null) break; // truly nothing left
          await _uploadFile(recheck);
        } else {
          await _uploadFile(next);
        }

        // Brief pause between files — lets receiver flush previous write
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      _isRunning = false;
      await _stopForegroundService();
    }
  }

  // ── CHUNKED UPLOAD ─────────────────────────────────
  // Sends directly to the receiver's embedded server

  Future<void> _uploadFile(TransferItem item) async {
    // ← Dio created fresh here, local to this method
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: Duration.zero,
        sendTimeout: Duration.zero,
      ),
    );

    if (item.status == TransferStatus.cancelled) return;
    if (appState.peerBaseUrl == null) {
      appState.updateTransfer(item.transferId, status: TransferStatus.failed);
      return;
    }
    appState.updateTransfer(
      item.transferId,
      status: TransferStatus.transferring,
    );

    // Extract file properties safely from dynamic — works for both
    // PlatformFile (from file_picker) and _SharedFile (from share sheet)
    if (item.file == null) {
      appState.updateTransfer(item.transferId, status: TransferStatus.failed);
      return;
    }
    final dynamic fileObj = item.file;
    final int totalSize = fileObj.size as int;
    final String fileName = fileObj.name as String;
    final String? filePath = fileObj.path as String?;
    final totalChunks = (totalSize / kChunkSize).ceil();
    final hasPath = filePath != null;

    if (Platform.isAndroid) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Sending $fileName',
        notificationText:
            '${(item.currentChunk / totalChunks * 100).toStringAsFixed(0)}%',
      );
    }

    int sentBytes = item.currentChunk * kChunkSize;
    int lastSpeedBytes = sentBytes;
    int lastSpeedTime = DateTime.now().millisecondsSinceEpoch;

    RandomAccessFile? raf;

    if (hasPath) {
      // Path available — open file once, read chunks on demand (most efficient)
      try {
        raf = await File(filePath).open();
      } catch (e) {
        debugPrint('Cannot open file: $e');
        appState.updateTransfer(item.transferId, status: TransferStatus.failed);
        return;
      }
    } else {
      // No path (Android content URI) — copy to temp file first so we can
      // seek through it chunk by chunk without loading it all into RAM.
      try {
        final stream = fileObj.readStream as Stream<List<int>>?;
        if (stream == null) {
          appState.updateTransfer(
            item.transferId,
            status: TransferStatus.failed,
          );
          return;
        }
        // Write stream to temp file
        final tmpDir = Directory.systemTemp;
        final tmpFile = File('${tmpDir.path}/xorbit_tmp_${item.transferId}');
        final sink = tmpFile.openWrite();
        await for (final chunk in stream) {
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        // Now open as RandomAccessFile for chunk reading
        raf = await tmpFile.open();
        // Clean up temp file after transfer (handled in finally block)
        item.tempPath = tmpFile.path;
      } catch (e) {
        debugPrint('Stream copy error: $e');
        appState.updateTransfer(item.transferId, status: TransferStatus.failed);
        return;
      }
    }

    try {
      for (int i = item.currentChunk; i < totalChunks; i++) {
        if (item.status == TransferStatus.cancelled) return;

        Uint8List chunkBytes;
        if (hasPath) {
          final len = ((i + 1) * kChunkSize > totalSize)
              ? totalSize - (i * kChunkSize)
              : kChunkSize;
          await raf.setPosition(i * kChunkSize);
          chunkBytes = await raf.read(len);
        } else {
          // RAF is open from the temp file copy — read chunk from it
          final len = ((i + 1) * kChunkSize > totalSize)
              ? totalSize - (i * kChunkSize)
              : kChunkSize;
          await raf.setPosition(i * kChunkSize);
          chunkBytes = await raf.read(len);
        }

        if (item.status == TransferStatus.cancelled) return;

        try {
          final formData = FormData.fromMap({
            'transferId': item.transferId,
            'chunkIndex': i.toString(),
            'totalChunks': totalChunks.toString(),
            'totalSize': totalSize.toString(),
            'filename': fileName,
            'fromId': appState.myId,
            'fromName': appState.myName,
            'file': MultipartFile.fromBytes(chunkBytes, filename: fileName),
          });

          await dio.post('${appState.peerBaseUrl}/chunk', data: formData);

          sentBytes += chunkBytes.length;
          item.currentChunk = i + 1;

          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastSpeedTime >= 500) {
            final elapsed = (now - lastSpeedTime) / 1000;
            final bps = (sentBytes - lastSpeedBytes) / elapsed;
            lastSpeedBytes = sentBytes;
            lastSpeedTime = now;

            // ETA calculation
            final remaining = totalSize - sentBytes;
            final etaSecs = bps > 0 ? (remaining / bps).round() : 0;
            String eta = '';
            if (etaSecs > 0) {
              if (etaSecs < 60) {
                eta = '${etaSecs}s left';
              } else if (etaSecs < 3600) {
                eta = '${(etaSecs ~/ 60)}m ${etaSecs % 60}s left';
              } else {
                eta = '${(etaSecs ~/ 3600)}h ${(etaSecs % 3600) ~/ 60}m left';
              }
            }

            final speedFmt = _fmtSize(bps.toInt());
            appState.updateTransfer(
              item.transferId,
              speed: '$speedFmt/s',
              eta: eta,
            );
          }

          appState.updateTransfer(
            item.transferId,
            progress: item.currentChunk / totalChunks,
            currentChunk: item.currentChunk,
          );
        } on DioException catch (e) {
          debugPrint('Chunk $i failed: ${e.message} — retrying in 2s');
          await Future.delayed(const Duration(seconds: 2));
          if (item.status == TransferStatus.cancelled) return;
          // Rebuild FormData — cannot reuse after Dio consumes it
          try {
            final retryData = FormData.fromMap({
              'transferId': item.transferId,
              'chunkIndex': i.toString(),
              'totalChunks': totalChunks.toString(),
              'totalSize': totalSize.toString(),
              'filename': fileName,
              'fromId': appState.myId,
              'fromName': appState.myName,
              'file': MultipartFile.fromBytes(chunkBytes, filename: fileName),
            });
            await dio.post('${appState.peerBaseUrl}/chunk', data: retryData);
            sentBytes += chunkBytes.length;
            item.currentChunk = i + 1;
            appState.updateTransfer(
              item.transferId,
              progress: item.currentChunk / totalChunks,
              currentChunk: item.currentChunk,
            );
          } catch (e2) {
            debugPrint('Chunk $i retry failed: $e2');
            if (item.status != TransferStatus.cancelled) {
              appState.updateTransfer(
                item.transferId,
                status: TransferStatus.failed,
              );
            }
            return;
          }
        }
      }
    } finally {
      dio.close(force: true); // safe — only closes this file's client
      final activeRaf = raf;
      if (activeRaf != null) {
        await activeRaf.close();
      }
      if (item.tempPath != null) {
        try {
          File(item.tempPath!).deleteSync();
        } catch (_) {}
        item.tempPath = null;
      }
    }

    if (item.status != TransferStatus.cancelled) {
      appState.updateTransfer(
        item.transferId,
        status: TransferStatus.done,
        progress: 1.0,
        speed: '',
      );
    }
  }

  Future<void> _cancel(TransferItem item) async {
    appState.updateTransfer(item.transferId, status: TransferStatus.cancelled);
    try {
      await Dio().post(
        '${appState.peerBaseUrl}/transfer/cancel',
        data: {'transferId': item.transferId},
      );
    } catch (_) {}
  }

  Future<void> _retry(TransferItem item) async {
    appState.updateTransfer(
      item.transferId,
      status: TransferStatus.waiting,
      currentChunk: 0,
      progress: 0,
      speed: '',
      eta: '',
    );
    _runQueue(); // _runQueue checks _isRunning internally
  }

  String _fmtSize(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _filtered;

    return AnimatedBuilder(
      animation: appState,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text('Transfer · ${widget.targetName}'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _filter,
                  icon: const Icon(Icons.filter_list_rounded, size: 20),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'sending', child: Text('Sending')),
                    DropdownMenuItem(
                      value: 'receiving',
                      child: Text('Receiving'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _filter = v ?? 'all'),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.swap_horiz_rounded,
                            size: 64,
                            color: scheme.onSurface.withOpacity(0.15),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No transfers yet',
                            style: TextStyle(
                              color: scheme.onSurface.withOpacity(0.3),
                            ),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: _pickFiles,
                            icon: const Icon(Icons.add),
                            label: const Text('Add Files'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        return TransferItemCard(
                          item: item,
                          onCancel: () => _cancel(item),
                          onRetry: () => _retry(item),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: ElevatedButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Files'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
