import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:xorbit/models/app_state.dart';
import 'package:xorbit/widgets/reusable/history_item_card.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final Dio dio = Dio();
  List<dynamic> history = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => loading = true);
    try {
      final res = await dio.get('http://127.0.0.1:$kServerPort/history');
      setState(() {
        history = List<dynamic>.from(res.data['history'] ?? []);
        loading = false;
      });
    } catch (_) {
      setState(() => loading = false);
    }
  }

  String _fmtTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfer History'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch),
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded),
            tooltip: 'Clear history',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Clear History'),
                  content: const Text(
                    'This removes all transfer history from this device. '
                    'Files already saved are not affected.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await dio.delete('http://127.0.0.1:${appState.myPort}/history');
                _fetch();
              }
            },
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : history.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history,
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
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final entry = history[i];
                    final isSent = entry['from'] == appState.myId;
                    final ts = entry['timestamp'] as int;

                    return HistoryItemCard(
                      entry: entry,
                      isSent: isSent,
                      timeLabel: _fmtTime(ts),
                      onDelete: () async {
                        final id = entry['id']?.toString() ??
                            entry['transferId']?.toString() ??
                            '';
                        if (id.isNotEmpty) {
                          await dio.delete(
                            'http://127.0.0.1:${appState.myPort}/history/$id',
                          );
                          _fetch();
                        }
                      },
                    );
                  },
                ),
    );
  }
}
