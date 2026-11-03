import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/tftp_folder_service.dart';

void main() {
  group('installDirFromRegistry', () {
    test('prefers InstallLocation', () {
      const output = '''

HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Tftpd64
    DisplayName    REG_SZ    Tftpd64
    InstallLocation    REG_SZ    D:\\Tools\\Tftpd64\\
    UninstallString    REG_SZ    "C:\\Program Files\\Tftpd64\\uninstall.exe"
''';
      expect(
        TftpFolderService.installDirFromRegistry(output),
        r'D:\Tools\Tftpd64',
      );
    });

    test('falls back to the uninstaller folder', () {
      const output = '''
HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Tftpd64
    DisplayName    REG_SZ    Tftpd64
    UninstallString    REG_SZ    "C:\\Program Files\\Tftpd64\\uninstall.exe" /S
''';
      expect(
        TftpFolderService.installDirFromRegistry(output),
        r'C:\Program Files\Tftpd64',
      );
    });

    test('reads an unquoted icon path', () {
      const output = '''
    DisplayIcon    REG_SZ    C:\\Apps\\Tftpd64\\tftpd64.exe,0
''';
      expect(
        TftpFolderService.installDirFromRegistry(output),
        r'C:\Apps\Tftpd64',
      );
    });

    test('returns null without a usable value', () {
      expect(
        TftpFolderService.installDirFromRegistry(
          '    DisplayName    REG_SZ    Tftpd64',
        ),
        isNull,
      );
    });
  });

  group('baseDirFromIni', () {
    const install = r'C:\Program Files\Tftpd64';

    test('keeps the install folder for the default "."', () {
      expect(
        TftpFolderService.baseDirFromIni(
          '[TFTPD32]\nBaseDirectory=.\n',
          install,
        ),
        isNull,
      );
      expect(TftpFolderService.baseDirFromIni('[TFTPD32]\n', install), isNull);
    });

    test('uses an absolute base directory', () {
      expect(
        TftpFolderService.baseDirFromIni('BaseDirectory=D:\\tftp\\\n', install),
        r'D:\tftp',
      );
    });

    test('resolves a relative base directory against the install folder', () {
      expect(
        TftpFolderService.baseDirFromIni(
          'BaseDirectory=.\\firmware\n',
          install,
        ),
        r'C:\Program Files\Tftpd64\firmware',
      );
      expect(
        TftpFolderService.baseDirFromIni('BaseDirectory=firmware\n', install),
        r'C:\Program Files\Tftpd64\firmware',
      );
    });
  });
}
