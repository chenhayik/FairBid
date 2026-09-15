// Bundled job postings - phase 1 of docs/BUNDLE_BIDDING.md.
//
// A bundle is one posting that groups 2-6 related tasks. bundles/{bundleId}
// holds the shared fields (requestor, title, location, photos, deadline).
// Each task is an ordinary job in jobs/{jobId} tagged with
// bundleId/bundleOrder, so nothing downstream (escrow, milestones, chat,
// disputes, cancellation) needs to learn a new shape - an awarded task is
// still a one-provider job.
//
// createBundle is the only writer of either collection. firestore.rules
// enforces that: client writes to bundles/ are denied, and a client-created
// job carrying bundle fields is rejected. So the cross-references authored
// here (task order, lot membership, dependencies, consolidation-cap
// snapshot) are exactly what the phase-3 award engine can trust.
//
// Lives in its own module because index.js is already long; re-exported
// there the same way ssm.js is.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
// Imported modularly rather than via admin.firestore.* - see ssm.js: the
// legacy accessor reads as undefined once the Functions emulator proxies
// the admin SDK.
const {FieldValue, Timestamp} = require("firebase-admin/firestore");

// Bundle size limits. Must match PlatformConfig.minBundleTasks /
// maxBundleTasks (lib/core/config/platform_config.dart). Upper bound keeps
// the phase-3 award search cheap: the exact solver walks 2^n subsets, so
// six tasks is 64 states.
const MIN_BUNDLE_TASKS = 2;
const MAX_BUNDLE_TASKS = 6;

// Consolidation cap, snapshotted onto every bundle at creation so an award
// is judged by the rule shown at posting time, not whatever the constant
// says later. Must match PlatformConfig.consolidationCapPct /
// consolidationCapSen. First read in phase 3 (previewBundleAward).
const CONSOLIDATION_CAP_PCT = 5;
const CONSOLIDATION_CAP_SEN = 50000; // RM 500

// Same per-amount ceiling the bid rules enforce: RM 1,000,000.
const MAX_AMOUNT_SEN = 100000000;

// Copy of kServiceCategories (lib/core/util/service_categories.dart). A
// task with a category outside this list would never show in the feed's
// category filter, so it's checked here rather than trusting the form.
const CATEGORIES = [
  "Cleaning", "Plumbing", "Electrical", "Aircon Servicing", "Home Repair",
  "Moving & Delivery", "Tutoring", "IT & Tech Support", "Design & Creative",
  "Other",
];

const MAX_TITLE_LEN = 120;
const MAX_ADDRESS_LEN = 200;
const MAX_DESCRIPTION_LEN = 5000;
const MAX_PHOTOS = 10;
const MAX_GAP_DAYS = 365;

// Rejects unauthenticated calls; returns the caller's uid.
function callerUid(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "You must be signed in.");
  }
  return context.auth.uid;
}

// An invalid-argument error - every call site does `throw bad("...")`.
function bad(message) {
  return new functions.https.HttpsError("invalid-argument", message);
}

// Returns value trimmed, or throws when it isn't usable text.
function text(value, name, max) {
  if (typeof value !== "string") throw bad(`${name} is required.`);
  const trimmed = value.trim();
  if (trimmed === "") throw bad(`${name} is required.`);
  if (trimmed.length > max) throw bad(`${name} is too long.`);
  return trimmed;
}

// Returns an optional whole-sen amount, or null when absent.
function optionalSen(value, name) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value < 0 || value > MAX_AMOUNT_SEN) {
    throw bad(`${name} is not a valid amount.`);
  }
  return value;
}

// Validates the shared map location and returns the stored shape.
function checkLocation(raw) {
  const m = raw || {};
  const lat = m.lat;
  const lng = m.lng;
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    throw bad("Pick a location on the map.");
  }
  return {
    lat,
    lng,
    address: text(m.address, "Location address", MAX_ADDRESS_LEN),
    districtCode: typeof m.districtCode === "string" ? m.districtCode : null,
    districtName: typeof m.districtName === "string" ? m.districtName : null,
    town: typeof m.town === "string" ? m.town : null,
  };
}

// Optional bidding deadline, sent as epoch millis (callable protocol is
// JSON, which has no date type).
function checkDeadline(value) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value <= Date.now()) {
    throw bad("The bidding deadline must be in the future.");
  }
  return Timestamp.fromMillis(value);
}

// Shared photo URLs, capped so one posting cannot balloon.
function checkPhotos(raw) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_PHOTOS ||
      !raw.every((url) => typeof url === "string" && url !== "")) {
    throw bad("Those bundle photos are not valid.");
  }
  return raw;
}

