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

/// What:   Maps a registered nature of business onto one of [kServiceCategories].
/// Input:  SSM nature-of-business text (Malay or English) from the OCR extract; may be null.
/// Output: A category name, or null when nothing matches; never 'Other'.
/// Notes:  Null is the common case: SSM wording covers every trade while the app serves ten. The result is written into
///         the applicant's form, so a confident null beats a wrong guess.
String? suggestedCategoryFor(String? natureOfBusiness) {
  final text = (natureOfBusiness ?? '').toUpperCase();
  if (text.isEmpty) return null;
  for (final entry in _categoryKeywords.entries) {
    if (entry.value.any(text.contains)) return entry.key;
  }
  return null;
}

/// What:   Licensing note for categories that legally need a registered tradesperson in Malaysia.
/// Input:  [category] from kServiceCategories.
/// Output: Notice text, or null when the category has none.
String? licenceNoticeFor(String category) => switch (category) {
      'Electrical' => 'Electrical work in Malaysia must be done by an '
          'Energy Commission-registered contractor.',
      'Plumbing' => 'Major plumbing work may need a SPAN-licensed plumber.',
      _ => null,
    };
