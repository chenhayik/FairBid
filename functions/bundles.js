// Bundled job postings - phases 1 and 2 of docs/BUNDLE_BIDDING.md.
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
      // Denormalised so a task's feed card can say "Part of a 4-task
      // bundle" without reading the bundle document.
      bundleTaskCount: tasks.length,
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

// ---------------------------------------------------------------------------
// Phase 2: the provider's package bid, and cancelling a bundle.
// ---------------------------------------------------------------------------

/** A proposal message is free text, so cap it. */
const MAX_MESSAGE_LEN = 2000;

/** "Less than 1 week" and friends - a picker's label, not free text. */
const MAX_DURATION_LEN = 40;

/** A document id sent by the app, e.g. the bundle a bid belongs to. */
function docId(value, name) {
  if (typeof value !== "string" || value.trim() === "" ||
      value.length > 1500 || value.includes("/")) {
    throw bad(`${name} is missing.`);
  }
  return value;
}

/**
 * Whether a bundle still takes bids: open AND not past its deadline. The
 * bundle-level twin of the `jobBiddingOpen` rule, so a late bid cannot sneak
 * in during the lag before the expiry sweep runs.
 */
function bundleBiddingOpen(bundle) {
  return bundle.status === "open" &&
      (bundle.deadline == null || bundle.deadline.toMillis() > Date.now());
}

/**
 * The provider's price for each task they picked: a map of job id to whole
 * sen. Validated here rather than in firestore.rules because the rules
 * language cannot walk a map's entries - which is the whole reason a bundle
 * bid is written by this callable instead of straight from the app.
 */
function checkTaskPrices(raw) {
  const prices = raw == null ? {} : raw;
  if (typeof prices !== "object" || Array.isArray(prices)) {
    throw bad("Pick at least one task to bid on.");
  }
  const entries = Object.entries(prices);
  if (entries.length === 0) throw bad("Pick at least one task to bid on.");
  if (entries.length > MAX_BUNDLE_TASKS) {
    throw bad(`A bid may cover at most ${MAX_BUNDLE_TASKS} tasks.`);
  }
  entries.forEach(([, sen]) => {
    if (!Number.isInteger(sen) || sen <= 0 || sen > MAX_AMOUNT_SEN) {
      throw bad("Every task you picked needs a price above RM 0.");
    }
  });
  // The keys are checked against the bundle's own taskIds in submitBundleBid,
  // which is also what makes them safe to use as document ids here.
  return Object.fromEntries(entries);
}

/** Adds the per-task prices up. */
function taskTotal(taskPrices) {
  return Object.values(taskPrices).reduce((sum, sen) => sum + sen, 0);
}

/**
 * Validates a `submitBundleBid` payload and returns the clean values to
 * store. Pure - no Firestore, no auth - so bundles.test.js can pin every rule
 * without an emulator. Everything that needs the bundle itself (which tasks
 * it has, its lots, whether it still takes bids) is checked in the callable.
 */
function validateBundleBid(data) {
  const payload = data || {};
  const taskPrices = checkTaskPrices(payload.taskPrices);
  const taskTotalSen = taskTotal(taskPrices);
  const bundlePriceSen = optionalSen(payload.bundlePriceSen, "Bundle price");
  if (bundlePriceSen != null) {
    if (bundlePriceSen === 0) {
      throw bad("Your bundle price must be above RM 0.");
    }
    // A bundle price is the discount for winning the whole bid. At or above
    // the sum of the task prices it is not a discount at all, and the phase-3
    // award engine would never pick it - so it is a slip worth catching here.
    if (bundlePriceSen >= taskTotalSen) {
      throw bad("Your bundle price must be lower than your task prices " +
          "added up.");
    }
  }
  return {
    taskPrices,
    taskTotalSen,
    bundlePriceSen,
    allOrNothing: payload.allOrNothing === true,
    estimatedDuration: text(
        payload.estimatedDuration, "Estimated duration", MAX_DURATION_LEN),
    message: text(payload.message, "Proposal message", MAX_MESSAGE_LEN),
  };
}

