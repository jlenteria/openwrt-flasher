// Generates the Windows and Linux app icons from assets/icon/app_icon.png.
// flutter_launcher_icons handles macOS; it can only write a single-size .ico
// on Windows and has no Linux support at all.
//
// Run with: make icons
import 'dart:io';

import 'package:image/image.dart' as img;

const _source = 'assets/icon/app_icon.png';
const _windowsIco = 'windows/runner/resources/app_icon.ico';
const _linuxPng = 'linux/runner/resources/app_icon.png';

const _windowsSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];
const _linuxSize = 256;

void main() {
  final source = img.decodePng(File(_source).readAsBytesSync());
  if (source == null) {
    stderr.writeln('Could not decode $_source');
    exit(1);
  }

  // The source carries the transparent margin macOS expects around its icon
  // tile. Windows and Linux icons are drawn closer to the edge, so trim most
  // of it to keep the artwork legible at 16-32px.
  final margin = (source.width * 88 / 1024).round();
  final tile = img.copyCrop(
    source,
    x: margin,
    y: margin,
    width: source.width - margin * 2,
    height: source.height - margin * 2,
  );

  img.Image resized(int size) => img.copyResize(
    tile,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );

  File(_windowsIco).writeAsBytesSync(
    img.IcoEncoder().encodeImages([for (final s in _windowsSizes) resized(s)]),
  );
  stdout.writeln('Wrote $_windowsIco (${_windowsSizes.join(', ')}px)');

  File(_linuxPng)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(resized(_linuxSize)));
  stdout.writeln('Wrote $_linuxPng (${_linuxSize}px)');
}
