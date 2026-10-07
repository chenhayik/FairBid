// Unit tests for the pure helpers in scheduling.js.
// Plain node:assert, in the style of price_change.test.js. Run with `npm test`.

const assert = require("node:assert");
const {
  validateProposal,
  validateVisitDay,
  validateSibling,
  sameProposal,
  isAllowedEta,
  isLateReschedule,
  formatVisit,
  reminderDue,
} = require("./scheduling");

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failed++;
    console.log(`  FAIL  ${name}\n        ${err.message}`);
  }
}

const NOW = Date.UTC(2026, 9, 7, 4, 0, 0);
const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const job = (o = {}) => ({status: "in_progress", ...o});
const check = (o) => validateProposal({
  job: job(), options: [NOW + DAY], nowMs: NOW, ...o,
});

test("one valid option passes", () => assert.strictEqual(check({}), null));
test("three options, end date and note pass", () =>
  assert.strictEqual(check({
    options: [NOW + DAY, NOW + 2 * DAY, NOW + 3 * DAY],
    endAt: NOW + 5 * DAY,
    note: "Please bring a ladder",
  }), null));

test("job not in progress rejected", () => {
  assert.match(check({job: job({status: "open"})}), /not in progress/);
  assert.match(check({job: job({status: "cancelled"})}), /not in progress/);
  assert.match(check({job: job({status: "completed"})}), /not in progress/);
});
test("pending cancellation rejected", () =>
  assert.match(
      check({job: job({cancellationRequestedBy: "provider"})}),
      /cancellation/));

test("no options and too many options rejected", () => {
  assert.match(check({options: []}), /1 to 3/);
  assert.match(check({options: undefined}), /1 to 3/);
  assert.match(
      check({options: [1, 2, 3, 4].map((n) => NOW + n * DAY)}), /1 to 3/);
});
test("non-integer option rejected", () =>
  assert.match(check({options: ["tomorrow"]}), /1 to 3/));
test("duplicate options rejected", () =>
  assert.match(check({options: [NOW + DAY, NOW + DAY]}), /different/));

test("option under 30 minutes away rejected", () => {
  assert.match(check({options: [NOW + 29 * MIN]}), /30 minutes/);
  assert.match(check({options: [NOW - HOUR]}), /30 minutes/);
});
test("option at exactly 30 minutes passes", () =>
  assert.strictEqual(check({options: [NOW + 30 * MIN]}), null));
test("option beyond 90 days rejected", () => {
  assert.match(check({options: [NOW + 91 * DAY]}), /90 days/);
  assert.strictEqual(check({options: [NOW + 90 * DAY]}), null);
});

test("endAt must be after the latest option", () => {
  const options = [NOW + DAY, NOW + 3 * DAY];
  assert.match(check({options, endAt: NOW + 2 * DAY}), /after the last/);
  assert.match(check({options, endAt: NOW + 3 * DAY}), /after the last/);
  assert.strictEqual(check({options, endAt: NOW + 3 * DAY + MIN}), null);
});
test("endAt must be within 90 days of the latest option", () => {
  assert.match(check({endAt: NOW + 92 * DAY}), /within 90 days/);
  assert.strictEqual(check({endAt: NOW + 91 * DAY}), null);
});

test("note over 300 characters rejected", () => {
  assert.match(check({note: "x".repeat(301)}), /300/);
  assert.strictEqual(check({note: "x".repeat(300)}), null);
});

test("late flag: no appointment is never late", () =>
  assert.strictEqual(isLateReschedule(null, NOW), false));
test("late flag: under 24 hours before the start", () => {
  assert.strictEqual(isLateReschedule(NOW + 23 * HOUR, NOW), true);
  assert.strictEqual(isLateReschedule(NOW - HOUR, NOW), true);
});
test("late flag: 24 hours or more before the start", () => {
  assert.strictEqual(isLateReschedule(NOW + 24 * HOUR, NOW), false);
  assert.strictEqual(isLateReschedule(NOW + 3 * DAY, NOW), false);
});

