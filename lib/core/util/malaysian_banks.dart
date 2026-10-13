/// What:   A Malaysian bank a provider can be paid into.
/// Input:  [kMalaysianBanks] (must match BANKS in functions/payout_method.js).
/// Output: [swift] id and [checkAccount] length validation.
class MalaysianBank {
  const MalaysianBank(this.name, this.swift, [this.lengths]);

  final String name;

  /// The bank's id for payouts. Picked from this list, never typed in.
  final String swift;

  /// Account number lengths, or null when any 8 to 17 digits is accepted.
  final List<int>? lengths;

  /// An error for [accountNumber], or null when it fits this bank.
  String? checkAccount(String accountNumber) {
    final number = accountNumber.trim();
    if (number.isEmpty) return 'Enter your account number.';
    if (!RegExp(r'^\d+$').hasMatch(number)) {
      return 'Use digits only, no spaces or dashes.';
    }
    final known = lengths;
    if (known != null) {
      return known.contains(number.length)
          ? null
          : '$name account numbers have ${known.join(' or ')} digits.';
    }
    return number.length >= 8 && number.length <= 17
        ? null
        : "That account number doesn't look right.";
  }
}

const kMalaysianBanks = [
  MalaysianBank('Maybank', 'MBBEMYKL', [12]),
  MalaysianBank('CIMB Bank', 'CIBBMYKL', [10, 14]),
  MalaysianBank('Public Bank', 'PBBEMYKL', [10]),
  MalaysianBank('RHB Bank', 'RHBBMYKL', [14]),
  MalaysianBank('Hong Leong Bank', 'HLBBMYKL', [11, 12, 13]),
  MalaysianBank('AmBank', 'ARBKMYKL'),
  MalaysianBank('Bank Islam', 'BIMBMYKL'),
  MalaysianBank('Bank Rakyat', 'BKRMMYKL'),
  MalaysianBank('BSN', 'BSNAMYK1'),
  MalaysianBank('Affin Bank', 'PHBMMYKL'),
  MalaysianBank('Alliance Bank', 'MFBBMYKL'),
  MalaysianBank('OCBC Bank', 'OCBCMYKL'),
  MalaysianBank('UOB Malaysia', 'UOVBMYKL'),
  MalaysianBank('HSBC Malaysia', 'HBMBMYKL'),
  MalaysianBank('Standard Chartered', 'SCBLMYKX'),
  MalaysianBank('Bank Muamalat', 'BMMBMYKL'),
  MalaysianBank('Agrobank', 'AGOBMYKL'),
];
