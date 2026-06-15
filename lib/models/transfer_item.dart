enum TransferStatus { waiting, transferring, done, cancelled, failed }
enum TransferDirection { sending, receiving }

class TransferItem {
  final String transferId;
  final String filename;
  final int totalSize;
  TransferStatus status;
  TransferDirection direction;
  double progress;
  String speed;
  String eta;
  int currentChunk;

  // Only non-null for sending items
  final dynamic file; // PlatformFile

  // Temp file path used when file was uploaded via stream (no direct path)
  String? tempPath;

  TransferItem.sending({
    required this.transferId,
    required this.file,
  })  : filename     = file.name,
        totalSize    = file.size,
        status       = TransferStatus.waiting,
        direction    = TransferDirection.sending,
        progress     = 0,
        speed        = '',
        eta          = '',
        currentChunk = 0;

  TransferItem.receiving({
    required this.transferId,
    required this.filename,
    required this.totalSize,
  })  : file        = null,
        status      = TransferStatus.transferring,
        direction   = TransferDirection.receiving,
        progress    = 0,
        speed       = '',
        eta         = '',
        currentChunk = 0;
}