// MyKad ID check (advisory; an admin still decides). The verdict never holds
// the name, DOB, full IC, religion or address - only a masked IC and booleans.
// Duplicate detection stores only an HMAC of the IC in `idRegistry`.

const crypto = require("node:crypto");
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue} = require("firebase-admin/firestore");
const {defineSecret} = require("firebase-functions/params");
const {
  normalizeIc, validateIc, maskIc, todayInKl, parseMyKadText,
} = require("./mykad");
const {namesMatch} = require("./ssm");

const icPepper = defineSecret("IC_PEPPER");

const ID_PATH = /^verification\/([^/]+)\/id_document_/;
const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff]);
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

/** Failures that mean the card is unusable, rather than merely unproven. */
const HARD_FAILURES = [
  "not-an-image", "no-ic-found", "invalid-ic", "underage", "ic-mismatch",
  "duplicate-ic",
];

/**
 * What:   Verdict from a list of failure codes.
 * Input:  [failures] (strings).
 * Output: "passed", "rejected" (any hard failure) or "needsReview".
 */
function verdictFor(failures) {
  if (failures.length === 0) return "passed";
  return failures.some((f) => HARD_FAILURES.includes(f)) ?
      "rejected" : "needsReview";
}

/**
 * What:   Registry key for an IC.
 * Input:  An IC number and the secret [pepper].
 * Output: Hex HMAC-SHA256 of the normalised IC; the pepper keeps it unguessable.
 */
function icKey(ic, pepper) {
  return crypto.createHmac("sha256", pepper).update(normalizeIc(ic))
      .digest("hex");
}

let visionClient;
/** Lazily created so requiring this module stays cheap and offline. */
function vision() {
  if (!visionClient) {
    const {ImageAnnotatorClient} = require("@google-cloud/vision");
    visionClient = new ImageAnnotatorClient();
  }
  return visionClient;
}

/**
 * Looks the IC up in `idRegistry`; with `reserve`, claims it for [uid] and
 * drops any older claim. Returns true when another account holds the typed or
 * OCR IC.
 */
function checkRegistry(uid, typed, ocrIc, reserve, pepper) {
  const db = admin.firestore();
  const keys = [...new Set([typed, ocrIc].filter((ic) => ic.length === 12)
      .map((ic) => icKey(ic, pepper)))];
  if (!keys.length) return Promise.resolve(false);
  return db.runTransaction(async (tx) => {
    const snaps = await Promise.all(
        keys.map((k) => tx.get(db.doc(`idRegistry/${k}`))));
    if (snaps.some((s) => s.exists && s.get("uid") !== uid)) return true;
    if (!reserve) return false;
    const mine = await tx.get(
        db.collection("idRegistry").where("uid", "==", uid));
    const key = icKey(typed, pepper);
    mine.docs.filter((d) => d.id !== key).forEach((d) => tx.delete(d.ref));
    tx.set(db.doc(`idRegistry/${key}`),
        {uid, at: FieldValue.serverTimestamp()});
    return false;
  });
}

/**
 * What:   Storage trigger that checks an uploaded MyKad photo.
 * Input:  verification/{uid}/id_document_* uploads.
 * Output: Verdict in users/{uid}/private/idExtract from Cloud Vision OCR, the
 *         typed IC, the account name and the duplicate registry.
 */