test("visit time is formatted in Malaysia time", () => {
  // 02:00 UTC is 10:00 am in Kuala Lumpur (UTC+8).
  assert.strictEqual(
      formatVisit(Date.UTC(2026, 9, 12, 2, 0)), "Mon 12 Oct, 10:00 am");
  assert.strictEqual(
      formatVisit(Date.UTC(2026, 9, 12, 10, 30)), "Mon 12 Oct, 6:30 pm");
});

test("only 15, 30, 45 and 60 minute ETAs are allowed", () => {
  for (const m of [15, 30, 45, 60]) assert.strictEqual(isAllowedEta(m), true);
  for (const m of [0, 10, 90, "30", null, undefined]) {
    assert.strictEqual(isAllowedEta(m), false);
  }
});

// Minimal Timestamp stand-in for the appointment map.
const at = (ms, flags = {}) => ({startAt: {toMillis: () => ms}, ...flags});

test("visit day: needs an in-progress job with a confirmed visit", () => {
  const soon = at(NOW + HOUR);
  assert.strictEqual(validateVisitDay(job({appointment: soon}), NOW), null);
  assert.match(validateVisitDay(job(), NOW), /visit time/);
  assert.match(
      validateVisitDay(job({status: "completed", appointment: soon}), NOW),
      /not in progress/);
});
test("visit day: only from 3 hours before the visit", () => {
  assert.match(validateVisitDay(job({appointment: at(NOW + 4 * HOUR)}), NOW),
      /3 hours/);
  assert.strictEqual(
      validateVisitDay(job({appointment: at(NOW - HOUR)}), NOW), null);
});
test("visit day: refused once arrived", () =>
  assert.match(validateVisitDay(
      job({appointment: at(NOW), arrivedAt: {}}), NOW), /already/));

test("24h reminder is due inside 24 hours, once", () => {
  assert.strictEqual(reminderDue(at(NOW + 20 * HOUR), NOW), "24h");
  assert.strictEqual(
      reminderDue(at(NOW + 20 * HOUR, {reminded24h: true}), NOW), null);
});

test("2h reminder is due inside 2 hours, once", () => {
  assert.strictEqual(reminderDue(at(NOW + HOUR), NOW), "2h");
  assert.strictEqual(
      reminderDue(at(NOW + HOUR, {reminded24h: true}), NOW), "2h");
  assert.strictEqual(
      reminderDue(at(NOW + HOUR, {reminded2h: true}), NOW), null);
});

test("no reminder further out or once the visit started", () => {
  assert.strictEqual(reminderDue(at(NOW + 25 * HOUR), NOW), null);
  assert.strictEqual(reminderDue(at(NOW - HOUR), NOW), null);
});

const task = (o = {}) => job({
  bundleId: "b1", requestorId: "r1", acceptedProviderId: "p1",
  schedulingRequired: true, ...o,
});
const group = (sibling, args = {}) => validateSibling(
    task(), sibling, {options: [NOW + DAY], nowMs: NOW, ...args});

test("a sibling from the same bundle and provider passes", () =>
  assert.strictEqual(group(task()), null));

test("a sibling from another bundle, client or provider fails", () => {
  for (const o of [{bundleId: "b2"}, {requestorId: "r2"},
    {acceptedProviderId: "p2"}, {schedulingRequired: false}]) {
    assert.match(group(task(o)), /same bundle and provider/);
  }
  assert.match(group(undefined), /same bundle and provider/);
  assert.match(
      validateSibling(job(), task(), {options: [NOW + DAY], nowMs: NOW}),
      /same bundle and provider/);
});

test("a sibling that is not in progress or has bad times fails", () => {
  assert.match(group(task({status: "completed"})), /not in progress/);
  assert.match(group(task(), {options: [NOW + MIN]}), /30 minutes/);
});

test("sameProposal matches on proposer and time", () => {
  const p = (by, ms) => ({by, at: {toMillis: () => ms}});
  assert.ok(sameProposal(p("u1", 5), p("u1", 5)));
  assert.ok(!sameProposal(p("u1", 5), p("u2", 5)));
  assert.ok(!sameProposal(p("u1", 5), p("u1", 6)));
  assert.ok(!sameProposal(undefined, p("u1", 5)));
});

if (failed > 0) {
  console.log(`\n${failed} scheduling test(s) failed.`);
  process.exit(1);
}
console.log("All scheduling tests passed.\n");
