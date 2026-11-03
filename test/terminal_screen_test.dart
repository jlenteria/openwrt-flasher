import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/models/terminal_screen.dart';

void main() {
  String render(String input) =>
      (TerminalScreen()..write(input)).render().text;

  test('plain log lines pass through', () {
    expect(render('U-Boot 2023.07\r\nDRAM: 256 MiB\r\n'),
        'U-Boot 2023.07\nDRAM: 256 MiB\n');
  });

  test('carriage return and backspace overwrite in place', () {
    expect(render('autoboot: 3\rautoboot: 2'), 'autoboot: 2');
    expect(render('abc\b\b\bxy'), 'xyc');
    expect(render('abc\b \b'), 'ab ');
  });

  test('clear screen keeps earlier output as history', () {
    expect(
      render('boot log\r\n\x1b[2J\x1b[1;1Hmenu'),
      'boot log\nmenu',
    );
  });

  test('cursor addressing places text on the screen grid', () {
    expect(
      render('\x1b[2J\x1b[3;5Hthird\x1b[1;1Hfirst'),
      'first\n\n    third',
    );
  });

  test('erase line and erase below', () {
    expect(render('hello world\x1b[6D\x1b[K'), 'hello');
    expect(render('hello\x1b[1G\x1b[2Kbye'), 'bye');
    expect(render('a\r\nb\r\nc\x1b[2;1H\x1b[J'), 'a\n');
  });

  test('reverse video becomes a highlight range', () {
    final view =
        (TerminalScreen()..write('  \x1b[7mselected\x1b[0m rest')).render();
    expect(view.text, '  selected rest');
    expect(view.highlights, [(2, 10)]);
  });

  test('sequences split across chunks still apply', () {
    final screen = TerminalScreen()
      ..write('x\r\x1b[')
      ..write('2')
      ..write('K')
      ..write('y');
    expect(screen.render().text, 'y');
  });

  test('private modes and title sequences are hidden', () {
    expect(render('\x1b[?25l\x1b]0;title\x07ok\x1b[?25h'), 'ok');
  });
}
