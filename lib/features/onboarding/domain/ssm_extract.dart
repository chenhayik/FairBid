/// What the server could confirm about an uploaded SSM document.
enum SsmVerdict {
  /// Every check that could run, passed.
  passed,

  /// Something did not line up - an admin should look at it.
  needsReview,

  /// Not a usable SSM document.
  rejected;

  static SsmVerdict? fromStorage(String? value) => switch (value) {
        'passed' => SsmVerdict.passed,
        'needsReview' => SsmVerdict.needsReview,
        'rejected' => SsmVerdict.rejected,
        _ => null,
      };
}

/// The server's reading of an uploaded SSM document, from the owner+admin-only
/// `users/{uid}/private/ssmExtract` document.
///
/// Written **only** by the `extractSsmDocument` Cloud Function, which runs with
/// the admin SDK and bypasses security rules; `firestore.rules` forbids any
/// client from writing this document, so an applicant cannot forge their own
/// verification result.
///
/// Every field here is a **proposal**. The applicant confirms or corrects it
/// before any of it reaches their profile - autofill that writes silently is
/// autofill you cannot audit.
class SsmExtract {
  const SsmExtract({
    required this.verdict,
    this.failures = const [],
    this.registrationNumber,
    this.businessName,
    this.entityStatus,
    this.ownership,
    this.expiryDate,
    this.businessStartDate,
    this.natureOfBusiness,
    this.ownerNameMatches,
    this.signaturePresent = false,
  });

  final SsmVerdict verdict;

  /// Machine-readable reasons, resolved to prose by [reasons].
  final List<String> failures;

  final String? registrationNumber;
  final String? businessName;
  final String? entityStatus;
  final String? ownership;

  /// `YYYY-MM-DD`, or null when the document did not state a parseable date.
  /// Only ever populated from a cleanly parsed date - a half-read one is left
  /// null rather than guessed, so it can never wrongly reject a registration.
  final String? expiryDate;
  final String? businessStartDate;

  /// The registered nature of business, e.g. "PERKHIDMATAN PERGIGIAN". Useful
  /// for suggesting the provider's service category.
  final String? natureOfBusiness;

  /// Whether the owner named on the optional Business Profile matches the
  /// account holder. Three-valued on purpose: null means no Profile was
  /// supplied, or neither name was usable - which is not the same as "no".
  ///
  /// Only ever the comparison result. The owner's name itself is compared on
  /// the server and discarded; it is never stored or sent to the client.
  final bool? ownerNameMatches;

  /// Whether the PDF carried a digital signature at all. Verifying that
  /// signature cryptographically is not yet implemented - see
  /// `functions/index.js`.
  final bool signaturePresent;

  bool get hasProposals =>
      (businessName ?? '').isNotEmpty || (registrationNumber ?? '').isNotEmpty;

  static const _reasons = {
    'not-a-pdf': 'That file was not a readable PDF.',
    'hidden-text': 'This document contains text that is not visible when it is '
        'read normally, so it cannot be trusted.',
    'no-text-layer': 'This looks like a photo or a scan rather than the '
        'original PDF from SSM. Please upload the file you downloaded from '
        'EzBiz or e-Info.',
    'no-registration-number': 'No SSM registration number was found.',
    'number-mismatch': 'The number on the document does not match the one you '
        'entered.',
    'registration-expired': 'This registration has expired. Please upload a '
        'current certificate.',
    'missing-ssm-markers': 'The document is missing the usual SSM markings.',
    'not-digitally-signed': 'This is not a digitally certified copy, so our '
        'team will check it by hand.',
  };

  /// Plain-English reasons, for the applicant and the admin queue.
  List<String> get reasons => [for (final f in failures) _reasons[f] ?? f];

  static SsmExtract? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final verdict = SsmVerdict.fromStorage(map['verdict'] as String?);
    if (verdict == null) return null;
    return SsmExtract(
      verdict: verdict,
      failures: (map['failures'] as List?)?.whereType<String>().toList() ??
          const [],
      registrationNumber: map['registrationNumber'] as String?,
      businessName: map['businessName'] as String?,
      entityStatus: map['entityStatus'] as String?,
      ownership: map['ownership'] as String?,
      expiryDate: map['expiryDate'] as String?,
      businessStartDate: map['businessStartDate'] as String?,
      natureOfBusiness: map['natureOfBusiness'] as String?,
      ownerNameMatches: map['ownerNameMatches'] as bool?,
      signaturePresent: map['signaturePresent'] as bool? ?? false,
    );
  }
}