// Validates the task list and returns one clean object per task.
// startsAfterIndex stays an index here; the caller resolves it to a real
// job id once the ids exist.
function checkTasks(list) {
  if (!Array.isArray(list) || list.length < MIN_BUNDLE_TASKS ||
      list.length > MAX_BUNDLE_TASKS) {
    throw bad(`A bundle needs between ${MIN_BUNDLE_TASKS} and ` +
        `${MAX_BUNDLE_TASKS} tasks.`);
  }
  return list.map((entry, i) => {
    const t = entry || {};
    const position = `Task ${i + 1}`;
    if (!CATEGORIES.includes(t.category)) {
      throw bad(`${position} has no valid category.`);
    }
    const minSen = optionalSen(t.budgetMinSen, `${position} budget`);
    const maxSen = optionalSen(t.budgetMaxSen, `${position} budget`);
    if (minSen != null && maxSen != null && minSen > maxSen) {
      throw bad(`${position} has a budget range that is back to front.`);
    }
    // Dependencies are finish-to-start and may only point at an earlier
    // task. That rule alone makes a cycle impossible - no graph walk
    // needed, and the stored order is always a valid schedule.
    const after = t.startsAfterIndex;
    if (after != null &&
        (!Number.isInteger(after) || after < 0 || after >= i)) {
      throw bad(`${position} must follow a task listed before it.`);
    }
    const gapDays = t.gapDays;
    if (gapDays != null &&
        (after == null || !Number.isInteger(gapDays) ||
         gapDays < 0 || gapDays > MAX_GAP_DAYS)) {
      throw bad(`${position} has an invalid gap.`);
    }
    return {
      title: text(t.title, `${position} title`, MAX_TITLE_LEN),
      description:
          text(t.description, `${position} description`, MAX_DESCRIPTION_LEN),
      category: t.category,
      budget: minSen == null && maxSen == null ?
          null :
          {minSen, maxSen, hourly: t.hourly === true},
      lotId: t.lotId == null ?
          null :
          text(t.lotId, `${position} lot`, MAX_TITLE_LEN),
      startsAfterIndex: after == null ? null : after,
      gapDays: gapDays == null ? 0 : gapDays,
    };
  });
}

// Validates a createBundle payload and returns the clean values to store.
// Pure - no Firestore, no auth - so bundles.test.js can pin every rule
// without an emulator.
function validateBundle(data) {
  const payload = data || {};
  return {
    title: text(payload.title, "Title", MAX_TITLE_LEN),
    description: text(payload.description, "Description", MAX_DESCRIPTION_LEN),
    location: checkLocation(payload.location),
    photoUrls: checkPhotos(payload.photoUrls),
    deadline: checkDeadline(payload.deadlineMillis),
    tasks: checkTasks(payload.tasks),
  };
}

// Creates one bundled posting: the bundles/{bundleId} doc plus one ordinary
// job per task, in a single atomic batch.
//
// A batch rather than a transaction: every write creates a brand-new
// document, and the one thing read here (the caller's profile) is never
// written back, so there's no read-modify-write to protect. acceptBid needs
// a transaction because it re-reads a wallet balance it then changes.
exports.createBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const {title, description, location, photoUrls, deadline, tasks} =
      validateBundle(data);

  const db = admin.firestore();
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "requestor") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only a requestor can post a bundle.");
  }
  if (user.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }

  // Ids are minted locally - .doc() with no argument allocates one without
  // a round trip - so a task can reference the job id of the task it
  // follows before anything is written.
  const bundleRef = db.collection("bundles").doc();
  const jobRefs = tasks.map(() => db.collection("jobs").doc());
  const requestor = {
    requestorId: uid,
    requestorName: user.displayName || "Requestor",
    ...(user.profilePhotoUrl ? {requestorPhotoUrl: user.profilePhotoUrl} : {}),
  };

  const batch = db.batch();
  tasks.forEach((task, i) => {
    batch.set(jobRefs[i], {
      ...requestor,
      title: task.title,
      description: task.description,
      category: task.category,
      // Copies of the bundle's shared fields, so a task renders in the
      // feed, Saved Jobs and job detail as an ordinary job - no bundle
      // lookup needed.
      location,
      photoUrls,
      ...(deadline ? {deadline} : {}),
      budget: task.budget,
      status: "open",
      bidCount: 0,
      createdAt: FieldValue.serverTimestamp(),
      bundleId: bundleRef.id,
      bundleOrder: i,
      ...(task.lotId ? {lotId: task.lotId} : {}),
      ...(task.startsAfterIndex == null ? {} : {
        startsAfterJobId: jobRefs[task.startsAfterIndex].id,
        gapDays: task.gapDays,
      }),
    });
  });
  batch.set(bundleRef, {
    ...requestor,
    title,
    description,
    location,
    photoUrls,
    ...(deadline ? {deadline} : {}),
    status: "open",
    taskIds: jobRefs.map((ref) => ref.id),
    consolidationCapPct: CONSOLIDATION_CAP_PCT,
    consolidationCapSen: CONSOLIDATION_CAP_SEN,
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  return {bundleId: bundleRef.id, taskIds: jobRefs.map((ref) => ref.id)};
});

// Exported for bundles.test.js only. index.js re-exports just createBundle,
// and the Firebase CLI deploys only what index.js exports.
exports.validateBundle = validateBundle;    