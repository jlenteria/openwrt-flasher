import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/models/console_tail.dart';

void main() {
  ConsoleTail tail({required int bytes, required int lines}) =>
      ConsoleTail(maxBytes: bytes, maxLines: lines);

  test('merges everything received since the last flush', () {
    final window = tail(bytes: 1000, lines: 100);
    window
      ..add('openwrt login: ')
      ..add('root\n');

    expect(window.flush(), 'openwrt login: root\n');
    expect(window.hasPending, isFalse);
    // Flushing with nothing pending returns the retained window unchanged.
    expect(window.flush(), 'openwrt login: root\n');
    expect(window.droppedBytes, 0);
  });

  test('keeps the newest bytes and never shows a torn line', () {
    final window = tail(bytes: 30, lines: 1000);
    window.add('0123456789\n' * 4);

    final kept = window.flush();

    expect(kept, '0123456789\n' * 2);
    expect(kept.length, lessThanOrEqualTo(30));
    expect(window.droppedBytes, 44 - kept.length);
    expect(window.totalBytes, 44);
  });

  test('keeps a trailing partial line instead of losing the whole window', () {
    final window = tail(bytes: 10, lines: 1000);
    window.add('x' * 20);

    expect(window.flush(), 'x' * 10);
  });

  test('survives a line longer than the whole window', () {
    final window = tail(bytes: 10, lines: 1000);
    window.add('short\n${'y' * 200}');

    final kept = window.flush();

    expect(kept, 'y' * 10);
    expect(kept, isNot(contains('short')));
  });

  test('caps the line count as well as the byte count', () {
    final window = tail(bytes: 1000, lines: 2);
    window.add('a\nb\nc\nd\n');

    // maxLines counts the segments of a split on '\n', so a window of 2 keeps
    // the last complete line plus the trailing fragment.
    expect(window.flush(), 'd\n');
  });

  test('counts bytes dropped from an earlier flush', () {
    final window = tail(bytes: 30, lines: 1000);
    window.add('a' * 20);
    expect(window.flush(), 'a' * 20);
    expect(window.droppedBytes, 0);

    window.add('b' * 20);
    final kept = window.flush();

    expect(kept.length, 30);
    expect(kept, endsWith('b' * 20));
    expect(window.droppedBytes, 10);
    expect(window.totalBytes, 40);
  });

  test('clear forgets the session', () {
    final window = tail(bytes: 30, lines: 1000);
    window
      ..add('a' * 40)
      ..flush()
      ..add('pending')
      ..clear();

    expect(window.flush(), isEmpty);
    expect(window.totalBytes, 0);
    expect(window.droppedBytes, 0);
    expect(window.hasPending, isFalse);
  });
}
