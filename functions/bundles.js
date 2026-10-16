// Bundled job postings: create, bid on, withdraw, cancel and expire bundles.
// A bundle is a group of 2-6 tasks, each stored as an ordinary job.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {
  callerUid, bad, docId, throwIfSuspended, notifyUser,
} = require("./common");

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

/**
 * What:   Required-text validator.
 * Input:  [value], the field [name] for errors and the [max] length.
 * Output: [value] trimmed; throws `invalid-argument` when empty or too long.
 */
function text(value, name, max) {
  if (typeof value !== "string") throw bad(`${name} is required.`);
  const trimmed = value.trim();
  if (trimmed === "") throw bad(`${name} is required.`);
  if (trimmed.length > max) throw bad(`${name} is too long.`);
  return trimmed;
}

/**
 * What:   Optional amount validator.
 * Input:  [value] and the field [name] for errors.
 * Output: A whole-sen amount (0 to MAX_AMOUNT_SEN), or null when absent.
 */
function optionalSen(value, name) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value < 0 || value > MAX_AMOUNT_SEN) {
    throw bad(`${name} is not a valid amount.`);
  }
  return value;
}

/**
 * What:   Validator for the bundle's shared map location.
 * Input:  The raw `location` map (lat, lng, address, district fields).
 * Output: The stored shape; throws when lat/lng are out of range.
 */
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

/**
 * What:   Validator for the optional bidding deadline.
 * Input:  Epoch millis (JSON has no date type), or null.
 * Output: A Timestamp, or null; throws unless it is in the future.
 */
function checkDeadline(value) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value <= Date.now()) {
    throw bad("The bidding deadline must be in the future.");
  }
  return Timestamp.fromMillis(value);
}

/**
 * What:   Validator for the shared photo URLs.
 * Input:  The raw `photoUrls` list, or null.
 * Output: The list (max MAX_PHOTOS non-empty strings), or [].
 */
function checkPhotos(raw) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_PHOTOS ||
      !raw.every((url) => typeof url === "string" && url !== "")) {
    throw bad("Those bundle photos are not valid.");
  }
  return raw;
}

/**
 * What:   Validator for a task's photo tags.
 * Input:  [raw] indexes into the shared photos, the [photoCount] and the
 *         task [position] label for errors.
 * Output: The unique, in-range indexes, or [].
 */
function checkPhotoIndexes(raw, photoCount, position) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || new Set(raw).size !== raw.length ||
      !raw.every((n) => Number.isInteger(n) && n >= 0 && n < photoCount)) {
    throw bad(`${position} has invalid photo tags.`);
  }
  return raw;
}

/**
 * What:   Validator for the task list.
 * Input:  The raw `tasks` list and the shared [photoCount].
 * Output: The stored shape of each task; throws unless there are 2 to 6 valid
 *         tasks (category, text, budget range, photo tags).
 */
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

/**
 * What:   Photo URLs per task.
 * Input:  The shared [photoUrls] and the checked [tasks].
 * Output: One URL list per task: its tagged photos plus any photo tagged to
 *         no task.
 */
function taskPhotoUrls(photoUrls, tasks) {
  const tagged = new Set(tasks.flatMap((t) => t.photoIndexes));
  return tasks.map((t) => photoUrls.filter((_, i) =>
    !tagged.has(i) || t.photoIndexes.includes(i)));
}

/**
 * What:   Validator for a createBundle payload.
 * Input:  The callable's raw [data].
 * Output: {title, description, location, photoUrls, deadline, tasks}; throws
 *         `invalid-argument` on the first bad field.
 * Notes:  Pure, so tests need no emulator.
 */
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

/**
 * What:   Callable that posts a bundle and one ordinary job per task.
 * Input:  {title, description, location, photoUrls?, deadlineMillis?, tasks}
 *         from BundleRepository.create().
 * Output: {bundleId, taskIds}; all docs are written in one batch.
 * Notes:  Only a non-suspended client may post.
 */
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
  throwIfSuspended(user);

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

/**
 * What:   Length limits for a bundle bid's message and duration text.
 * Output: MAX_MESSAGE_LEN and MAX_DURATION_LEN, in characters.
 */
const MAX_MESSAGE_LEN = 2000;
const MAX_DURATION_LEN = 40;

/**
 * What:   Bid-window check.
 * Input:  Bundle doc data.
 * Output: True while the bundle is open and not past its deadline.
 */
