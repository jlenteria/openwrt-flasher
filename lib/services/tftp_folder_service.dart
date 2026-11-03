import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where Tftpd64 was found and the folder it serves.
class Tftpd64Location {
  const Tftpd64Location({required this.installDir, required this.baseDir});

  final String installDir;

  /// The folder Tftpd64 serves: its install folder unless tftpd32.ini names
  /// another base directory.
  final String baseDir;
}

/// Finds the folders the recovery guide copies firmware between.
class TftpFolderService {
  static const _uninstallKeys = [
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  ];

  /// Tftpd64's installer puts it here unless the user picks another folder.
  static String get defaultTftpd64Dir {
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    return '$programFiles\\Tftpd64';
  }

  /// The Downloads folder from the environment, known without a plugin call.
  static String get fallbackDownloadsDir {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    return '$home${Platform.pathSeparator}Downloads';
  }

  /// The user's Downloads folder, honouring a relocated folder where the OS
  /// reports one.
  static Future<String> downloadsDir() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir.path;
    } catch (_) {}
    return fallbackDownloadsDir;
  }

  /// Looks Tftpd64 up in the uninstall registry and the usual install
  /// folders. Returns null when it is not installed (or not on Windows).
  static Future<Tftpd64Location?> findTftpd64() async {
    if (!Platform.isWindows) return null;
    final candidates = <String>[
      ...await _registryInstallDirs(),
      defaultTftpd64Dir,
      if (Platform.environment['ProgramFiles(x86)'] case final x86?)
        '$x86\\Tftpd64',
      if (Platform.environment['LOCALAPPDATA'] case final local?)
        '$local\\Programs\\Tftpd64',
    ];
    for (final dir in candidates) {
      if (!await _hasTftpd64(dir)) continue;
      return Tftpd64Location(
        installDir: dir,
        baseDir: await _baseDirFromIni(dir) ?? dir,
      );
    }
    return null;
  }

  static Future<bool> _hasTftpd64(String dir) async {
    for (final exe in const ['tftpd64.exe', 'tftpd32.exe', 'tftpd64_svc.exe']) {
      if (await File('$dir\\$exe').exists()) return true;
    }
    return false;
  }

  static Future<List<String>> _registryInstallDirs() async {
    final dirs = <String>[];
    for (final root in _uninstallKeys) {
      try {
        final keys = await Process.run('reg', [
          'query',
          root,
          '/f',
          'Tftpd',
          '/k',
        ]);
        if (keys.exitCode != 0) continue;
        for (final key in const LineSplitter().convert(keys.stdout as String)) {
          if (!key.trim().toUpperCase().startsWith('HKEY_')) continue;
          final values = await Process.run('reg', ['query', key.trim()]);
          if (values.exitCode != 0) continue;
          final dir = installDirFromRegistry(values.stdout as String);
          if (dir != null) dirs.add(dir);
        }
      } catch (_) {}
    }
    return dirs;
  }

  /// Reads the install folder from `reg query` output of an uninstall key:
  /// InstallLocation, or the folder of the uninstaller or icon.
  static String? installDirFromRegistry(String regOutput) {
    final values = <String, String>{};
    final line = RegExp(r'^\s+(\S+)\s+REG_\w+\s+(.*)$');
    for (final row in const LineSplitter().convert(regOutput)) {
      final match = line.firstMatch(row);
      if (match != null) values[match.group(1)!] = match.group(2)!.trim();
    }
    final location = values['InstallLocation'];
    if (location != null && location.isNotEmpty) {
      return _trimSlash(_unquote(location));
    }
    for (final name in const ['UninstallString', 'DisplayIcon']) {
      final value = values[name];
      if (value == null || value.isEmpty) continue;
      final exe = _executablePath(value);
      final slash = exe.lastIndexOf('\\');
      if (slash > 0) return exe.substring(0, slash);
    }
    return null;
  }

  /// The `BaseDirectory` from Tftpd64's settings, resolved against its
  /// install folder. Null when the file is missing or keeps the default.
  static Future<String?> _baseDirFromIni(String installDir) async {
    final ini = File('$installDir\\tftpd32.ini');
    if (!await ini.exists()) return null;
    try {
      return baseDirFromIni(await ini.readAsString(), installDir);
    } catch (_) {
      return null;
    }
  }

  static String? baseDirFromIni(String ini, String installDir) {
    final match = RegExp(
      r'^\s*BaseDirectory\s*=\s*(.*?)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(ini);
    final value = match == null ? '' : _unquote(match.group(1)!);
    if (value.isEmpty || value == '.' || value == r'.\') return null;
    final absolute = RegExp(r'^([A-Za-z]:\\|\\\\)').hasMatch(value);
    final relative = value.startsWith(r'.\') ? value.substring(2) : value;
    return _trimSlash(absolute ? value : '$installDir\\$relative');
  }

  static String _executablePath(String value) {
    final text = value.trim();
    if (text.startsWith('"')) {
      final end = text.indexOf('"', 1);
      return end > 0 ? text.substring(1, end) : text.substring(1);
    }
    final exe = RegExp(r'^(.*?\.exe)', caseSensitive: false).firstMatch(text);
    return (exe?.group(1) ?? text.split(',').first).trim();
  }

  static String _unquote(String value) {
    final text = value.trim();
    return text.length >= 2 && text.startsWith('"') && text.endsWith('"')
        ? text.substring(1, text.length - 1)
        : text;
  }

  static String _trimSlash(String dir) => dir.length > 3 && dir.endsWith('\\')
      ? dir.substring(0, dir.length - 1)
      : dir;

  /// Opens [directory] in File Explorer, Finder or the Linux file manager.
  static Future<void> openFolder(String directory) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [directory]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [directory]);
    } else {
      await Process.run('xdg-open', [directory]);
    }
  }
}
