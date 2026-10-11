// SSM document extraction. Parsing is deterministic and runs here: no LLM or
// third-party API sees the document (it may carry the owner's NRIC, date of
// birth and home address), and the verdict is only proposals for the client to
// confirm. Exports extractSsmDocument (re-exported by index.js) and
// deleteSsmDocument (called by onVerificationDecided).

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
// Modular import: `admin.firestore.FieldValue` reads as undefined once the
// Functions emulator proxies the admin SDK.
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
 * An ALL-CAPS label plus its colon. The Business Profile has two columns, so
 * flattening can glue a left label onto a right value; strip it, don't match it.
 */
const RE_LABEL = /^[A-Z][A-Z0-9 .&/'-]{2,40}\s*:\s*/;

/** Closed-vocabulary fields: a keyword scan doesn't depend on column layout. */
const RE_STATUS = /\b(ACTIVE|AKTIF|DISSOLVED|TERMINATED|EXPIRED)\b/;
const RE_OWNERSHIP = /\b(SOLE PROPRIETORSHIP|PARTNERSHIP|BODY CORPORATE)\b/;

/** Layout markings a genuine SSM printout carries. Forgeable, but free. */
const RE_MARKERS = /MENARA SSM|SSM@SENTRAL|REGISTRATION NO|SISTEM EZBIZ|e-?Info/i;

const MONTHS = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};

/**
 * What:   Date parser for the two shapes SSM prints.
 * Input:  Text with `08-10-2020` (Business Profile) or `22 JANUARY 2027`
 *         (Certificate).
 * Output: `YYYY-MM-DD`, or null when there is no usable year.
 * Notes:  Never guesses, so a half-read date can't reject a valid registration.
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

/**
 * What:   Canonical registration number.
 * Input:  Any text.
 * Output: Upper-case letters and digits only; mirrors `SsmNumber.normalized`
 *         in the Dart client.
 */
