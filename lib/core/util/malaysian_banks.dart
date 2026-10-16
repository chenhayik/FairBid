/// What:   A Malaysian bank a provider can be paid into.
/// Input:  [kMalaysianBanks] (must match BANKS in functions/payout_method.js).
/// Output: [swift] id, [checkAccount] length validation and [lengthHint].
class MalaysianBank {
  const MalaysianBank(this.name, this.swift, [this.lengths]);

  final String name;

  /// The bank's id for payouts. Picked from this list, never typed in.
  final String swift;

  /// Account number lengths, or null when any 8 to 17 digits is accepted.
  final List<int>? lengths;

  /// What:   Strips spaces and dashes from an account number.
  /// Input:  [input] as typed or pasted from a banking app.
  /// Output: The remaining characters.
  static String clean(String input) => input.replaceAll(RegExp(r'[\s-]'), '');

  /// What:   Account-length hint for the field.
  /// Output: e.g. "12 digits"; "8 to 17 digits" when the bank has no fixed lengths.
  String get lengthHint => '${lengths?.join(' or ') ?? '8 to 17'} digits';

  /// What:   Validates an account number for this bank.
  /// Input:  [accountNumber] as typed (cleaned first).
  /// Output: An error message, or null when it fits.
  /// How:    Digits only; length must be in [lengths], else 8 to 17 when the bank has none.
  String? checkAccount(String accountNumber) {
    final number = clean(accountNumber);
    if (number.isEmpty) return 'Enter your account number.';
    if (!RegExp(r'^\d+$').hasMatch(number)) return 'Use digits only.';
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
