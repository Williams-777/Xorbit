import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:xorbit/utils/helpers.dart';

class HistoryItemCard extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool isSent;
  final String timeLabel;
  final VoidCallback onDelete;

  const HistoryItemCard({
    super.key,
    required this.entry,
    required this.isSent,
    required this.timeLabel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fromName = entry['fromName'] ?? 'Unknown';
    final toName = entry['toName'] ?? 'Unknown';
    final files = List<dynamic>.from(entry['files'] ?? []);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.onSurface.withOpacity(0.07)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isSent ? scheme.primary : Colors.green)
                      .withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isSent ? Icons.upload_rounded : Icons.download_rounded,
                      size: 12,
                      color: isSent ? scheme.primary : Colors.green,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      isSent ? 'SENT' : 'RECEIVED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isSent ? scheme.primary : Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                timeLabel,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.4),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Delete Entry'),
                      content: const Text(
                        'Remove this transfer from history? The file itself is not deleted.',
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
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    onDelete();
                  }
                },
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: scheme.onSurface.withOpacity(0.3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.devices,
                size: 13,
                color: scheme.onSurface.withOpacity(0.4),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                    children: [
                      TextSpan(
                        text: fromName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isSent ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                      TextSpan(
                        text: '  →  ',
                        style: TextStyle(
                          color: scheme.onSurface.withOpacity(0.3),
                        ),
                      ),
                      TextSpan(
                        text: toName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: !isSent ? Colors.green : scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: scheme.onSurface.withOpacity(0.07)),
          const SizedBox(height: 10),
          ...files.map((f) {
            final name = f['original'] ?? f['name'] ?? 'file';
            final size = f['size'] != null ? formatBytes(f['size']) : '';
            final savedTo = f['savedTo']?.toString() ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Text(getFileIcon(name), style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (savedTo.isNotEmpty)
                          Text(
                            savedTo,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: scheme.onSurface.withOpacity(0.4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (size.isNotEmpty)
                    Text(
                      size,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.4),
                      ),
                    ),
                  if (savedTo.isNotEmpty) ...[
                    IconButton(
                      icon: Icon(
                        Icons.open_in_new_rounded,
                        size: 16,
                        color: scheme.primary.withOpacity(0.7),
                      ),
                      tooltip: 'Open file',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () async {
                        final result = await OpenFilex.open(savedTo);
                        if (result.type != ResultType.done &&
                            context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Cannot open: ${result.message}'),
                            ),
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.folder_open_rounded,
                        size: 16,
                        color: scheme.onSurface.withOpacity(0.4),
                      ),
                      tooltip: 'Open folder',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () async {
                        final folder = p.dirname(savedTo);
                        final result = await OpenFilex.open(folder);
                        if (result.type != ResultType.done &&
                            context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Location: $folder'),
                              duration: const Duration(seconds: 5),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            );
          }),
          if (files.length > 1)
            Text(
              '${files.length} files',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withOpacity(0.3),
              ),
            ),
        ],
      ),
    );
  }
}
