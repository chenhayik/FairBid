/**
 * SSM document extraction (smart signup).
 *
 * Fires on every `verification/{uid}/ssm_document_*` upload: confirms the file
 * really is a PDF, reads the business name and registration number out of it,
 * runs the cheap authenticity checks, and writes a verdict to the applicant's
 * owner+admin-only `users/{uid}/private/ssmExtract` document.
 *
 * Three deliberate properties:
 *
 *  1. **Nothing leaves the project.** Parsing is deterministic and runs here.
 *     No LLM, no third-party API, so no cross-border transfer of a document
 *     that may carry the owner's NRIC, date of birth, race and home address.
 *     It is also immune to text hidden in the PDF instructing a model.
 *  2. **Nothing is written to the public profile.** The verdict is a set of
 *     proposals; the client renders them for the applicant to confirm.
 *  3. **The source file is deleted once read.** Only the handful of extracted
 *     fields are kept - see `deleteAfterExtract` below.
 *
 * Lives in its own module because index.js is already long; re-exported there
 * the same way `trust.js` is.
 */

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
// Imported modularly rather than via the `admin.firestore.FieldValue`
// namespace: that legacy accessor reads as undefined once the Functions
// emulator proxies the admin SDK, which fails the trigger at runtime while
// looking perfectly correct in review.
const {FieldValue} = require("firebase-admin/firestore");
const pdfParse = require("pdf-parse");

/** "%PDF-" - the only file signature accepted under the SSM path. */
const PDF_MAGIC = Buffer.from([0x25, 0x50, 0x44, 0x46, 0x2d]);

/** Matches the two upload kinds this trigger owns. */
const SSM_PATH = /^verification\/([^/]+)\/ssm_(document|profile)_/;

/** Registration numbers as SSM prints them, in both live formats. */
const RE_CURRENT = /\b((?:19|20)\d{2}0[1-6]\d{6})\b/;
const RE_LEGACY = /\b([A-Z]{0,2}\d{5,9}\s*-\s*[A-Z])\b/;

/**
 * Any ALL-CAPS label plus its colon gutter. The Business Profile is laid out in
 * two columns, and flattening it can glue a label from the left column onto a
 * value from the right one ("PRINCIPLE PLACE OF BUSINESS   : SUNMAL DENTAL
 * ART"), so the label has to be stripped rather than matched.
 */
const RE_LABEL = /^[A-Z][A-Z0-9 .&/'-]{2,40}\s*:\s*/;

/**
 * Closed-vocabulary fields. A keyword scan beats label parsing outright here,
 * because it does not depend on the columns lining up at all.
 */
const RE_STATUS = /\b(ACTIVE|AKTIF|DISSOLVED|TERMINATED|EXPIRED)\b/;
const RE_OWNERSHIP = /\b(SOLE PROPRIETORSHIP|PARTNERSHIP|BODY CORPORATE)\b/;

/** Layout markings a genuine SSM printout carries. Forgeable, but free. */
const RE_MARKERS = /MENARA SSM|SSM@SENTRAL|REGISTRATION NO|SISTEM EZBIZ|e-?Info/i;

/** Month names as SSM prints them on a Certificate of Registration. */
const MONTHS = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};

/**
 * Parses the two date shapes SSM prints - `08-10-2020` on a Business Profile
 * and `22 JANUARY 2027` on a Certificate - into a plain `YYYY-MM-DD` string.
 *
 * Returns null when there is no usable year rather than guessing one. That
 * matters: an expiry date is only ever acted on when it parsed cleanly, so a
 * half-read date can never wrongly reject a valid registration.
 */
