// Bundled job postings: create, bid on, withdraw, cancel and expire bundles.
// A bundle is a group of 2-6 tasks, each stored as an ordinary job.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
// Imported directly: `admin.firestore.*` is undefined in the emulator.
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {notifyUser} = require("./common");

// Task count limits; must match PlatformConfig. Keeps the award search small.
const MIN_BUNDLE_TASKS = 2;
const MAX_BUNDLE_TASKS = 6;

// Consolidation cap, saved on each bundle when posted (matches PlatformConfig).
const CONSOLIDATION_CAP_PCT = 5;
const CONSOLIDATION_CAP_SEN = 50000; // RM 500

// Same per-amount ceiling the bid rules enforce: RM 1,000,000.
const MAX_AMOUNT_SEN = 100000000;

// Highest bid total (RM 50,000): the wallet cap, so any award can be funded.
const MAX_BID_SEN = 5000000;

// Copy of kServiceCategories, so a task with an unknown category is rejected.
const CATEGORIES = [
  "Cleaning", "Plumbing", "Electrical", "Aircon Servicing", "Home Repair",
  "Moving & Delivery", "Tutoring", "IT & Tech Support", "Design & Creative",
  "Other",
];

const MAX_TITLE_LEN = 120;
const MAX_ADDRESS_LEN = 200;
const MAX_DESCRIPTION_LEN = 5000;
const MAX_PHOTOS = 10;

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

// Optional bidding deadline in epoch millis (JSON has no date type).
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

// Which pool photos a task is tagged with: unique indexes into the pool.
function checkPhotoIndexes(raw, photoCount, position) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || new Set(raw).size !== raw.length ||
      !raw.every((n) => Number.isInteger(n) && n >= 0 && n < photoCount)) {
    throw bad(`${position} has invalid photo tags.`);
  }
  return raw;
}

// Validates the task list and returns the stored shape of each task.
function checkTasks(list, photoCount) {
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
    return {
      title: text(t.title, `${position} title`, MAX_TITLE_LEN),
      description:
          text(t.description, `${position} description`, MAX_DESCRIPTION_LEN),
      category: t.category,
      budget: minSen == null && maxSen == null ?
          null :
          {minSen, maxSen, hourly: t.hourly === true},
      photoIndexes: checkPhotoIndexes(t.photoIndexes, photoCount, position),
    };
  });
}

// Each task's photos: the ones tagged to it, plus any photo tagged to none.
function taskPhotoUrls(photoUrls, tasks) {
  const tagged = new Set(tasks.flatMap((t) => t.photoIndexes));
  return tasks.map((t) => photoUrls.filter((_, i) =>
    !tagged.has(i) || t.photoIndexes.includes(i)));
}

// Validates a createBundle payload. Pure, so tests need no emulator.
function validateBundle(data) {
  const payload = data || {};
  const photoUrls = checkPhotos(payload.photoUrls);
  const tasks = checkTasks(payload.tasks, photoUrls.length);
  const perTask = taskPhotoUrls(photoUrls, tasks);
  return {
    title: text(payload.title, "Title", MAX_TITLE_LEN),
    description: text(payload.description, "Description", MAX_DESCRIPTION_LEN),
    location: checkLocation(payload.location),
    photoUrls,
    deadline: checkDeadline(payload.deadlineMillis),
    tasks: tasks.map((task, i) => ({...task, photoUrls: perTask[i]})),
  };
}

// Creates the bundle doc and one ordinary job per task, in one atomic batch.
exports.createBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const {title, description, location, photoUrls, deadline, tasks} =
      validateBundle(data);

  const db = admin.firestore();
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "requestor") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only a client can post a bundle.");
  }
  if (user.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }

  // Ids are minted locally so the bundle can list its task ids.
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
      // Copies of the bundle's shared fields, so a task works as a normal job.
      location,
      photoUrls: task.photoUrls,
      ...(deadline ? {deadline} : {}),
      budget: task.budget,
      status: "open",
      bidCount: 0,
      createdAt: FieldValue.serverTimestamp(),
      bundleId: bundleRef.id,
      bundleOrder: i,
      // Saved on the task so its feed card can show the bundle size.
      bundleTaskCount: tasks.length,
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

// Provider package bids, and cancelling a bundle.

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

/** Whether a bundle still takes bids: open and not past its deadline. */
function bundleBiddingOpen(bundle) {
  return bundle.status === "open" &&
      (bundle.deadline == null || bundle.deadline.toMillis() > Date.now());
}

/** Checks the price per picked task (job id to sen); rules cannot check maps. */
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
    if (!Number.isInteger(sen) || sen <= 0) {
      throw bad("Every task you picked needs a price above RM 0.");
    }
    if (sen > MAX_BID_SEN) {
      throw bad("A task price can't be more than RM 50,000.");
    }
  });
  // Keys are checked against the bundle's taskIds in submitBundleBid.
  return Object.fromEntries(entries);
}

