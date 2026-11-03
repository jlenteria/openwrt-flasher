import 'dart:math' as math;

/// A highlighted range of the rendered text, `[start, end)` in code units.
typedef HighlightRange = (int start, int end);

/// The rendered console: plain text plus the ranges drawn in reverse video.
typedef TerminalView = ({String text, List<HighlightRange> highlights});

/// A minimal VT100/ANSI interpreter for the serial console.
///
/// Bootloader menus (U-Boot's bootmenu and the vendor recovery menus built on
/// it) draw with cursor addressing, line erases and reverse video instead of
/// plain lines. Printed verbatim those sequences show up as garbage such as
/// `[2J[1;1H`. This applies them to a line buffer, so the console shows what a
/// terminal would while ordinary log output still accumulates as history.
///
/// The visible screen is the last [rows] lines; cursor addressing is relative
/// to it. Clearing the screen keeps the old contents above as history instead
/// of erasing them, because a log console is read after the fact.
class TerminalScreen {
  TerminalScreen({this.rows = 24});

  /// Height of the emulated screen. A serial console has no size negotiation,
  /// so programs assume the VT100 default.
  final int rows;

  /// Lines are created when written to, so moving the cursor down without
  /// printing leaves no blank lines behind.
  final List<_Line> _lines = [_Line()];
  int _row = 0;
  int _col = 0;
  int _top = 0;
  bool _reverse = false;
  int _savedRow = 0;
  int _savedCol = 0;

  _State _state = _State.ground;
  final StringBuffer _params = StringBuffer();
  int _oscLength = 0;

  /// Unterminated sequences longer than these are treated as noise, so a stray
  /// ESC in garbled output cannot swallow the rest of the log.
  static const int _maxParamsLength = 32;
  static const int _maxOscLength = 512;

  /// Characters in the rendered text, newlines included.
  int get length {
    var total = _lines.length - 1;
    for (final line in _lines) {
      total += line.chars.length;
    }
    return total;
  }

  void write(String data) {
    for (var i = 0; i < data.length; i++) {
      _feed(data.codeUnitAt(i));
    }
  }

  void clear() {
    _lines
      ..clear()
      ..add(_Line());
    _row = 0;
    _col = 0;
    _top = 0;
    _reverse = false;
    _savedRow = 0;
    _savedCol = 0;
    _state = _State.ground;
    _params.clear();
    _oscLength = 0;
  }

  /// Drops the oldest output until at most [maxLines] lines and [maxChars]
  /// characters remain, cutting on line boundaries where possible. Returns how
  /// many characters were dropped.
  int trim({required int maxChars, required int maxLines}) {
    var total = length;
    var dropped = 0;
    var drop = 0;
    while (_lines.length - drop > 1 &&
        (_lines.length - drop > maxLines || total > maxChars)) {
      final size = _lines[drop].chars.length + 1;
      total -= size;
      dropped += size;
      drop++;
    }
    if (drop > 0) {
      _lines.removeRange(0, drop);
      _row = math.max(0, _row - drop);
      _top = math.max(0, _top - drop);
    }
    // One line longer than the whole window: keep its tail rather than nothing.
    if (total > maxChars) {
      final cut = total - maxChars;
      _lines.first.removeHead(cut);
      dropped += cut;
      if (_row == 0) _col = math.max(0, _col - cut);
    }
    return dropped;
  }