function canonical(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

/**
 * What:   Reader for an SSM Certificate of Registration or Business Profile.
 * Input:  The PDF's text.
 * Output: {businessName, registrationNumber, legacyNumber, expiryDate,
 *         businessStartDate, natureOfBusiness, entityStatus, ownership}.
 * How:    The name is the line above the registration number, which holds in
 *         both layouts. Owner sections (NRIC, DOB, address) are split off first
 *         and never read.
 * Notes:  That split depends on SSM printing the owner heading; ssm.test.js
 *         pins it, so a layout change is a privacy regression to re-test.
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

  // Everything below reads only the business section.
  const business = text.split(/INFORMATION OF (?:CURRENT|PREVIOUS) OWNER/i)[0];

  // A Certificate states its expiry in prose.
  const until = business.match(/registered\s+until\s+(.{3,40}?)\s+in\s+accordance/i);
  out.expiryDate = parseDate(until && until[1]);

  // A Business Profile lists start, registration, expiry, last amendment in
  // that order, but flattening separates the dates from their labels, so the
  // order is the only handle. Gated on the label block being present.
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
 * Detects text that is in the PDF but invisible on the page (white or tiny
 * text), which could hide a legitimate registration number from a human.
 * Structural giveaways only; no rasteriser.
 */
function looksHidden(buffer) {
  const raw = buffer.toString("latin1");
  // `Tr 3` is invisible text; legitimate only in OCR'd scans, rejected anyway.
  if (/\b3\s+Tr\b/.test(raw)) return true;
  // A font under ~4pt is unreadable by a human but extracts perfectly.
  const sizes = raw.match(/\/F\d+\s+([\d.]+)\s+Tf/g) || [];
  for (const decl of sizes) {
    const size = parseFloat(decl.match(/\s([\d.]+)\s+Tf/)[1]);
    if (size > 0 && size < 4) return true;
  }
  // Unicode tag block: invisible characters used to smuggle instructions.
  if (/\uDB40[\uDC00-\uDC7F]/.test(buffer.toString("utf8"))) return true;
  return false;
}

/**
 * What:   Reader for the current owner's name on a Business Profile.
 * Input:  The PDF's text.
 * Output: The name, or null. It is compared, then thrown away; nothing else
 *         from the owner section is read.
 * Notes:  A Certificate names no owner, so only a Profile links the uploader
 *         to the business.
 */
function parseOwnerName(text) {
  const lines = text.split("\n");
  const start = lines.findIndex(
      (line) => /INFORMATION OF CURRENT OWNER/i.test(line));
  if (start < 0) return null;
  // The name is the first value; the address after it starts with a number.
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
 * What:   Fuzzy name comparison.
 * Input:  Two names.
 * Output: True/false, or null when either is unusable ("can't tell" is not "no").
 * How:    Token sets, 60% overlap of the shorter one, so punctuation, word
 *         order, bin/binti and middle names don't matter.
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
 * The Certificate branch's identity fields, blanked. Writes merge so the
 * Profile's fields survive, so a rejected re-upload would otherwise leave the
 * old name and number beside the new "rejected" verdict.
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

/**
 * What:   Storage trigger that checks an uploaded SSM PDF.
 * Input:  verification/{uid}/ssm_document_* or ssm_profile_* uploads.
 * Output: Verdict + proposed business fields in users/{uid}/private/ssmExtract.
 * Notes:  A Business Profile is read only for the owner-name match. Files are
 *         deleted later, once an admin rules (deleteSsmDocument).
 */
exports.extractSsmDocument = functions
    .runWith({memory: "512MB", timeoutSeconds: 120})
    .storage.object().onFinalize(async (object) => {
      const path = object.name || "";
      const match = path.match(SSM_PATH);
      if (!match) return;
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

      // 1. Magic bytes by a 16-byte ranged read. `contentType` is client-
      //    supplied, so this is the first point the type is known.
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

      // 2. Text layer: a genuine e-Info/EzBiz PDF is text; a photo or re-scan
      //    has nothing to read.
      let text = "";
      try {
        text = (await pdfParse(buffer)).text || "";
      } catch (_err) {
        functions.logger.info("ssm pdf-parse failed", {uid});
      }
      const hasTextLayer = text.replace(/\s/g, "").length > 200;

      // The optional Profile answers one question (is the applicant the
      // registered owner?) and is deleted at once; it holds an NRIC, a date of
      // birth and a home address.
      if (isProfile) {
        // It alone states the business status, expiry, ownership type and
        // nature of business: business facts, kept as onboarding autofill.
        const profile = parseSsmText(text);
        const account = await admin.firestore().doc(`users/${uid}`).get();
        const matches = namesMatch(
            parseOwnerName(text), account.get("displayName"));

        // Merged: the Certificate owns `verdict`/`failures`; the Profile only
        // fills fields the Certificate could not supply.
        const add = (key, value) => value ? {[key]: value} : {};
        await ref.set({
          ownerNameMatches: matches,
          // Pinned to the business it was computed for, so a later
          // certificate for another business doesn't inherit "Owner confirmed".
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

      // 3. Cross-check against the number the applicant typed.
      const privateSnap = await admin.firestore()
          .doc(`users/${uid}/private/verification`).get();
      const typed = canonical(privateSnap.get("ssmNumber"));

      // Keep an owner check only when this certificate is for the same
      // registration number; otherwise clear it.
      const existing = (await ref.get()).data() || {};
      const ownerStillValid = !!existing.ownerCheckedFor &&
          existing.ownerCheckedFor === found;
      const ownerFields = ownerStillValid ? {} : BLANK_OWNER;

      // A signature is only detected, not verified: most uploads are
      // re-prints, so this routes to a human rather than blocking.
      const signaturePresent = buffer.includes("/ByteRange");

      const failures = [];
      if (!hasTextLayer) failures.push("no-text-layer");
      if (!found) failures.push("no-registration-number");
      if (typed && found && typed !== found) failures.push("number-mismatch");
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
 * What:   Deletes the applicant's uploaded SSM certificates.
 * Input:  [uid]; called by onVerificationDecided.
 * Output: Every `ssm_document_*` file and `ssmDocumentUrl` removed.
 * Notes:  Runs after an admin rules (PDPA s.10), not at extraction, so the
 *         queue still has something to review. Best-effort: never blocks a
 *         recorded decision.
 */
exports.deleteSsmDocument = async (uid) => {
  const db = admin.firestore();
  try {
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

// Exported for tests.
exports.parseSsmText = parseSsmText;
exports.parseDate = parseDate;
exports.parseOwnerName = parseOwnerName;
exports.namesMatch = namesMatch;
exports.canonical = canonical;
