import 'package:path/path.dart' as p;

String formatBytes(dynamic bytes) {
  final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
  if (b < 1024) return '${b}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
}

String getFileIcon(String filename) {
  final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
  if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return '🖼️';
  if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) return '🎬';
  if (['mp3', 'wav', 'aac', 'flac', 'm4a'].contains(ext)) return '🎵';
  if (['pdf'].contains(ext)) return '📄';
  if (['zip', 'rar', '7z', 'tar'].contains(ext)) return '🗜️';
  if (['doc', 'docx'].contains(ext)) return '📝';
  if (['apk'].contains(ext)) return '📦';
  return '📁';
}
