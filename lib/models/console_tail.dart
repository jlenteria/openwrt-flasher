import 'terminal_screen.dart';

/// The retained tail of a stream that must not grow without limit.
///
/// The serial console used to keep every byte it ever received in one text
/// block, so the cost of each repaint grew with the session: a long boot log got
/// slower and slower. This buffers incoming chunks, merges them once per flush,
/// and keeps only the newest window — always cut on a line boundary so a torn
/// line is never shown.
///
/// Incoming text goes through a [TerminalScreen], so terminal control
/// sequences (the bootloader menu's cursor moves and highlights) are applied
/// instead of printed.
class ConsoleTail {
  ConsoleTail({required this.maxBytes, required this.maxLines});

  /// Largest window kept, in rendered characters. SerialService decodes with
  /// `String.fromCharCodes`, so one character is one received byte.
  final int maxBytes;

  /// Secondary guard: bounds the scroll extent and the selection geometry of
  /// the text block the window is rendered into.
  final int maxLines;

  final StringBuffer _pending = StringBuffer();
  final TerminalScreen _screen = TerminalScreen();
  String _retained = '';
  List<HighlightRange> _highlights = const [];
  int _totalBytes = 0;
  int _droppedBytes = 0;

  /// Everything ever added, including what the window dropped.
  int get totalBytes => _totalBytes;

  /// How much of the rendered output no longer fits in the window.
  int get droppedBytes => _droppedBytes;

  /// Ranges of the last flushed window drawn in reverse video, such as the
  /// selected bootloader menu entry.
  List<HighlightRange> get highlights => _highlights;

  bool get hasPending => _pending.isNotEmpty;

  void add(String chunk) => _pending.write(chunk);

  /// Merges the buffered chunks into the window and returns it. One call costs
  /// one trim, however many chunks arrived since the last one.
  String flush() {
    final incoming = _pending.toString();
    _pending.clear();
    if (incoming.isEmpty) return _retained;
    _totalBytes += incoming.length;

    _screen.write(incoming);
    _droppedBytes += _screen.trim(maxChars: maxBytes, maxLines: maxLines);
    final view = _screen.render();
    _retained = view.text;
    _highlights = view.highlights;
    return _retained;
  }

  void clear() {
    _pending.clear();
    _screen.clear();
    _retained = '';
    _highlights = const [];
    _totalBytes = 0;
    _droppedBytes = 0;
  }
}
