/// One award option from `previewBundleAward`: who wins which tasks and
/// what it costs. The server builds it from the stored bids.
class BundleAwardOption {
  const BundleAwardOption({
    required this.key,
    required this.label,
    required this.totalSen,
    required this.providerCount,
    required this.premiumSen,
    required this.weightedTrust,
    this.trustVisible = false,
    this.uncoveredTaskIds = const [],
    this.awards = const [],
  });

  /// 'cheapest', 'fewest' or 'recommended'.
  final String key;
  final String label;
  final int totalSen;
  final int providerCount;

  /// How much more this option costs than the cheapest.
  final int premiumSen;

  /// Trust Score weighted by how much each provider is paid.
  final int weightedTrust;

  /// False when any hired provider is still new, so [weightedTrust] is hidden.
  final bool trustVisible;

  /// Tasks no bid covers. Awarding sends them back to normal bidding.
  final List<String> uncoveredTaskIds;

  final List<BundleAwardItem> awards;

  /// The picks to send to `awardBundle`.
  Map<String, String> get providerByTaskId => {
    for (final award in awards)
      for (final taskId in award.taskAmountsSen.keys) taskId: award.providerId,
  };

  factory BundleAwardOption.fromMap(Map<String, dynamic> m) =>
      BundleAwardOption(
        key: m['key'] as String? ?? '',
        label: m['label'] as String? ?? '',
        totalSen: (m['totalSen'] as num?)?.toInt() ?? 0,
        providerCount: (m['providerCount'] as num?)?.toInt() ?? 0,
        premiumSen: (m['premiumSen'] as num?)?.toInt() ?? 0,
        weightedTrust: (m['weightedTrust'] as num?)?.toInt() ?? 0,
        trustVisible: m['trustVisible'] as bool? ?? false,
        uncoveredTaskIds:
            (m['uncoveredTaskIds'] as List?)?.whereType<String>().toList() ??
            const [],
        awards:
            (m['awards'] as List?)
                ?.whereType<Map>()
                .map((a) => BundleAwardItem.fromMap(a))
                .toList() ??
            const [],
      );
}

/// What one provider wins in an option and what each task pays.
class BundleAwardItem {
  const BundleAwardItem({
    required this.providerId,
    required this.providerName,
    required this.taskAmountsSen,
  });

  final String providerId;
  final String providerName;

  /// Job id to amount in sen. It becomes the task's accepted bid amount,
  /// so the funded stage must equal it exactly.
  final Map<String, int> taskAmountsSen;

  int get totalSen =>
      taskAmountsSen.values.fold(0, (sum, amount) => sum + amount);

  factory BundleAwardItem.fromMap(Map m) => BundleAwardItem(
    providerId: m['providerId'] as String? ?? '',
    providerName: m['providerName'] as String? ?? 'Provider',
    taskAmountsSen: <String, int>{
      for (final entry in (m['taskAmountsSen'] as Map? ?? {}).entries)
        if (entry.value is num)
          entry.key as String: (entry.value as num).toInt(),
    },
  );
}