  TerminalView render() {
    final text = StringBuffer();
    List<HighlightRange>? highlights;
    var offset = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (i > 0) {
        text.writeCharCode(0x0a);
        offset++;
      }
      final line = _lines[i];
      text.write(String.fromCharCodes(line.chars));
      final reverse = line.reverse;
      if (reverse != null) {
        var start = -1;
        for (var c = 0; c <= reverse.length; c++) {
          final on = c < reverse.length && reverse[c];
          if (on && start < 0) {
            start = c;
          } else if (!on && start >= 0) {
            (highlights ??= []).add((offset + start, offset + c));
            start = -1;
          }
        }
      }
      offset += line.chars.length;
    }
    return (text: text.toString(), highlights: highlights ?? const []);
  }

  void _feed(int c) {
    switch (_state) {
      case _State.ground:
        if (c == 0x1b) {
          _state = _State.escape;
        } else if (c < 0x20 || c == 0x7f) {
          _control(c);
        } else {
          _put(c);
        }
      case _State.escape:
        _escape(c);
      case _State.escapeSkip:
        _state = _State.ground;
      case _State.csi:
        if (c >= 0x40 && c <= 0x7e) {
          _state = _State.ground;
          _dispatchCsi(c);
        } else if (c == 0x1b) {
          _params.clear();
          _state = _State.escape;
        } else if (c < 0x20) {
          _control(c);
        } else if (c <= 0x3f) {
          if (c >= 0x30) _params.writeCharCode(c);
          if (_params.length > _maxParamsLength) {
            _params.clear();
            _state = _State.ground;
          }
        }
      case _State.osc:
        if (c == 0x07) {
          _state = _State.ground;
        } else if (c == 0x1b) {
          _state = _State.escape;
        } else if (++_oscLength > _maxOscLength) {
          _state = _State.ground;
        }
    }
  }

  void _control(int c) {
    switch (c) {
      case 0x0a || 0x0b || 0x0c:
        // Treated as CR+LF: some firmware sends a bare LF.
        _lineFeed();
        _col = 0;
      case 0x0d:
        _col = 0;
      case 0x08:
        if (_col > 0) _col--;
      case 0x09:
        _col = (_col ~/ 8 + 1) * 8;
    }
  }

  void _escape(int c) {
    _state = _State.ground;
    switch (c) {
      case 0x5b: // [
        _params.clear();
        _state = _State.csi;
      case 0x5d: // ]
        _oscLength = 0;
        _state = _State.osc;
      case 0x28 || 0x29 || 0x2a || 0x2b || 0x2d || 0x2e || 0x2f || 0x23 || 0x25:
        // Charset and line-size selectors carry one more byte.
        _state = _State.escapeSkip;
      case 0x37: // 7
        _saveCursor();
      case 0x38: // 8
        _restoreCursor();
      case 0x44: // D
        _lineFeed();
      case 0x45: // E
        _lineFeed();
        _col = 0;
      case 0x4d: // M
        if (_row > _top) _row--;
      case 0x63: // c
        _clearScreen();
        _moveTo(0, 0);
        _reverse = false;
    }
  }

  void _dispatchCsi(int finalByte) {
    final raw = _params.toString();
    _params.clear();
    // Private modes (cursor visibility and the like) change nothing shown.
    if (raw.isNotEmpty && '<=>?'.contains(raw[0])) return;
    final args = raw.split(';').map((s) => int.tryParse(s) ?? 0).toList();
    int arg(int i, [int fallback = 1]) {
      final value = i < args.length ? args[i] : 0;
      return value == 0 ? fallback : value;
    }

    switch (finalByte) {
      case 0x41: // A
        _row = math.max(_top, _row - arg(0));
      case 0x42: // B
        _row = math.min(_top + rows - 1, _row + arg(0));
      case 0x43: // C
        _col += arg(0);
      case 0x44: // D
        _col = math.max(0, _col - arg(0));
      case 0x45: // E
        _row = math.min(_top + rows - 1, _row + arg(0));
        _col = 0;
      case 0x46: // F
        _row = math.max(_top, _row - arg(0));
        _col = 0;
      case 0x47 || 0x60: // G `
        _col = arg(0) - 1;
      case 0x64: // d
        _moveTo(arg(0) - 1, _col);
      case 0x48 || 0x66: // H f
        _moveTo(arg(0) - 1, arg(1) - 1);
      case 0x4a: // J
        _eraseDisplay(args.first);
      case 0x4b: // K
        _eraseLine(args.first);
      case 0x6d: // m
        for (final code in args) {
          if (code == 0 || code == 27) _reverse = false;
          if (code == 7) _reverse = true;
        }
      case 0x73: // s
        _saveCursor();
      case 0x75: // u
        _restoreCursor();
    }
  }

  void _put(int c) {
    _lineAt(_row).set(_col, c, _reverse);
    _col++;
  }

  _Line _lineAt(int row) {
    while (_lines.length <= row) {
      _lines.add(_Line());
    }
    return _lines[row];
  }

  void _lineFeed() {
    _row++;
    _lineAt(_row);
    if (_row - _top >= rows) _top = _row - rows + 1;
  }

  void _moveTo(int row, int col) {
    _row = _top + row.clamp(0, rows - 1);
    _col = math.max(0, col);
  }

  void _saveCursor() {
    _savedRow = _row - _top;
    _savedCol = _col;
  }

  void _restoreCursor() => _moveTo(_savedRow, _savedCol);

  void _eraseDisplay(int mode) {
    switch (mode) {
      case 0:
        if (_row >= _lines.length) return;
        _lines[_row].truncate(_col);
        _lines.length = _row + 1;
      case 1:
        for (var r = _top; r < math.min(_row, _lines.length); r++) {
          _lines[r].clear();
        }
        if (_row < _lines.length) _lines[_row].blank(_col + 1);
      case 2:
        final relative = _row - _top;
        _clearScreen();
        _row = _top + relative;
      // 3 (erase scrollback) is ignored: the history is the point of the log.
    }
  }

  /// Starts a fresh screen below everything shown so far.
  void _clearScreen() {
    while (_lines.length > 1 && _lines.last.isEmpty) {
      _lines.removeLast();
    }
    if (!_lines.last.isEmpty) _lines.add(_Line());
    _top = _lines.length - 1;
    _row = _top;
  }

  void _eraseLine(int mode) {
    if (_row >= _lines.length) return;
    final line = _lines[_row];
    switch (mode) {
      case 0:
        line.truncate(_col);
      case 1:
        line.blank(_col + 1);
      case 2:
        line.clear();
    }
  }
}

enum _State { ground, escape, escapeSkip, csi, osc }

class _Line {
  final List<int> chars = [];

  /// Per-character reverse video, allocated only once a line uses it.
  List<bool>? reverse;

  bool get isEmpty => chars.isEmpty;

  void set(int col, int char, bool rev) {
    if (rev && reverse == null) {
      reverse = List<bool>.filled(chars.length, false, growable: true);
    }
    while (chars.length < col) {
      chars.add(0x20);
      reverse?.add(false);
    }
    if (col < chars.length) {
      chars[col] = char;
      reverse?[col] = rev;
    } else {
      chars.add(char);
      reverse?.add(rev);
    }
  }

  void truncate(int col) {
    if (col >= chars.length) return;
    chars.length = col;
    reverse?.length = col;
  }

  /// Blanks the first [count] characters.
  void blank(int count) {
    final end = math.min(count, chars.length);
    for (var i = 0; i < end; i++) {
      chars[i] = 0x20;
      reverse?[i] = false;
    }
  }

  void clear() {
    chars.clear();
    reverse = null;
  }

  void removeHead(int count) {
    final n = math.min(count, chars.length);
    chars.removeRange(0, n);
    reverse?.removeRange(0, n);
  }
}
