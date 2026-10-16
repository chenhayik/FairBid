// MyKad (Malaysian IC) validation: the JS twin of lib/core/util/mykad_number.dart,
// pinned to it by test/fixtures/mykad_vectors.json. Format YYMMDD-PB-###G with
// no checksum: only length, a real birth date, age >= 18 and a plausible
// place-of-birth code can be checked offline.

/**
 * What:   IC normaliser.
 * Input:  Any text.
 * Output: Its digits only.
 */
function normalizeIc(s) {
  return String(s ?? "").replace(/\D/g, "");
}

/**
 * What:   IC mask.
 * Input:  An IC number.
 * Output: `******-07-**27` (enough to recognise, not to reuse), or "" if not
 *         12 digits.
 */
function maskIc(ic) {
  const n = normalizeIc(ic);
  if (n.length !== 12) return "";
  return `******-${n.slice(6, 8)}-**${n.slice(10)}`;
}

/**
 * What:   Today's date in Asia/Kuala_Lumpur (UTC+8, no DST).
 * Input:  Optional [now] Date.
 * Output: `YYYY-MM-DD`.
 */
function todayInKl(now = new Date()) {
  return new Date(now.getTime() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

// Place-of-birth codes. Anything not listed is invalid.
const PB_REVIEW = new Set([80, 81, 94, 95, 96, 97]);

/**
 * What:   Place-of-birth code check.
 * Input:  The two-digit [pb] code as a number.
 * Output: True when it is a known code (including the PB_REVIEW ones).
 */
function pbIsValid(pb) {
  return (pb >= 1 && pb <= 16) || (pb >= 21 && pb <= 68) ||
    pb === 71 || pb === 72 || (pb >= 74 && pb <= 79) ||
    (pb >= 82 && pb <= 93) || pb === 98 || pb === 99 || PB_REVIEW.has(pb);
}

/**
 * What:   Date to a comparable number.
 * Input:  A `YYYY-MM-DD` string or a Date.
 * Output: A `YYYYMMDD` number.
 */
function dateKey(d) {
  const iso = d instanceof Date ? d.toISOString().slice(0, 10) : String(d);
  return Number(iso.replace(/-/g, ""));
}

/**
 * What:   Calendar check.
 * Input:  Year [y], month [m] (1-12) and day [d].
 * Output: True when the date exists (rejects e.g. 31 Feb).
 */
function isRealDate(y, m, d) {
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 &&
    dt.getUTCDate() === d;
}

/**
 * What:   Zero-padder.
 * Input:  Number [n] and width [w].
 * Output: [n] as a string left-padded with zeros.
 */
const pad = (n, w) => String(n).padStart(w, "0");

/**
 * What:   IC validator.
 * Input:  [ic] as typed; [today] as YYYY-MM-DD, normally todayInKl().
 * Output: {ok, issues, normalized, masked, dob, isMale, pbNeedsReview}; issues
 *         are wrong-length, invalid-date, invalid-pb-code, underage.
 * Notes:  Unknown place-of-birth codes are not an issue; they set pbNeedsReview.
 */
function validateIc(ic, today) {
  const normalized = normalizeIc(ic);
  const bad = {
    ok: false, issues: ["wrong-length"], normalized, masked: "", dob: null,
    isMale: null, pbNeedsReview: false,
  };
  if (normalized.length !== 12) return bad;

  const issues = [];
  const yy = Number(normalized.slice(0, 2));
  const mm = Number(normalized.slice(2, 4));
  const dd = Number(normalized.slice(4, 6));
  const pb = Number(normalized.slice(6, 8));
  const todayKey = dateKey(today);

  // 20YY unless that would be in the future.
  let year = 2000 + yy;
  if (year * 10000 + mm * 100 + dd > todayKey) year = 1900 + yy;

  let dob = null;
  if (isRealDate(year, mm, dd)) {
    dob = `${pad(year, 4)}-${pad(mm, 2)}-${pad(dd, 2)}`;
    if ((year + 18) * 10000 + mm * 100 + dd > todayKey) issues.push("underage");
  } else {
    issues.push("invalid-date");
  }
  if (!pbIsValid(pb)) issues.push("invalid-pb-code");
  // Keep a fixed order: date, pb, age.
  issues.sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));

  return {
    ok: issues.length === 0,
    issues,
    normalized,
    masked: maskIc(normalized),
    dob,
    isMale: Number(normalized[11]) % 2 === 1,
    pbNeedsReview: PB_REVIEW.has(pb),
  };
}

const ORDER = ["invalid-date", "invalid-pb-code", "underage"];

const RE_IC = /\b\d{6}\s*-?\s*\d{2}\s*-?\s*\d{4}\b/;
const RE_NAME_LINE = /^[A-Z][A-Z @'./-]*$/;
// Whole words that end the name block: card labels and address words.
const RE_STOP =
  /\b(KAD|PENGENALAN|MALAYSIA|MYKAD|IDENTITY|CARD|WARGANEGARA|LELAKI|PEREMPUAN|JALAN|JLN|LORONG|LRG|TAMAN|TMN|KAMPUNG|KG|LEBUH|LEBUHRAYA|PERSIARAN|BLOK|BLOCK|APARTMENT|PANGSAPURI|BATU|SEKSYEN|BANDAR|PEKAN|NO)\b/;
// Religion ends the name only as a line of its own: ISLAM can be part of a name.
const RE_RELIGION = /^(ISLAM|KRISTIAN|BUDDHA|HINDU)$/;
const RE_MARKERS = /KAD\s+PENGENALAN|MYKAD|WARGANEGARA|IDENTITY\s+CARD/i;

/**
 * What:   Reader for the OCR text of a MyKad front.
 * Input:  Flattened OCR text.
 * Output: {icNumber, name, gender, hasMarkers}.
 * Notes:  Never returns the address or religion.
 */
function parseMyKadText(text) {
  const src = String(text ?? "");
  const lines = src.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const out = {icNumber: null, name: null, gender: null,
    hasMarkers: RE_MARKERS.test(src)};

  const at = lines.findIndex((l) => RE_IC.test(l));
  if (at >= 0) {
    out.icNumber = normalizeIc(lines[at].match(RE_IC)[0]);
    const parts = [];
    for (const line of lines.slice(at + 1, at + 7)) {
      if (/\d/.test(line) || RE_STOP.test(line) || RE_RELIGION.test(line)) {
        break;
      }
      // Skip lowercase OCR noise before the name; after it, end the name.
      if (!RE_NAME_LINE.test(line) || line.replace(/[^A-Z]/g, "").length < 2) {
        if (parts.length) break;
        continue;
      }
      parts.push(line);
      if (parts.length === 2) break;
    }
    if (parts.length) out.name = parts.join(" ");
  } else {
    const m = src.match(RE_IC);
    if (m) out.icNumber = normalizeIc(m[0]);
  }

  if (/\bPEREMPUAN\b/i.test(src)) out.gender = "female";
  else if (/\bLELAKI\b/i.test(src)) out.gender = "male";
  return out;
}

module.exports = {normalizeIc, validateIc, maskIc, todayInKl, parseMyKadText};
