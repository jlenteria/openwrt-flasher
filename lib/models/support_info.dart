/// The support ask, verbatim from `docs/SUPPORT.md` and the README.
///
/// `test/support_test.dart` asserts every sentence here appears in both files, so
/// the app, the repository's Sponsor page and the docs cannot drift apart.
class SupportInfo {
  SupportInfo._();

  /// `docs/banks/bpi.jpg` — the same image `docs/SUPPORT.md` embeds, declared as
  /// an asset in `pubspec.yaml` instead of copied into `assets/`.
  static const String qrAsset = 'docs/banks/bpi.jpg';

  static const String title = 'Support OpenWrt Flasher';

  static const String intro =
      'OpenWrt Flasher is free, with no ads and no accounts. Every feature is '
      'available to everyone.';

  static const String tip =
      'If you would like to, you can send an optional, voluntary tip directly '
      'to the developer. It unlocks nothing and gives no rewards.';

  static const String scan =
      'Scan the QR with any QR Ph app. This is a direct person-to-person '
      'transfer to the developer, not a purchase.';

  static const String thanks =
      'Never required. Thank you for using OpenWrt Flasher!';

  /// In reading order. The parity test iterates this list, so a sentence added
  /// to the dialog has to exist in the docs too.
  static const List<String> sentences = [intro, tip, scan, thanks];
}
