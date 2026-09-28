/// Ready-made bundles a requestor can start from, instead of typing every
/// task by hand. Categories are exact entries of [kServiceCategories].
///
/// Lots and dependencies here are read-only in v1 (see
/// docs/BUNDLE_BIDDING.md): they only ever come from a template, never from
/// the requestor's own editing.
class BundleTemplateTask {
  const BundleTemplateTask({
    required this.title,
    required this.category,
    this.lotId,
    this.startsAfter,
    this.gapDays,
  });

  final String title;
  final String category;

  /// Tasks sharing a lot id bid and get awarded together.
  final String? lotId;

  /// Index, within the template's task list, of the task this one starts
  /// after.
  final int? startsAfter;

  final int? gapDays;
}

class BundleTemplate {
  const BundleTemplate({required this.name, required this.tasks});

  final String name;
  final List<BundleTemplateTask> tasks;
}

const kBundleTemplates = [
  BundleTemplate(
    name: 'Bathroom renovation',
    tasks: [
      BundleTemplateTask(title: 'Plumbing rough-in', category: 'Plumbing'),
      BundleTemplateTask(
        title: 'Waterproofing',
        category: 'Home Repair',
        lotId: 'wet-area',
        startsAfter: 0,
      ),
      BundleTemplateTask(
        title: 'Tiling',
        category: 'Home Repair',
        lotId: 'wet-area',
        startsAfter: 1,
        gapDays: 2,
      ),
      BundleTemplateTask(
        title: 'Electrical fittings',
        category: 'Electrical',
        startsAfter: 0,
      ),
    ],
  ),
  BundleTemplate(
    name: 'Kitchen refresh',
    tasks: [
      BundleTemplateTask(title: 'Remove old cabinets', category: 'Home Repair'),
      BundleTemplateTask(
        title: 'Sink plumbing',
        category: 'Plumbing',
        startsAfter: 0,
      ),
      BundleTemplateTask(
        title: 'Electrical points',
        category: 'Electrical',
        startsAfter: 0,
      ),
      BundleTemplateTask(
        title: 'Install cabinets and countertop',
        category: 'Home Repair',
        startsAfter: 1,
      ),
    ],
  ),
  BundleTemplate(
    name: 'Move-in prep',
    tasks: [
      BundleTemplateTask(title: 'Deep clean', category: 'Cleaning'),
      BundleTemplateTask(
        title: 'Aircon servicing',
        category: 'Aircon Servicing',
      ),
      BundleTemplateTask(
        title: 'Moving',
        category: 'Moving & Delivery',
        startsAfter: 0,
      ),
    ],
  ),
];