function bundleBiddingOpen(bundle) {
  return bundle.status === "open" &&
      (bundle.deadline == null || bundle.deadline.toMillis() > Date.now());
}

/**
 * What:   Validator for the price per picked task.
 * Input:  [raw] map of job id to sen.
 * Output: The map; throws unless it has 1 to 6 whole-sen prices above 0 and
 *         up to MAX_BID_SEN each.
 * Notes:  Keys are checked against the bundle's taskIds in submitBundleBid,
 *         since Firestore rules cannot check maps.
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

/**
 * What:   Sum of the per-task prices.
 * Input:  [taskPrices] map of job id to sen.
 * Output: Total sen.
 */
function taskTotal(taskPrices) {
  return Object.values(taskPrices).reduce((sum, sen) => sum + sen, 0);
}

/**
 * What:   Bundle price shared across the picked tasks.
 * Input:  [taskPrices] map of job id to sen and the [bundlePriceSen] total.
 * Output: Map of job id to sen that adds up to [bundlePriceSen].
 * How:    Each share is the floor of its proportion of the task total; the last
 *         task absorbs the rounding.
 */
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

/**
 * What:   Validator for a submitBundleBid payload.
 * Input:  The callable's raw [data].
 * Output: {taskPrices, taskTotalSen, bundlePriceSen, estimatedDuration,
 *         message}; throws `invalid-argument` on the first bad field.
 * How:    A bundle price must be above 0, below the task total, leave every
 *         task share at 1 sen or more, and the bid total stays within
 *         MAX_BID_SEN.
 * Notes:  Pure, so tests need no emulator.
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

/**
 * What:   Bidder eligibility guard.
 * Input:  Firestore [db] and the caller [uid].
 * Output: The caller's user data; throws `permission-denied` unless they are an
 *         approved provider who is not suspended.
 */
async function biddingProvider(db, uid) {
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "provider" || user.verificationStatus !== "approved") {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Only a verified provider can bid. Finish verification first.");
  }
  throwIfSuspended(user);
  return user;
}

/**
 * What:   Callable that saves a provider's sealed bid on a bundle.
 * Input:  {bundleId, taskPrices, bundlePriceSen?, estimatedDuration, message}
 *         from BundleBidRepository (bundle_bid_repository.dart).
 * Output: Writes `bundles/{id}/bundleBids/{uid}`; a re-bid edits it and adjusts
 *         each task's `bidCount`; a new bid notifies the requestor.
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

  await db.runTransaction(async (tx) => {
    const bundle = (await tx.get(bundleRef)).data();
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
    const [existing, ...taskSnaps] = await tx.getAll(bidRef, ...taskRefs);
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

});

/**
 * What:   Callable that withdraws the caller's pending bundle bid.
 * Input:  {bundleId} from BundleBidRepository.
 * Output: Deletes the bid and lowers each task's `bidCount`; refused once
 *         bidding closed or the bid was decided.
 */
exports.withdrawBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  await db.runTransaction(async (tx) => {
    const [bundleSnap, snap] = await tx.getAll(bundleRef, bidRef);
    if (!snap.exists) return; // already gone - nothing left to undo
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
    tx.delete(bidRef);
    Object.keys(existing.taskPrices || {}).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));
  });
});

/**
 * What:   Callable that cancels an open bundle.
 * Input:  {bundleId} from BundleRepository.cancelBundle().
 * Output: Bundle and its open tasks cancelled, pending bids closed and notified.
 */
exports.cancelBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);

  await db.runTransaction(async (tx) => {
    const bundle = (await tx.get(bundleRef)).data();
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

    taskSnaps.forEach((snap) => {
      if (snap.data()?.status !== "open") return;
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
  });
});

/**
 * What:   Scheduled sweep (every 6 hours) for overdue open bundles.
 * Input:  Bundles with status "open" and a deadline in the past.
 * Output: Each becomes "expired"; its pending bids are closed and notified.
 */
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
          // Re-read: an award may have landed since the query.
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

// Exported for tests; index.js re-exports the callables.
exports.validateBundle = validateBundle;
exports.validateBundleBid = validateBundleBid;
exports.bundleBiddingOpen = bundleBiddingOpen;
exports.splitBundlePrice = splitBundlePrice;

// Shared with the posting assist in index.js.
exports.CATEGORIES = CATEGORIES;
