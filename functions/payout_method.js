// Where a provider's withdrawals go: a DuitNow ID or a bank account.
// Demo only: no real bank or payout API is ever called.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {callerUid, bad, throwIfSuspended, notifyUser} = require("./common");

// Must match lib/core/util/malaysian_banks.dart. Lengths are account digits.
const BANKS = [
  {swift: "MBBEMYKL", name: "Maybank", lengths: [12]},
  {swift: "CIBBMYKL", name: "CIMB Bank", lengths: [10, 14]},
  {swift: "PBBEMYKL", name: "Public Bank", lengths: [10]},
  {swift: "RHBBMYKL", name: "RHB Bank", lengths: [14]},
  {swift: "HLBBMYKL", name: "Hong Leong Bank", lengths: [11, 12, 13]},
  {swift: "ARBKMYKL", name: "AmBank", lengths: null},
  {swift: "BIMBMYKL", name: "Bank Islam", lengths: null},
  {swift: "BKRMMYKL", name: "Bank Rakyat", lengths: null},
  {swift: "BSNAMYK1", name: "BSN", lengths: null},
  {swift: "PHBMMYKL", name: "Affin Bank", lengths: null},
  {swift: "MFBBMYKL", name: "Alliance Bank", lengths: null},
  {swift: "OCBCMYKL", name: "OCBC Bank", lengths: null},
  {swift: "UOVBMYKL", name: "UOB Malaysia", lengths: null},
  {swift: "HBMBMYKL", name: "HSBC Malaysia", lengths: null},
  {swift: "SCBLMYKX", name: "Standard Chartered", lengths: null},
  {swift: "BMMBMYKL", name: "Bank Muamalat", lengths: null},
  {swift: "AGOBMYKL", name: "Agrobank", lengths: null},
];

// Banks without a known length accept any typical account number length.
const GENERIC_LENGTH = {min: 8, max: 17};

// New or changed payout details wait this long before a withdrawal.
const HOLD_MS = 24 * 60 * 60 * 1000;

/**
 * What:   Digit extractor.
 * Input:  Any [value].
 * Output: Its digits only, as a string.
 */
const digits = (value) => String(value || "").replace(/\D/g, "");

/**
 * What:   Mobile number normaliser.
 * Input:  Any phone text (+60, spaces, dashes).
 * Output: `01XXXXXXXX(X)`, or null when it isn't a Malaysian mobile.
 */
function normaliseMobile(value) {
  let d = digits(value);
  if (d.startsWith("60")) d = d.slice(1);
  return /^01\d{8,9}$/.test(d) ? d : null;
}

/**
 * What:   Mobile number mask.
 * Input:  A normalised mobile number.
 * Output: e.g. `012-•••• 678`: enough to recognise, not enough to reuse.
 */
function maskMobile(mobile) {
  return `${mobile.slice(0, 3)}-•••• ${mobile.slice(-3)}`;
}

/**
 * What:   Bank account check.
 * Input:  Bank [swift] code and [accountNumber].
 * Output: {bank, last4}; throws `invalid-argument` for an unknown bank, a
 *         non-digit number or a length the bank doesn't use.
 */
function checkBankAccount(swift, accountNumber) {
  const bank = BANKS.find((b) => b.swift === swift);
  if (!bank) throw bad("Pick your bank from the list.");
  const number = digits(accountNumber);
  if (number !== String(accountNumber || "").trim()) {
    throw bad("The account number should only have digits.");
  }
  const ok = bank.lengths ?
      bank.lengths.includes(number.length) :
      number.length >= GENERIC_LENGTH.min &&
          number.length <= GENERIC_LENGTH.max;
  if (!ok) {
    throw bad(bank.lengths ?
        `${bank.name} account numbers have ${bank.lengths.join(" or ")} ` +
            "digits." :
        "That account number doesn't look right. Check it and try again.");
  }
  return {bank, last4: number.slice(-4)};
}

/**
 * What:   Builds the stored payout method.
 * Input:  The request [data] and {phone, ssmNumber, isBusiness} from the profile.
 * Output: The fields to store (`method`, `masked`, ...); throws `invalid-argument`.
 * Notes:  DuitNow IDs always come from the profile, never from the app.
 */
function buildPayoutMethod(data, {phone, ssmNumber, isBusiness}) {
  const method = data?.method;
  if (method === "bank") {
    const {bank, last4} = checkBankAccount(data.bankSwift, data.accountNumber);
    return {
      method,
      proxyType: null,
      bankName: bank.name,
      bankSwift: bank.swift,
      masked: `${bank.name} •••• ${last4}`,
    };
  }
  if (method !== "duitnow") throw bad("Pick DuitNow or a bank account.");
  const base = {method, bankName: null, bankSwift: null};
  switch (data.proxyType) {
    case "mobile": {
      const mobile = normaliseMobile(phone);
      if (!mobile) {
        throw bad("Add your Malaysian mobile number to your profile first.");
      }
      // Kept server-side so a withdrawal can check the profile still matches.
      return {...base, proxyType: "mobile", mobile,
        masked: `DuitNow ${maskMobile(mobile)}`};
    }
    case "brn": {
      const brn = digits(ssmNumber);
      if (!isBusiness || brn.length < 4) {
        throw bad("Only business accounts with an SSM number can use this.");
      }
      return {...base, proxyType: "brn",
        masked: `DuitNow SSM •••• ${brn.slice(-4)}`};
    }
    default:
      throw bad("Pick which DuitNow ID to use.");
  }
}

/**
 * What:   Callable that saves the caller's payout method.
 * Input:  {method, ...} from WalletRepository.savePayoutMethod().
 * Output: Writes `private/payoutMethod`; a change (not the first setup) starts a
 *         24-hour withdrawal hold and notifies the user.
 */
exports.savePayoutMethod = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const db = admin.firestore();
  const userRef = db.doc(`users/${uid}`);
  const methodRef = userRef.collection("private").doc("payoutMethod");

  await db.runTransaction(async (tx) => {
    const [userSnap, payoutSnap, verificationSnap, existing] =
        await tx.getAll(
            userRef,
            userRef.collection("private").doc("payout"),
            userRef.collection("private").doc("verification"),
            methodRef);
    const user = userSnap.data() || {};
    if (user.role !== "provider" && user.role !== "requestor") {
      throw new functions.https.HttpsError(
          "permission-denied", "Admins don't have a payout method.");
    }
    throwIfSuspended(user);
    const built = buildPayoutMethod(data, {
      // Older accounts still keep the phone on the public doc.
      phone: payoutSnap.data()?.phone ?? user.phone,
      ssmNumber: verificationSnap.data()?.ssmNumberNormalized,
      isBusiness: user.onboarding?.providerType === "business",
    });
    const now = Date.now();
    tx.set(methodRef, {
      ...built,
      // Always the verified profile name, never typed in.
      holderName: user.displayName || "",
      availableAt: Timestamp.fromMillis(existing.exists ? now + HOLD_MS : now),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (existing.exists) {
      notifyUser(tx, uid, {
        type: "account",
        title: "Payout method changed",
        body: `Withdrawals now go to ${built.masked}, from 24 hours ` +
            "from now. If this wasn't you, change your password.",
        route: "/profile/earnings",
      });
    }
  });
});

// Exported for tests and the withdraw check in index.js.
exports.normaliseMobile = normaliseMobile;
exports.checkBankAccount = checkBankAccount;
exports.buildPayoutMethod = buildPayoutMethod;
