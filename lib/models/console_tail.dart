/// The retained tail of a stream that must not grow without limit.
///
/// The serial console used to keep every byte it ever received in one text
/// block, so the cost of each repaint grew with the session: a long boot log got
/// slower and slower. This buffers incoming chunks, merges them once per flush,
/// and keeps only the newest window — always cut on a line boundary so a torn
/// line is never shown.
class ConsoleTail {
  ConsoleTail({required this.maxBytes, required this.maxLines});

  /// Largest window kept, in UTF-16 code units. SerialService decodes with
  /// `String.fromCharCodes`, so one code unit is one received byte.
  final int maxBytes;

  /// Secondary guard: bounds the scroll extent and the selection geometry of
  /// the text block the window is rendered into.
  final int maxLines;

  final StringBuffer _pending = StringBuffer();
  String _retained = '';
  int _totalBytes = 0;
  int _droppedBytes = 0;

  /// Everything ever added, including what the window dropped.
  int get totalBytes => _totalBytes;

  /// How much of [_totalBytes] no longer fits in the window.
  int get droppedBytes => _droppedBytes;

  bool get hasPending => _pending.isNotEmpty;

  void add(String chunk) => _pending.write(chunk);

  /// Merges the buffered chunks into the window and returns it. One call costs
  /// one trim, however many chunks arrived since the last one.
  String flush() {
    final incoming = _pending.toString();
    _pending.clear();
    if (incoming.isEmpty) return _retained;
    _totalBytes += incoming.length;

    final text = _retained + incoming;
    var start = 0;
    if (text.length > maxBytes) {
      start = text.length - maxBytes;
      final boundary = text.indexOf('\n', start);
      // Snap past the next newline. If the surplus is one unterminated line
      // there is no boundary, and the raw tail is kept rather than losing
      // everything.
      if (boundary >= 0) start = boundary + 1;
    }
    var kept = start == 0 ? text : text.substring(start);

    final lines = kept.split('\n');
    if (lines.length > maxLines) {
      kept = lines.sublist(lines.length - maxLines).join('\n');
    }

    _droppedBytes += text.length - kept.length;
    _retained = kept;
    return kept;
  }

  void clear() {
    _pending.clear();
    _retained = '';
    _totalBytes = 0;
    _droppedBytes = 0;
  }
}
