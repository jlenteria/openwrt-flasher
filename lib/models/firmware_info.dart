enum FirmwareStatus {
  /// The image names this router's board/compatible identifiers.
  matched,

  /// The image carries device metadata that does not name this router.
  mismatched,

  /// The image carries no device metadata at all, so it cannot be checked.
  unverifiable,

  /// Not a flashable sysupgrade image.
  invalid,
}

class FirmwareInfo {
  const FirmwareInfo({
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.version,
    required this.status,
    this.model = '',
    this.sha256 = '',
    this.supportedDevices = const [],
    this.detail = '',
  });

  final String fileName;
  final String filePath;
  final int fileSize;
  final String version;
  final FirmwareStatus status;
  final String model;

  /// Hash of the local file, computed in a background isolate.
  final String sha256;

  /// Device identifiers found inside the image.
  final List<String> supportedDevices;

  /// Human-readable explanation, always shown next to [status].
  final String detail;

  bool get isValid => status != FirmwareStatus.invalid;
  bool get isConfirmedForDevice => status == FirmwareStatus.matched;
  bool get needsAcknowledgement => status == FirmwareStatus.unverifiable;

  String get sizeLabel {
    const kb = 1024;
    if (fileSize < kb) return '$fileSize B';
    if (fileSize < kb * kb) return '${(fileSize / kb).toStringAsFixed(0)} KB';
    return '${(fileSize / kb / kb).toStringAsFixed(1)} MB';
  }
}