/** Adds the per-task prices up. */
function taskTotal(taskPrices) {
  return Object.values(taskPrices).reduce((sum, sen) => sum + sen, 0);
}

/** Splits a bundle price across tasks; the last one absorbs the rounding. */
function splitBundlePrice(taskPrices, bundlePriceSen) {
  const taskIds = Object.keys(taskPrices);
  const priceTotal = taskIds.reduce((sum, id) => sum + taskPrices[id], 0);
  const amounts = {};
  let allocated = 0;
  taskIds.forEach((taskId, i) => {
    if (i === taskIds.length - 1) {
      amounts[taskId] = bundlePriceSen - allocated;
      return;
    }
    const share = Math.floor(bundlePriceSen * taskPrices[taskId] / priceTotal);
    amounts[taskId] = share;
    allocated += share;
  });
  return amounts;
}

/** Validates a `submitBundleBid` payload; pure, so tests need no emulator. */
function validateBundleBid(data) {
  const payload = data || {};
  const taskPrices = checkTaskPrices(payload.taskPrices);
  const taskTotalSen = taskTotal(taskPrices);
  const bundlePriceSen = optionalSen(payload.bundlePriceSen, "Bundle price");
  if (bundlePriceSen != null) {
    if (bundlePriceSen === 0) {
      throw bad("Your bundle price must be above RM 0.");
    }
    // A bundle price not below the task total is no discount, so reject it.
    if (bundlePriceSen >= taskTotalSen) {
      throw bad("Your bundle price must be lower than your task prices " +
          "added up.");
    }
    // A share under 1 sen would become RM 0, but every milestone must be above 0.
    const shares = splitBundlePrice(taskPrices, bundlePriceSen);
    if (Object.values(shares).some((sen) => sen < 1)) {
      throw bad("Your bundle price is too low to share across every task " +
          "you picked.");
    }
  }
  if ((bundlePriceSen ?? taskTotalSen) > MAX_BID_SEN) {
    throw bad("Your bid total can't be more than RM 50,000.");
  }
  return {
    taskPrices,
    taskTotalSen,
    bundlePriceSen,
    estimatedDuration: text(
        payload.estimatedDuration, "Estimated duration", MAX_DURATION_LEN),
    message: text(payload.message, "Proposal message", MAX_MESSAGE_LEN),
  };
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
 * Saves a provider's sealed bid at `bundles/{id}/bundleBids/{uid}`.
 * Runs in a transaction because a re-bid adjusts `bidCount`.
 */
exports.submitBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");
  const bid = validateBundleBid(data);
  const picked = Object.keys(bid.taskPrices);

  const db = admin.firestore();
  const user = await biddingProvider(db, uid);

  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  const providerName = user.displayName || "Provider";

  // Quick check first so a doomed call fails fast; repeated in the transaction.
  const cheapBundle = (await bundleRef.get()).data();
  if (!cheapBundle) {
    throw new functions.https.HttpsError(
        "not-found", "That bundle no longer exists.");
  }

  await db.runTransaction(async (tx) => {
    // Read the bundle first: a transaction cannot read after it writes.
    const bundleSnap = await tx.get(bundleRef);
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
    if (picked.some((jobId) => !taskIds.includes(jobId))) {
      throw bad("Those tasks are not part of this bundle.");
    }

    const taskRefs = taskIds.map((jobId) => db.doc(`jobs/${jobId}`));
    const [existing, ...taskSnaps] = taskRefs.length === 0 ?
        [await tx.get(bidRef)] :
        await tx.getAll(bidRef, ...taskRefs);
    if (taskSnaps.some((snap) =>
      picked.includes(snap.id) && snap.data()?.status !== "open")) {
      throw bad("One of the tasks you picked is no longer open.");
    }

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
      providerName,
      ...(user.profilePhotoUrl ? {providerPhotoUrl: user.profilePhotoUrl} : {}),
      // Taken from the profile, not the payload, so the Trust Score cannot be faked.
      providerTrustScore: user.trustScore || 0,
      providerScoreVisible: user.trust?.scoreVisible === true,
      taskPrices: bid.taskPrices,
      ...(bid.bundlePriceSen == null ?
          {} :
          {bundlePriceSen: bid.bundlePriceSen}),
      estimatedDuration: bid.estimatedDuration,
      message: bid.message,
      // Lets the Pending Bids list show the bundle title without another read.
      bundleTitle: bundle.title || "Bundle",
      status: "pending",
      // An edit keeps the original createdAt.
      createdAt: existing.exists ?
          existing.data().createdAt :
          FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    // Only tasks added to or dropped from this bid change their bidCount.
    picked.filter((jobId) => !before.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(1)}));
    before.filter((jobId) => !picked.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));

    // Only a new bid is announced; bids are sealed, so no price is shown.
    if (!existing.exists) {
      notifyUser(tx, bundle.requestorId, {
        type: "bid_received",
        title: "New bid on your bundle",
        body: `${providerName} bid on ${picked.length} task(s) of ` +
            `"${bundle.title || "a bundle"}".`,
        route: `/bundles/${bundleId}`,
      });
    }
  });

  return {
    taskCount: picked.length,
    totalSen: bid.bundlePriceSen == null ?
        bid.taskTotalSen :
        bid.bundlePriceSen,
  };
});