exports.extractIdDocument = functions
    .runWith({memory: "512MB", timeoutSeconds: 120, secrets: [icPepper]})
    .storage.object().onFinalize(async (object) => {
      const path = object.name || "";
      const match = path.match(ID_PATH);
      if (!match) return;
      const uid = match[1];
      const db = admin.firestore();
      const ref = db.doc(`users/${uid}/private/idExtract`);

      const blank = {
        maskedIc: null, ageOk: null, nameMatches: null,
        genderConsistent: null, docType: "mykad",
      };
      // Set, not merge: each upload replaces the previous verdict.
      const write = (verdict, failures, fields) => ref.set({
        verdict,
        failures,
        storagePath: path,
        at: FieldValue.serverTimestamp(),
        ...blank,
        ...fields,
      });

      const [userSnap, privSnap] = await Promise.all([
        db.doc(`users/${uid}`).get(),
        db.doc(`users/${uid}/private/verification`).get(),
      ]);
      const typed = normalizeIc(privSnap.get("icNumber"));
      const typedMask = typed.length === 12 ? maskIc(typed) : null;

      if (userSnap.get("onboarding.idDocumentType") === "passport") {
        await write("needsReview", ["passport-not-automated"],
            {docType: "passport"});
        return;
      }

      const file = admin.storage().bucket(object.bucket).file(path);
      const [head] = await file.download({start: 0, end: 15});
      const isImage = [JPEG_MAGIC, PNG_MAGIC]
          .some((m) => head.subarray(0, m.length).equals(m));
      if (!isImage) {
        await write("rejected", ["not-an-image"], {maskedIc: typedMask});
        return;
      }

      let text;
      try {
        const [result] = await vision()
            .textDetection(`gs://${object.bucket}/${path}`);
        text = result.fullTextAnnotation?.text || "";
      } catch (err) {
        functions.logger.warn("id ocr failed", {uid, message: err.message});
        await write("needsReview", ["ocr-failed"], {maskedIc: typedMask});
        return;
      }

      const parsed = parseMyKadText(text);
      const ocr = validateIc(parsed.icNumber || "", todayInKl());
      const hasOcrIc = !!parsed.icNumber;
      const mismatch = !!typed && hasOcrIc && ocr.normalized !== typed;

      const dup = await checkRegistry(
          uid, typed, ocr.ok ? ocr.normalized : "",
          ocr.ok && !mismatch && ocr.normalized === typed, icPepper.value());

      const nameOk = namesMatch(parsed.name, userSnap.get("displayName"));
      const genderOk = parsed.gender && ocr.isMale !== null ?
          (parsed.gender === "male") === ocr.isMale : null;

      const failures = [];
      if (!hasOcrIc) failures.push("no-ic-found");
      if (hasOcrIc && ocr.issues.some((i) => i !== "underage")) {
        failures.push("invalid-ic");
      }
      if (ocr.issues.includes("underage")) failures.push("underage");
      if (mismatch) failures.push("ic-mismatch");
      if (dup) failures.push("duplicate-ic");
      if (nameOk !== true) failures.push("name-mismatch");
      if (genderOk === false) failures.push("gender-inconsistent");
      if (!parsed.hasMarkers) failures.push("missing-mykad-markers");
      if (ocr.pbNeedsReview) failures.push("unknown-pb-code");

      await write(verdictFor(failures), failures, {
        maskedIc: ocr.ok ? ocr.masked : typedMask,
        ageOk: ocr.dob ? !ocr.issues.includes("underage") : null,
        nameMatches: nameOk,
        genderConsistent: genderOk,
      });
    });

/**
 * What:   Deletes the applicant's ID photo, selfie and typed IC.
 * Input:  [uid]; called by onVerificationDecided.
 * Output: Files and the private fields removed; `idExtract`, `idRegistry` and
 *         `idConsentAt` (proof of consent) are kept.
 * Notes:  Best-effort: never blocks a recorded decision.
 */
exports.deleteIdDocuments = async (uid) => {
  try {
    const bucket = admin.storage().bucket();
    const lists = await Promise.all(["id_document_", "selfie_"].map(
        (p) => bucket.getFiles({prefix: `verification/${uid}/${p}`})));
    await Promise.all(lists.flatMap(([files]) =>
      files.map((f) => f.delete({ignoreNotFound: true}))));
    await admin.firestore().doc(`users/${uid}/private/verification`).set({
      idDocumentUrl: FieldValue.delete(),
      selfieUrl: FieldValue.delete(),
      icNumber: FieldValue.delete(),
      idFaceBox: FieldValue.delete(),
      selfieFaceBox: FieldValue.delete(),
    }, {merge: true});
  } catch (_err) {
    functions.logger.warn("id document cleanup failed", {uid});
  }
};

// Exported for tests.
exports.verdictFor = verdictFor;
exports.icKey = icKey;
