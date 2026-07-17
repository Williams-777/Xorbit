import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:xorbit/models/transfer_item.dart';
import 'package:xorbit/utils/helpers.dart';

class TransferItemCard extends StatelessWidget {
  final TransferItem item;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  const TransferItemCard({
    super.key,
    required this.item,
    required this.onCancel,
    required this.onRetry,
  });

  Color _statusColor(TransferStatus s) {
    switch (s) {
      case TransferStatus.done:
        return Colors.green;
      case TransferStatus.failed:
        return Colors.red;
      case TransferStatus.cancelled:
        return Colors.grey;
      case TransferStatus.transferring:
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(TransferItem item) {
    if (item.direction == TransferDirection.receiving) {
      return item.status == TransferStatus.done ? 'Received' : 'Receiving';
    }
    switch (item.status) {
      case TransferStatus.waiting:
        return 'Waiting';
      case TransferStatus.transferring:
        return 'Sending';
      case TransferStatus.done:
        return 'Sent';
      case TransferStatus.cancelled:
        return 'Cancelled';
      case TransferStatus.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSending = item.direction == TransferDirection.sending;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
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
                Text(
                  getFileIcon(item.filename),
                  style: const TextStyle(fontSize: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.filename,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        formatBytes(item.totalSize),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(item.status).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSending
                            ? Icons.upload_rounded
                            : Icons.download_rounded,
                        size: 11,
                        color: _statusColor(item.status),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        _statusLabel(item),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _statusColor(item.status),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.status == TransferStatus.transferring ||
                item.status == TransferStatus.done) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: item.progress,
                  minHeight: 6,
                  backgroundColor: scheme.onSurface.withOpacity(0.08),
                  color: _statusColor(item.status),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '${(item.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  const Spacer(),
                  if (item.eta.isNotEmpty) ...[
                    Text(
                      item.eta,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.primary.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '·',
                      style: TextStyle(
                        color: scheme.onSurface.withOpacity(0.3),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (item.speed.isNotEmpty)
                    Text(
                      item.speed,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.4),
                      ),
                    ),
                ],
              ),
            ],
            // Controls row
            Row(
              children: [
                // Retry for failed sends
                if (isSending && item.status == TransferStatus.failed)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text(
                      'Retry',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                // Open file location when done
                if (item.status == TransferStatus.done)
                  TextButton.icon(
                    onPressed: () async {
                      final path =
                          item.direction == TransferDirection.receiving
                              ? item.savedPath
                              : item.file?.path as String?;
                      if (path != null) {
                        final result = await OpenFilex.open(path);
                        if (result.type != ResultType.done &&
                            context.mounted) {
                          await OpenFilex.open(p.dirname(path));
                        }
                      }
                    },
                    icon: Icon(
                      Icons.folder_open_rounded,
                      size: 14,
                      color: scheme.primary,
                    ),
                    label: Text(
                      'Open location',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                const Spacer(),
                // Cancel for active/waiting sends
                if (item.status != TransferStatus.done &&
                    item.status != TransferStatus.cancelled &&
                    item.status != TransferStatus.failed)
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.red,
                    ),
                    label: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