/**
 * Tasks sharing a `lotId` are bid on and awarded together (waterproofing then
 * tiling, say), so a bid that picks one of them must pick all of them.
 * Checked against the task documents, because only they carry the lot.
 */
function checkLots(taskSnaps, picked) {
  const lots = {};
  taskSnaps.forEach((snap) => {
    const lotId = snap.data()?.lotId;
    if (!lotId) return;
    lots[lotId] = (lots[lotId] || []).concat(snap.id);
  });
  Object.values(lots).forEach((lot) => {
    const inBid = lot.filter((jobId) => picked.includes(jobId));
    if (inBid.length !== 0 && inBid.length !== lot.length) {
      throw bad("Some of these tasks have to go to the same provider. Pick " +
          "every task in the group, or none of them.");
    }
  });
}

/** Loads a bundle's task jobs, in `taskIds` order. */
function readTasks(db, taskIds) {
  if (taskIds.length === 0) return Promise.resolve([]);
  return db.getAll(...taskIds.map((jobId) => db.doc(`jobs/${jobId}`)));
}

/** The caller's profile, rejected unless they may bid right now. */
async function biddingProvider(db, uid) {
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "provider" || user.verificationStatus !== "approved") {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Only a verified provider can bid. Finish verification first.");
  }
  if (user.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }
  return user;
}

/**
 * One provider's sealed package bid on a bundle, stored at
 * `bundles/{bundleId}/bundleBids/{uid}` - written here and nowhere else,
 * because firestore.rules denies every client write to it.
 *
 * Why a callable rather than a rules-checked write like an ordinary per-job
 * bid: the prices live in a map, one entry per task, and the rules language
 * cannot walk a map's entries. A rule could check that the map's KEYS are
 * tasks of this bundle and nothing more, leaving every price itself
 * unchecked - and the phase-3 award engine moves real money against those
 * numbers. Doing it here also lets the server stamp the Trust Score snapshot
 * from the profile rather than pin a value the client sent, and keeps each
 * task's `bidCount` in step with the bid inside one transaction.
 *
 * A transaction, not a batch (unlike createBundle): re-bidding reads the
 * provider's existing bid to see which tasks joined or left it, then writes
 * counters worked out from what it read.
 */
exports.submitBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");
  const bid = validateBundleBid(data);

  const db = admin.firestore();
  const [user, bundleSnap] = await Promise.all([
    biddingProvider(db, uid),
    db.doc(`bundles/${bundleId}`).get(),
  ]);
  const bundle = bundleSnap.data();
  if (!bundle) {
    throw new functions.https.HttpsError(
        "not-found", "That bundle no longer exists.");
  }
  if (bundle.requestorId === uid) {
    throw new functions.https.HttpsError(
        "permission-denied", "You cannot bid on your own bundle.");
  }
  if (!bundleBiddingOpen(bundle)) {
    throw new functions.https.HttpsError(
        "failed-precondition", "This bundle is no longer taking bids.");
  }

  const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
  const picked = Object.keys(bid.taskPrices);
  if (picked.some((jobId) => !taskIds.includes(jobId))) {
    throw bad("Those tasks are not part of this bundle.");
  }
  const taskSnaps = await readTasks(db, taskIds);
  if (taskSnaps.some((snap) =>
    picked.includes(snap.id) && snap.data()?.status !== "open")) {
    throw bad("One of the tasks you picked is no longer open.");
  }
  checkLots(taskSnaps, picked);

  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(bidRef);
    const before = existing.exists ?
        Object.keys(existing.data().taskPrices || {}) :
        [];
    if (existing.exists && existing.data().status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "This bid has already been decided, so it can no longer be " +
          "changed.");
    }
    tx.set(bidRef, {
      providerId: uid,
      providerName: user.displayName || "Provider",
      ...(user.profilePhotoUrl ? {providerPhotoUrl: user.profilePhotoUrl} : {}),
      // Stamped from the profile, never from the payload: a provider must not
      // be able to dress their own bid in a better Trust Score.
      providerTrustScore: user.trustScore || 0,
      providerScoreVisible: user.trust?.scoreVisible === true,
      taskPrices: bid.taskPrices,
      ...(bid.bundlePriceSen == null ?
          {} :
          {bundlePriceSen: bid.bundlePriceSen}),
      allOrNothing: bid.allOrNothing,
      estimatedDuration: bid.estimatedDuration,
      message: bid.message,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
    });
    // Each task counts the bids that cover it, so only the tasks that joined
    // or left this bid move - re-bidding the same tasks changes nothing.
    picked.filter((jobId) => !before.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(1)}));
    before.filter((jobId) => !picked.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));
  });

  return {
    taskCount: picked.length,
    totalSen: bid.bundlePriceSen == null ?
        bid.taskTotalSen :
        bid.bundlePriceSen,
  };
});

