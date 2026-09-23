/// One award option from `previewBundleAward`: who wins what, and what it
/// costs. Built by the server from the stored bids, never by the app.
class BundleAwardOption {
  const BundleAwardOption({
    required this.key,
    required this.label,
    required this.totalSen,
    required this.providerCount,
    required this.premiumSen,
    required this.weightedTrust,
    this.uncoveredTaskIds = const [],
    this.warnings = const [],
    this.awards = const [],
  });

  /// 'cheapest', 'fewest' or 'recommended'.
  final String key;
  final String label;
  final int totalSen;
  final int providerCount;

  /// How much more than the cheapest option this one costs.
  final int premiumSen;

  /// Trust Score weighted by how much each provider is paid.
  final int weightedTrust;

  /// Tasks no bid covers; awarding releases them back to ordinary bidding.
  final List<String> uncoveredTaskIds;

  /// Handovers this option splits between providers.
  final List<String> warnings;

  final List<BundleAwardItem> awards;

  /// The picks to send to `awardBundle`.
  Map<String, String> get providerByTaskId => {
        for (final award in awards)
          for (final taskId in award.taskAmountsSen.keys)
            taskId: award.providerId,
      };

  factory BundleAwardOption.fromMap(Map<String, dynamic> m) =>
      BundleAwardOption(
        key: m['key'] as String? ?? '',
        label: m['label'] as String? ?? '',
        totalSen: (m['totalSen'] as num?)?.toInt() ?? 0,
        providerCount: (m['providerCount'] as num?)?.toInt() ?? 0,
        premiumSen: (m['premiumSen'] as num?)?.toInt() ?? 0,
        weightedTrust: (m['weightedTrust'] as num?)?.toInt() ?? 0,
        uncoveredTaskIds:
            (m['uncoveredTaskIds'] as List?)?.whereType<String>().toList() ??
                const [],
        warnings:
            (m['warnings'] as List?)?.whereType<String>().toList() ?? const [],
        awards: (m['awards'] as List?)
                ?.whereType<Map>()
                .map((a) => BundleAwardItem.fromMap(a))
                .toList() ??
            const [],
      );
}

/// What one provider wins in an option, and what each task pays them.
class BundleAwardItem {
  const BundleAwardItem({
    required this.providerId,
    required this.providerName,
    required this.taskAmountsSen,
  });

  final String providerId;
  final String providerName;

  /// Job id to amount in sen. Each amount lands on that task as its accepted
  /// bid amount, so a milestone plan has to total it exactly.
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