/** Withdraws the caller's pending bundle bid while bidding is still open. */
exports.withdrawBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  const taskCount = await db.runTransaction(async (tx) => {
    // Read first: a transaction cannot read after it writes.
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

/** Cancels an open bundle, its open tasks and pending bids, atomically. */
exports.cancelBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);

  const taskCount = await db.runTransaction(async (tx) => {
    // Read the bundle first: a transaction cannot read after it writes.
    const bundleSnap = await tx.get(bundleRef);
    const bundle = bundleSnap.data();
    if (!bundle) {
      throw new functions.https.HttpsError(
          "not-found", "That bundle no longer exists.");
    }
    if (bundle.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the client who posted this bundle can cancel it.");
    }
    if (bundle.status !== "open") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This bundle is no longer open.");
    }

    const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
    const taskRefs = taskIds.map((jobId) => db.doc(`jobs/${jobId}`));
    // Reading bids inside the transaction closes the gap for late bids.
    const [taskSnaps, pendingBids] = await Promise.all([
      taskRefs.length === 0 ? Promise.resolve([]) : tx.getAll(...taskRefs),
      tx.get(db.collection(`bundles/${bundleId}/bundleBids`)
          .where("status", "==", "pending")),
    ]);

    let cancelled = 0;
    taskSnaps.forEach((snap) => {
      if (snap.data()?.status !== "open") return;
      cancelled++;
      tx.update(snap.ref, {
        status: "cancelled",
        cancelledBy: uid,
        cancelledAt: FieldValue.serverTimestamp(),
        cancellationReason:
            "The client cancelled the bundle this task was part of.",
      });
    });

    // Pending bids are 'closed' (not 'rejected') since the bundle was called off.
    pendingBids.docs.forEach((doc) => {
      tx.update(doc.ref, {status: "closed"});
      notifyUser(tx, doc.id, {
        type: "cancellation",
        title: "Bundle cancelled",
        body: `The client cancelled "${bundle.title || "a bundle"}", ` +
            "so your bid is closed.",
        route: null,
      });
    });

    tx.update(bundleRef, {
      status: "cancelled",
      cancelledBy: uid,
      cancelledAt: FieldValue.serverTimestamp(),
    });

    return cancelled;
  });

  return {taskCount};
});

// Bundle expiry.

/** Every 6 hours, expires overdue open bundles and closes their pending bids. */
exports.closeExpiredBundles = functions.pubsub
    .schedule("every 6 hours")
    .onRun(async () => {
      const db = admin.firestore();
      const now = Timestamp.now();
      const snap = await db.collection("bundles")
          .where("status", "==", "open")
          .where("deadline", "<=", now)
          .get();

      let closed = 0;
      for (const doc of snap.docs) {
        const didClose = await db.runTransaction(async (tx) => {
          // Re-read inside the transaction: an award may have landed since the query.
          const bundleSnap = await tx.get(doc.ref);
          const bundle = bundleSnap.data();
          if (!bundle || bundle.status !== "open") return false;

          const pendingBids = await tx.get(db
              .collection(`bundles/${doc.id}/bundleBids`)
              .where("status", "==", "pending"));
          tx.update(doc.ref, {
            status: "expired",
            expiredAt: FieldValue.serverTimestamp(),
          });
          pendingBids.docs.forEach((bidDoc) => {
            tx.update(bidDoc.ref, {status: "closed"});
            notifyUser(tx, bidDoc.id, {
              type: "cancellation",
              title: "Bundle closed",
              body: `Bidding on "${bundle.title || "a bundle"}" closed ` +
                  "without an award, so your bid is closed.",
              route: null,
            });
          });
          return true;
        });
        if (didClose) closed++;
      }
      functions.logger.info(`closeExpiredBundles: closed ${closed} bundle(s)`);
    });

// Trust and reviews count a bundle once per participant, not once per task.

/** Returns the participants not yet counted as completed for this bundle. */
function uidsToCount(participants, alreadyCounted) {
  return participants.filter((uid) => !alreadyCounted.includes(uid));
}

// Exported for tests only; index.js re-exports just the callables.
exports.validateBundle = validateBundle;
exports.validateBundleBid = validateBundleBid;
exports.bundleBiddingOpen = bundleBiddingOpen;
exports.splitBundlePrice = splitBundlePrice;
exports.uidsToCount = uidsToCount;

// Shared with bundle_award.js and the posting assist in index.js.
exports.CATEGORIES = CATEGORIES;
exports.callerUid = callerUid;
exports.bad = bad;
exports.docId = docId;
