import 'package:flutter_test/flutter_test.dart';

import 'package:openwrt_flasher/services/firmware_download_service.dart';

void main() {
  test('the default images point at the shared Drive files', () {
    final images = FirmwareDownloadService.defaultImages;
    expect(images, hasLength(2));
    expect(
      images.map((image) => image.fileId),
      containsAll([
        '1ku6Hk5ivIF9N0-1fua4DaQcfKOsYFPM5',
        '1qFELcvKvQ1JpzjsqxVIzVdHrpfT9sgqQ',
      ]),
    );

    for (final image in images) {
      expect(
        image.downloadUrl,
        'https://drive.google.com/uc?export=download&id=${image.fileId}',
      );
      expect(image.fileName, endsWith('.bin'));
    }
  });

  test('one default firmware and one example upgrade are labelled apart', () {
    final defaultFirmware = FirmwareDownloadService.defaultFirmwareImages;
    final upgrades = FirmwareDownloadService.upgradeFirmwareImages;
    expect(defaultFirmware, hasLength(1));
    expect(upgrades, hasLength(1));

    expect(defaultFirmware.single.label, 'ZR-2660');
    expect(defaultFirmware.single.fileName, 'default-firmware.bin');
    expect(defaultFirmware.single.isUpgrade, isFalse);

    expect(upgrades.single.label, 'FlareWifi');
    expect(upgrades.single.fileName, 'flarewifi-firmware.bin');
    expect(upgrades.single.isUpgrade, isTrue);
  });
}
