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
  final dynamic file;
  String? tempPath;
  String? savedPath; // ← where received file was saved on disk

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
  })  : file         = null,
        status       = TransferStatus.transferring,
        direction    = TransferDirection.receiving,
        progress     = 0,
        speed        = '',
        eta          = '',
        currentChunk = 0;
}