function parseDate(raw) {
  if (!raw) return null;
  const iso = (y, m, d) => (m < 1 || m > 12 || d < 1 || d > 31) ? null :
      `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;

  const numeric = raw.match(/\b(\d{1,2})-(\d{1,2})-(\d{4})\b/);
  if (numeric) return iso(+numeric[3], +numeric[2], +numeric[1]);

  const named = raw.match(/\b(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})\b/);
  if (named) {
    const month = MONTHS[named[2].toUpperCase()];
    if (month) return iso(+named[3], month, +named[1]);
  }
  return null;
}

/** Canonical form, mirroring `SsmNumber.normalized` in the Dart client. */
function canonical(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

/**
 * Reads an SSM Certificate of Registration or Business Profile.
 *
 * The two document types label their fields differently, but both print the
 * business name on the line immediately above the registration number - so the
 * name is anchored to the number rather than to a label, and one rule covers
 * both layouts.
 *
 * Deliberately reads nothing else. A Business Profile also carries the owner's
 * NRIC, date of birth, race, gender and residential address; not reading them
 * is both cheaper and safer than reading and discarding them.
 */
function parseSsmText(text) {
  const lines = text.split("\n").map((line) => line.replace(/\s+$/, ""));
  const out = {
    businessName: null,
    registrationNumber: null,
    legacyNumber: null,
    expiryDate: null,
    businessStartDate: null,
    natureOfBusiness: null,
  };

  for (let i = 0; i < lines.length; i++) {
    const found = lines[i].match(RE_CURRENT);
    if (!found) continue;
    out.registrationNumber = found[1];
    const legacy = lines[i].match(RE_LEGACY);
    out.legacyNumber = legacy ? legacy[1].replace(/\s+/g, "") : null;

    for (let j = i - 1; j >= 0; j--) {
      const line = lines[j].trim();
      if (!line) continue;
      const name = line.replace(RE_LABEL, "").replace(/^:\s*/, "").trim();
      if (name.length >= 3 && !RE_CURRENT.test(name)) out.businessName = name;
      break; // nearest non-blank line only - never wander up the page
    }
    break;
  }

  const status = text.match(RE_STATUS);
  const ownership = text.match(RE_OWNERSHIP);
  out.entityStatus = status ? status[1] : null;
  out.ownership = ownership ? ownership[1] : null;

  // Everything below reads only the business section. Splitting the owner
  // sections off first means a date of birth can never be mistaken for a
  // business date, and keeps the owner's NRIC, DOB, race and home address out
  // of everything this function returns.
  //
  // Note the limit of that guarantee: it depends on SSM printing the heading
  // below. A profile that reworded or omitted it would leave `business` as the
  // whole document. The guard is pinned by ssm.test.js rather than being
  // structural, so treat a layout change as a privacy regression to re-test.
  const business = text.split(/INFORMATION OF (?:CURRENT|PREVIOUS) OWNER/i)[0];

  // A Certificate of Registration states its expiry in prose.
  const until = business.match(/registered\s+until\s+(.{3,40}?)\s+in\s+accordance/i);
  out.expiryDate = parseDate(until && until[1]);

  // A Business Profile lists its dates in a fixed order - start, registration,
  // expiry, last amendment - but the two-column layout separates them from
  // their labels when flattened, so they cannot be matched by label. The order
  // is the only reliable handle, and it is gated on the label block actually
  // being present so this never misfires on some other document.
  if (/BUSINESS EXPIRY DATE/i.test(business)) {
    const dates = (business.match(/\b\d{2}-\d{2}-\d{4}\b/g) || []);
    if (dates.length >= 3) {
      out.businessStartDate = parseDate(dates[0]);
      out.expiryDate = out.expiryDate || parseDate(dates[2]);
    }
  }

  // Nature of business sits on its own under a BUSINESS TYPE heading.
  const typeIndex = lines.findIndex((line) => /BUSINESS TYPE/i.test(line));
  if (typeIndex >= 0) {
    for (let j = typeIndex + 1; j < lines.length; j++) {
      const line = lines[j].trim();
      if (!line) continue;
      if (/BRANCH|INFORMATION|^\*|^User ID/i.test(line)) break;
      out.natureOfBusiness = line;
      break;
    }
  }
  return out;
}

/**
 * Cheap detector for text that is present in the PDF but invisible on the page.
 *
 * This matters even though no model is involved: the parser above reads the
 * text layer, so an attacker could hide a legitimate business's registration
 * number in white-on-white or 1pt text, type that number into the form, and
 * pass the cross-check. A full check renders the page and diffs it against the
 * text layer; these are the structural giveaways that need no rasteriser.
 */
function looksHidden(buffer) {
  const raw = buffer.toString("latin1");
  // `Tr 3` is the PDF invisible text-rendering mode - legitimate only in
  // OCR'd scans, which are rejected by the text-layer check anyway.
  if (/\b3\s+Tr\b/.test(raw)) return true;
  // A font set below ~4pt is unreadable by a human but extracts perfectly.
  const sizes = raw.match(/\/F\d+\s+([\d.]+)\s+Tf/g) || [];
  for (const decl of sizes) {
    const size = parseFloat(decl.match(/\s([\d.]+)\s+Tf/)[1]);
    if (size > 0 && size < 4) return true;
  }
  // Unicode tag block - invisible characters used to smuggle instructions.
  if (/\uDB40[\uDC00-\uDC7F]/.test(buffer.toString("utf8"))) return true;
  return false;
}

/**
 * Reads ONLY the current owner's name out of a Business Profile.
 *
 * This is the single field that links the uploader to the business - a
 * Certificate of Registration names no one, so a genuine certificate proves a
 * business exists but not that this applicant is entitled to it.
 *
 * The name is compared and then thrown away; it is never persisted, and
 * nothing else from the owner section (NRIC, date of birth, race, gender,
 * residential address) is read at all.
 */
function parseOwnerName(text) {
  const lines = text.split("\n");
  const start = lines.findIndex(
      (line) => /INFORMATION OF CURRENT OWNER/i.test(line));
  if (start < 0) return null;
  // The name is the first value in the section. The address that follows
  // starts with a house number, so the leading-letter test skips it.
  for (let i = start + 1; i < Math.min(start + 12, lines.length); i++) {
    const value = lines[i].match(/:\s*(.+?)\s*$/);
    if (!value) continue;
    const candidate = value[1].trim();
    if (candidate.length >= 3 && /^[A-Z][A-Z .'/-]+$/.test(candidate)) {
      return candidate;
    }
  }
  return null;
}

/**
 * Whether two names plausibly describe the same person. Returns null when
 * either side is unusable, so "could not tell" stays distinct from "no".
 *
 * Compares token sets rather than strings: SSM prints "TAN XIAO-IAN" while an
 * account might read "Tan Xiao Ian", and Malaysian names carry bin/binti and
 * optional middle names that an exact match would reject outright.
 */
function namesMatch(a, b) {
  const tokens = (value) => new Set(String(value || "").toUpperCase()
      .replace(/[^A-Z ]/g, " ").split(/\s+/).filter((t) => t.length > 1));
  const first = tokens(a);
  const second = tokens(b);
  if (!first.size || !second.size) return null;
  const [fewer, more] = first.size <= second.size ?
      [first, second] : [second, first];
  let hits = 0;
  for (const token of fewer) if (more.has(token)) hits++;
  return hits / fewer.size >= 0.6;
}

/**
 * The identity fields the Certificate branch owns, blanked. Writes use
 * `merge: true` so the optional Profile's contributions survive, which means a
 * rejected re-upload would otherwise leave the previous document's name and
 * number sitting beside the new "rejected" verdict.
 */
const BLANK_CERT = {
  registrationNumber: null,
  legacyNumber: null,
  businessName: null,
  signaturePresent: false,
};

/** The owner check, cleared. See `ownerCheckedFor`. */
const BLANK_OWNER = {ownerNameMatches: null, ownerCheckedFor: null};

/** Failures that mean the document is unusable, rather than merely unproven. */
const HARD_FAILURES = [
  "not-a-pdf",
  "registration-expired",
  "hidden-text",
  "no-text-layer",
  "no-registration-number",
  "number-mismatch",
];

exports.extractSsmDocument = functions
    .runWith({memory: "512MB", timeoutSeconds: 120})
    .storage.object().onFinalize(async (object) => {
      const path = object.name || "";
      const match = path.match(SSM_PATH);
      if (!match) return; // not an SSM upload
      const uid = match[1];
      const isProfile = match[2] === "profile";

      const file = admin.storage().bucket(object.bucket).file(path);
      const ref = admin.firestore().doc(`users/${uid}/private/ssmExtract`);

      const write = (verdict, failures, fields) => ref.set({
        verdict,
        failures,
        storagePath: path,
        at: FieldValue.serverTimestamp(),
        ...fields,
      }, {merge: true});

      // 1. Magic bytes: a ranged read, so this costs ~16 bytes rather than the
      //    whole file. `contentType` is client-supplied and Cloud Storage never
      //    sniffs it, so this is the first point at which the type is known.
      const [head] = await file.download({start: 0, end: 15});
      if (!head.subarray(0, PDF_MAGIC.length).equals(PDF_MAGIC)) {
        await write("rejected", ["not-a-pdf"], {...BLANK_CERT, ...BLANK_OWNER});
        return;
      }

      const [buffer] = await file.download();

      if (looksHidden(buffer)) {
        await write("rejected", ["hidden-text"],
            {...BLANK_CERT, ...BLANK_OWNER});
        return;
      }

      // 2. Text layer. A genuine e-Info/EzBiz PDF is text-based; a photo or a
      //    re-scan is a raster with nothing to read. Cheap, and one of the more
      //    effective signals available short of checking the signature.
      let text = "";
      try {
        text = (await pdfParse(buffer)).text || "";
      } catch (_err) {
        functions.logger.info("ssm pdf-parse failed", {uid});
      }
      const hasTextLayer = text.replace(/\s/g, "").length > 200;

      // The Business Profile is optional and answers exactly one question:
      // is the applicant the registered owner? It is the only document here
      // carrying an NRIC, a date of birth and a home address, so it is read
      // for that one boolean and deleted immediately - a human never sees it,
      // because the machine has already answered the only thing it is for.
      if (isProfile) {
        // The Profile is the richer document: it alone states the business
        // status, expiry, ownership type and nature of business. Those are
        // business facts, not personal data, so they are kept and offered as
        // autofill for the later onboarding stages.
        const profile = parseSsmText(text);
        const account = await admin.firestore().doc(`users/${uid}`).get();
        const matches = namesMatch(
            parseOwnerName(text), account.get("displayName"));

        // Merged, never overwriting. The Certificate is the required document
        // and owns `verdict`/`failures`; the Profile only ever adds to them,
        // and only fills fields the Certificate could not supply.
        const add = (key, value) => value ? {[key]: value} : {};
        await ref.set({
          ownerNameMatches: matches,
          // Pinned to the business it was computed for. Without this a Profile
          // for one business keeps showing "Owner confirmed" beside a
          // certificate later uploaded for a different one.
          ownerCheckedFor: canonical(profile.registrationNumber),
          ownerCheckedAt: FieldValue.serverTimestamp(),
          ...add("entityStatus", profile.entityStatus),
          ...add("ownership", profile.ownership),
          ...add("expiryDate", profile.expiryDate),
          ...add("businessStartDate", profile.businessStartDate),
          ...add("natureOfBusiness", profile.natureOfBusiness),
        }, {merge: true});
        await file.delete({ignoreNotFound: true}).catch(() => {
          functions.logger.warn("ssm profile delete failed", {uid});
        });
        return;
      }

      const parsed = parseSsmText(text);
      const found = canonical(parsed.registrationNumber);

      // 3. Cross-check against what the applicant typed. The number lives in
      //    the private document, not on the public profile.
      const privateSnap = await admin.firestore()
          .doc(`users/${uid}/private/verification`).get();
      const typed = canonical(privateSnap.get("ssmNumber"));

      // An owner check belongs to the business it was run against. Keep it only
      // when this certificate is for that same registration number; otherwise
      // clear it rather than let a stale "Owner confirmed" ride along.
      const existing = (await ref.get()).data() || {};
      const ownerStillValid = !!existing.ownerCheckedFor &&
          existing.ownerCheckedFor === found;
      const ownerFields = ownerStillValid ? {} : BLANK_OWNER;

      // A signature is not verified yet - only detected. Most uploads today
      // are re-prints, so this routes to a human rather than blocking.
      const signaturePresent = buffer.includes("/ByteRange");

      const failures = [];
      if (!hasTextLayer) failures.push("no-text-layer");
      if (!found) failures.push("no-registration-number");
      if (typed && found && typed !== found) failures.push("number-mismatch");
      // Only ever acted on when the date parsed cleanly - see parseDate.
      const today = new Date().toISOString().slice(0, 10);
      if (parsed.expiryDate && parsed.expiryDate < today) {
        failures.push("registration-expired");
      }
      if (!RE_MARKERS.test(text)) failures.push("missing-ssm-markers");
      if (!signaturePresent) failures.push("not-digitally-signed");

      const verdict = failures.length === 0 ? "passed" :
          failures.some((f) => HARD_FAILURES.includes(f)) ?
              "rejected" : "needsReview";

      await write(verdict, failures, {
        // Proposals only; the client shows these for confirmation.
        registrationNumber: parsed.registrationNumber,
        legacyNumber: parsed.legacyNumber,
        businessName: parsed.businessName,
        entityStatus: parsed.entityStatus,
        ownership: parsed.ownership,
        expiryDate: parsed.expiryDate,
        businessStartDate: parsed.businessStartDate,
        natureOfBusiness: parsed.natureOfBusiness,
        signaturePresent,
        ...ownerFields,
      });
    });

/**
 * Deletes the applicant's uploaded SSM document and forgets where it was.
 *
 * Called from `onVerificationDecided` rather than from the extractor: an
 * SSM Business Profile carries the owner's NRIC, date of birth and home
 * address, and PDPA s.10 requires destruction once the purpose is served - but
 * that purpose is not served until a human has reviewed it. Deleting at
 * extraction time would leave the admin queue with nothing to look at, which is
 * exactly the fallback the automated checks depend on.
 *
 * Best-effort throughout: a failure here must never block a verification
 * decision that has already been recorded.
 */
exports.deleteSsmDocument = async (uid) => {
  const db = admin.firestore();
  try {
    // Every certificate this applicant uploaded, not only the most recent:
    // `storagePath` is overwritten on each re-upload, so keying the delete off
    // it alone stranded the earlier files in Storage for good.
    const [files] = await admin.storage().bucket()
        .getFiles({prefix: `verification/${uid}/ssm_document_`});
    await Promise.all(
        files.map((file) => file.delete({ignoreNotFound: true})));
    await db.doc(`users/${uid}/private/verification`).set({
      ssmDocumentUrl: FieldValue.delete(),
    }, {merge: true});
  } catch (_err) {
    functions.logger.warn("ssm document cleanup failed", {uid});
  }
};

// Exported for unit testing without a Storage emulator.
exports.parseSsmText = parseSsmText;
exports.parseDate = parseDate;
exports.parseOwnerName = parseOwnerName;
exports.namesMatch = namesMatch;
exports.looksHidden = looksHidden;
exports.canonical = canonical;
