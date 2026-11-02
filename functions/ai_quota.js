// Daily allowance for the Post-a-Job AI assists ("Draft with AI" and the
// fair-price suggestion), so one account cannot run up the Gemini bill.
// The counter lives in aiUsage/{uid}. The catch-all rule at the end of
// firestore.rules already keeps clients out of it; only the Admin SDK in
// Cloud Functions reads and writes it.

const {todayInKl} = require("./mykad");

/**
 * What:   AI assist calls one user may make per day (Malaysia time).
 * Output: 30, shared by drafts and price suggestions.
 */
const DAILY_AI_LIMIT = 30;

/**
 * What:   Decides whether one more AI call fits in today's allowance.
 * Input:  [usage] as stored ({day, count}) or undefined; [today] as
 *         YYYY-MM-DD; optional [limit].
 * Output: {allowed, next}; [next] is the usage to store when allowed.
 * Notes:  A stored day other than [today] counts as zero, so the allowance
 *         starts again at midnight without a scheduled job.
 */
function takeOne(usage, today, limit = DAILY_AI_LIMIT) {
  const used = usage && usage.day === today ? usage.count : 0;
  if (used >= limit) return {allowed: false, next: null};
  return {allowed: true, next: {day: today, count: used + 1}};
}

/**
 * What:   Gives back one call after the model could not be reached.
 * Input:  [usage] as stored, or undefined; [today] as YYYY-MM-DD.
 * Output: The usage to store, or null when there is nothing to give back.
 */
function giveOneBack(usage, today) {
  if (!usage || usage.day !== today || !(usage.count > 0)) return null;
  return {day: today, count: usage.count - 1};
}

/**
 * What:   Reserves one AI call for [uid] before the model is asked.
 * Input:  Firestore [db], the caller's [uid], optional [now].
 * Output: True when the call may go ahead; false when today's allowance is
 *         used up.
 * Notes:  Runs in a transaction, so calls sent at the same moment cannot
 *         slip past the limit together.
 */
function reserveAiCall(db, uid, now = new Date()) {
  const ref = db.doc(`aiUsage/${uid}`);
  const today = todayInKl(now);
  return db.runTransaction(async (tx) => {
    const {allowed, next} = takeOne((await tx.get(ref)).data(), today);
    if (allowed) tx.set(ref, next);
    return allowed;
  });
}

/**
 * What:   Returns a reserved call when the model gave no answer at all.
 * Input:  Firestore [db], the caller's [uid], optional [now].
 * Output: Resolves once the count is lowered (or there was nothing to lower).
 */
function refundAiCall(db, uid, now = new Date()) {
  const ref = db.doc(`aiUsage/${uid}`);
  const today = todayInKl(now);
  return db.runTransaction(async (tx) => {
    const next = giveOneBack((await tx.get(ref)).data(), today);
    if (next) tx.set(ref, next);
  });
}

module.exports = {
  DAILY_AI_LIMIT,
  takeOne,
  giveOneBack,
  reserveAiCall,
  refundAiCall,
};
