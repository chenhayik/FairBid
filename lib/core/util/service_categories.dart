/// Service categories providers offer and requestors post under.
const kServiceCategories = [
  'Cleaning',
  'Plumbing',
  'Electrical',
  'Aircon Servicing',
  'Home Repair',
  'Moving & Delivery',
  'Tutoring',
  'IT & Tech Support',
  'Design & Creative',
  'Other',
];

/// Keyword to category. Malay first, because that is the language SSM prints
/// the registered nature of business in.
const _categoryKeywords = <String, List<String>>{
  'Cleaning': ['PEMBERSIHAN', 'CUCI', 'DOBI', 'CLEANING', 'LAUNDRY'],
  'Plumbing': ['PAIP', 'PERPAIPAN', 'SANITARI', 'PLUMBING'],
  'Electrical': ['ELEKTRIK', 'PENDAWAIAN', 'ELECTRICAL', 'WIRING'],
  'Aircon Servicing': ['PENYAMAN UDARA', 'PENDINGIN', 'AIRCOND', 'AIR COND'],
  'Home Repair': [
    'PEMBAIKAN', 'PENGUBAHSUAIAN', 'RENOVASI', 'BINAAN',
    'RENOVATION', 'REPAIR', 'CONSTRUCTION',
  ],
  'Moving & Delivery': [
    'PENGANGKUTAN', 'PENGHANTARAN', 'LORI',
    'MOVING', 'DELIVERY', 'TRANSPORT', 'COURIER',
  ],
  'Tutoring': ['TUISYEN', 'PENDIDIKAN', 'TUITION', 'EDUCATION', 'TUTOR'],
  'IT & Tech Support': [
    'KOMPUTER', 'TEKNOLOGI', 'RANGKAIAN', 'COMPUTER', 'SOFTWARE',
  ],
  'Design & Creative': [
    'REKA BENTUK', 'GRAFIK', 'PERCETAKAN', 'FOTOGRAFI',
    'DESIGN', 'GRAPHIC', 'PRINTING', 'PHOTOGRAPH',
  ],
};

/// Maps a registered nature of business - as SSM prints it, in Malay or
/// English - onto one of [kServiceCategories].
///
/// Returns null when nothing matches, and that is the common case rather than a
/// failure: SSM's wording covers every trade in the country while this app
/// serves ten of them. A confident null beats a wrong guess, because the
/// suggestion is written into the applicant's form.
///
/// Never returns 'Other' - suggesting the catch-all would be noise, and the
/// applicant can pick it themselves.
String? suggestedCategoryFor(String? natureOfBusiness) {
  final text = (natureOfBusiness ?? '').toUpperCase();
  if (text.isEmpty) return null;
  for (final entry in _categoryKeywords.entries) {
    if (entry.value.any(text.contains)) return entry.key;
  }
  return null;
}

/// Licensing note for a category that legally requires a registered/licensed
/// tradesperson in Malaysia, or null when [category] has none.
String? licenceNoticeFor(String category) => switch (category) {
      'Electrical' => 'Electrical work in Malaysia must be done by an '
          'Energy Commission-registered contractor.',
      'Plumbing' => 'Major plumbing work may need a SPAN-licensed plumber.',
      _ => null,
    };
