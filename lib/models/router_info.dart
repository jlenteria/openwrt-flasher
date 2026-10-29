/// A router whose identity has been confirmed over SSH.
class RouterInfo {
  const RouterInfo({
    required this.ip,
    required this.boardName,
    required this.model,
    required this.firmwareVersion,
    this.hostname = '',
    this.compatIds = const [],
  });

  final String ip;

  /// `/tmp/sysinfo/board_name` — the value a sysupgrade image must support.
  final String boardName;

  /// `/tmp/sysinfo/model`.
  final String model;

  final String firmwareVersion;
  final String hostname;

  /// Device-tree compatible strings, when readable.
  final List<String> compatIds;

  /// Strings a compatible firmware image is expected to mention.
  List<String> get identifiers {
    final ids = <String>{
      boardName,
      ...compatIds,
      model.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll('_*', ''),
    };
    ids.removeWhere((id) => id.trim().length < 4);
    final sorted = ids.toList()..sort();
    return sorted;
  }

  @override
  String toString() =>
      'RouterInfo(ip: $ip, board: $boardName, version: $firmwareVersion)';
}

/// A device discovered on the LAN that looks like it might be the target
/// router. Identity is only established after an SSH probe of this candidate.
class RouterCandidate {
  const RouterCandidate({required this.ip, required this.hint, required this.banner});

  final String ip;

  /// `ssh` or `luci`, for display only.
  final String hint;

  /// The SSH banner or HTTP status that made this a candidate.
  final String banner;
}