/**
 * Withdraws the caller's own bundle bid and gives back the `bidCount` it
 * added to every task it covered.
 *
 * Allowed only while the bundle still takes bids - the same window in which
 * the bid could be edited. Once bidding closes the requestor is choosing
 * between the bids in front of them, and one vanishing mid-decision would
 * pull a task out of an award they were about to make. A bid that has already
 * been decided is refused for the same reason, with a clearer message.
 */
exports.withdrawBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  const taskCount = await db.runTransaction(async (tx) => {
    // Both reads first: a transaction may not read after it has written.
    const [bundleSnap, snap] = await tx.getAll(bundleRef, bidRef);
    if (!snap.exists) return 0; // already gone - nothing left to undo
    const existing = snap.data();
    if (existing.status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "This bid has already been decided, so it can no longer be " +
          "withdrawn.");
    }
    const bundle = bundleSnap.data();
    if (!bundle || !bundleBiddingOpen(bundle)) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Bidding has closed on this bundle, so your bid can no longer be " +
          "withdrawn.");
    }
    const covered = Object.keys(existing.taskPrices || {});
    tx.delete(bidRef);
    covered.forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));
    return covered.length;
  });

  return {taskCount};
});

/**
 * Cancels an open bundle and every task still open under it, in one batch.
 *
 * It has to be one action. A provider bids on the package, so letting the
 * requestor cancel a single task would break an all-or-nothing bid or split a
 * lot - which is why firestore.rules freezes a task's status while its bundle
 * is open, and why this runs on the server. Tasks that have already left
 * 'open' (an awarded one, or one the expiry sweep closed) are left alone, and
 * the existing `logJobStatusChange` trigger writes each task's timeline entry.
 */
exports.cancelBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bundle = (await bundleRef.get()).data();
  if (!bundle) {
    throw new functions.https.HttpsError(
        "not-found", "That bundle no longer exists.");
  }
  if (bundle.requestorId !== uid) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Only the requestor who posted this bundle can cancel it.");
  }
  if (bundle.status !== "open") {
    throw new functions.https.HttpsError(
        "failed-precondition", "This bundle is no longer open.");
  }

  const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
  const taskSnaps = await readTasks(db, taskIds);
  const batch = db.batch();
  let cancelled = 0;
  taskSnaps.forEach((snap) => {
    if (snap.data()?.status !== "open") return;
    cancelled++;
    batch.update(snap.ref, {
      status: "cancelled",
      cancelledBy: uid,
      cancelledAt: FieldValue.serverTimestamp(),
      cancellationReason:
          "The requestor cancelled the bundle this task was part of.",
    });
  });
  batch.update(bundleRef, {
    status: "cancelled",
    cancelledBy: uid,
    cancelledAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  return {taskCount: cancelled};
});

// Exported for bundles.test.js only. index.js re-exports just the
// callables, and the Firebase CLI deploys only what index.js exports.
exports.validateBundle = validateBundle;
exports.validateBundleBid = validateBundleBid;
exports.checkLots = checkLots;
exports.bundleBiddingOpen = bundleBiddingOpen;

// Shared with bundle_award.js.
exports.callerUid = callerUid;
exports.bad = bad;
exports.docId = docId;    