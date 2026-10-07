// Picks who wins which task of a bundle. Pure engine (tests need no emulator),
// run on the server because awarding moves escrow money.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {callerUid, bad, docId, bundleBiddingOpen, splitBundlePrice} =
    require("./bundles");
const {notifyUser, writeFundedMilestone} = require("./common");

// Must match PlatformConfig.neutralTrustScore.
const NEUTRAL_TRUST = 700;

/** Every set of tasks a bid would accept, with what each set costs. */
// Any non-empty subset of the bid's tasks is an offer.
function offersFor(bid, taskIndex) {
  const priced = Object.keys(bid.taskPrices);
  const offers = [];
  for (let subset = 1; subset < (1 << priced.length); subset++) {
    const chosen = priced.filter((_, i) => (subset >> i) & 1);
    // Skip task ids the bundle no longer has (they would count as task 0).
    if (chosen.some((id) => !Object.hasOwn(taskIndex, id))) continue;
    const isWholeBid = chosen.length === priced.length;

    const amounts = isWholeBid && bid.bundlePriceSen != null ?
        splitBundlePrice(bid.taskPrices, bid.bundlePriceSen) :
        Object.fromEntries(chosen.map((id) => [id, bid.taskPrices[id]]));
    offers.push({
      providerId: bid.providerId,
      taskAmountsSen: amounts,
      taskMask: chosen.reduce((mask, id) => mask | (1 << taskIndex[id]), 0),
      priceSen: Object.values(amounts).reduce((sum, sen) => sum + sen, 0),
    });
  }
  return offers;
}

/** Trust Score weighted by how much money each provider is paid. */
function weightedTrust(awards, trustByProvider) {
  let money = 0;
  let weighted = 0;
  awards.forEach((award) => {
    const total = Object.values(award.taskAmountsSen)
        .reduce((sum, sen) => sum + sen, 0);
    money += total;
    weighted += (trustByProvider[award.providerId] || 0) * total;
  });
  return money === 0 ? 0 : Math.floor(weighted / money);
}

/** Cheaper wins; on an exact tie, the higher weighted Trust Score. */
function beats(candidate, existing, trustByProvider) {
  if (!existing) return true;
  if (candidate.costSen !== existing.costSen) {
    return candidate.costSen < existing.costSen;
  }
  return weightedTrust(candidate.awards, trustByProvider) >
      weightedTrust(existing.awards, trustByProvider);
}

/** How many tasks a coverage mask holds. */
function countBits(value) {
  let count = 0;
  for (let rest = value; rest !== 0; rest >>= 1) count += rest & 1;
  return count;
}

/** The most a fewer-provider option may cost above the cheapest one. */
// Both limits apply; the smaller one wins.
function allowanceSen(cheapestSen, capPct, capSen) {
  return Math.min(Math.floor(cheapestSen * capPct / 100), capSen);
}

/** Best award with exactly `k` providers within `ceiling` (top Trust Score). */
// Needed because the DP below keeps only the cheapest award per state.
function bestWithinCap({bidOffers, trustByProvider, coverage, k, ceiling}) {
  let best = null;
  const awards = [];

  function consider(mask, providers, costSen) {
    if (providers !== k || countBits(mask) !== coverage) return;
    const candidate = {costSen, awards: [...awards]};
    if (!best) {
      best = candidate;
      return;
    }
    const bestTrust = weightedTrust(best.awards, trustByProvider);
    const candidateTrust = weightedTrust(candidate.awards, trustByProvider);
    if (candidateTrust > bestTrust ||
        (candidateTrust === bestTrust && candidate.costSen < best.costSen)) {
      best = candidate;
    }
  }

  function dfs(i, mask, providers, costSen) {
    if (providers > k || costSen > ceiling) return; // prune
    if (i === bidOffers.length) {
      consider(mask, providers, costSen);
      return;
    }
    dfs(i + 1, mask, providers, costSen); // skip this bid entirely
    bidOffers[i].forEach((offer) => {
      if (mask & offer.taskMask) return; // a task here is already taken
      awards.push({
        providerId: offer.providerId,
        taskAmountsSen: offer.taskAmountsSen,
      });
      dfs(i + 1, mask | offer.taskMask, providers + 1,
          costSen + offer.priceSen);
      awards.pop();
    });
  }

  dfs(0, 0, 0, 0);
  return best;
}

/** Trust Score snapshot per bidder, keyed by provider id. */
function trustByProviderFrom(bids) {
  return Object.fromEntries(bids.map((b) => [b.providerId, b.trustScore || 0]));
}

/** Builds the three options the requestor chooses between. */
// Coverage first, then cost. Returns [] when nothing can be awarded.
function buildAwardOptions({tasks, bids, capPct, capSen}) {
  const trustByProvider = trustByProviderFrom(bids);
  const taskIndex = Object.fromEntries(tasks.map((t, i) => [t.id, i]));
  const maskCount = 1 << tasks.length;

  // Built once and reused by the DP and the Recommended search.
  const bidOffers = bids.map((bid) => offersFor(bid, taskIndex));

  // best[covered tasks][providers used] = cheapest way to get there.
  let best = Array.from({length: maskCount},
      () => new Array(tasks.length + 1).fill(null));
  best[0][0] = {costSen: 0, awards: []};

  // One bid at a time, so no provider appears twice in an award.
  bidOffers.forEach((offers) => {
    const next = best.map((row) => [...row]);
    for (let mask = 0; mask < maskCount; mask++) {
      for (let used = 0; used < tasks.length; used++) {
        const soFar = best[mask][used];
        if (!soFar) continue;
        offers.forEach((offer) => {
          if (mask & offer.taskMask) return; // a task here is already taken
          const grown = mask | offer.taskMask;
          const candidate = {
            costSen: soFar.costSen + offer.priceSen,
            awards: [...soFar.awards, {
              providerId: offer.providerId,
              taskAmountsSen: offer.taskAmountsSen,
            }],
          };
          if (beats(candidate, next[grown][used + 1], trustByProvider)) {
            next[grown][used + 1] = candidate;
          }
        });
      }
    }
    best = next;
  });

  // The most tasks any combination of these bids can cover.
  let bestCoverage = 0;
  for (let mask = 0; mask < maskCount; mask++) {
    if (best[mask].some(Boolean) && countBits(mask) > bestCoverage) {
      bestCoverage = countBits(mask);
    }
  }

  // Of the awards with that coverage, the cheapest for each number of providers.
  const cheapestByCount = new Array(tasks.length + 1).fill(null);
  for (let mask = 0; mask < maskCount; mask++) {
    if (countBits(mask) !== bestCoverage) continue;
    best[mask].forEach((partial, used) => {
      if (partial && beats(partial, cheapestByCount[used], trustByProvider)) {
        cheapestByCount[used] = partial;
      }
    });
  }

  let cheapest = null;
  cheapestByCount.forEach((partial) => {
    if (partial && beats(partial, cheapest, trustByProvider)) {
      cheapest = partial;
    }
  });
  // The empty award is always in the table, so this catches "nothing to award".
  if (!cheapest || cheapest.awards.length === 0) return [];

  const fewest = cheapestByCount.find(Boolean);

  // Recommended: fewest providers within the cap, then Trust Score, then price.
  const ceiling =
      cheapest.costSen + allowanceSen(cheapest.costSen, capPct, capSen);
  const k = cheapestByCount.findIndex((p) => p && p.costSen <= ceiling);
  const recommended = bestWithinCap({
    bidOffers, trustByProvider, coverage: bestCoverage, k, ceiling,
  }) || cheapestByCount[k] || cheapest;

  const toOption = (key, label, partial) => option({
    key, label, partial, tasks, bids, trustByProvider,
    cheapestCostSen: cheapest.costSen,
  });
  return [
    toOption("cheapest", "Cheapest", cheapest),
    toOption("fewest", "Fewest providers", fewest),
    toOption("recommended", "Recommended", recommended),
  ];
}

/** Turns a part-built award into the card the requestor sees. */
function option(
    {key, label, partial, tasks, bids, trustByProvider, cheapestCostSen}) {
  const nameByProvider = Object.fromEntries(
      bids.map((b) => [b.providerId, b.providerName || "Provider"]));
  const providerByTask = {};
  partial.awards.forEach((award) => {
    Object.keys(award.taskAmountsSen)
        .forEach((taskId) => (providerByTask[taskId] = award.providerId));
  });

  return {
    key,
    label,
    totalSen: partial.costSen,
    providerCount: partial.awards.length,
    premiumSen: partial.costSen - cheapestCostSen,
    weightedTrust: weightedTrust(partial.awards, trustByProvider),
    // Only shown when every hired provider has earned a visible score.
    trustVisible: partial.awards.length > 0 && partial.awards.every((a) =>
      bids.some((b) => b.providerId === a.providerId && b.scoreVisible)),
    uncoveredTaskIds: tasks.filter((t) => !providerByTask[t.id])
        .map((t) => t.id),
    awards: partial.awards.map((award) => ({
      providerId: award.providerId,
      providerName: nameByProvider[award.providerId] || "Provider",
      taskAmountsSen: award.taskAmountsSen,
    })),
  };
}

/** Prices and checks a hand-made award, before the server moves any money. */
// Uses Map lookups so ids like "__proto__" cannot hit Object.prototype.
function checkManualAward({tasks, bids, providerByTaskId}) {
  const problems = [];
  const bidByProvider = new Map(bids.map((b) => [b.providerId, b]));
  const taskById = new Map(tasks.map((t) => [t.id, t]));

  const taskIdsByProvider = new Map();
  Object.entries(providerByTaskId).forEach(([taskId, providerId]) => {
    if (!taskById.has(taskId)) {
      problems.push(`Unknown task "${taskId}".`);
      return;
    }
    if (!taskIdsByProvider.has(providerId)) {
      taskIdsByProvider.set(providerId, []);
    }
    taskIdsByProvider.get(providerId).push(taskId);
  });

  const awards = [];
  taskIdsByProvider.forEach((wonTaskIds, providerId) => {
    const bid = bidByProvider.get(providerId);
    if (!bid) {
      problems.push(`No bid from provider "${providerId}".`);
      return;
    }
    const unpriced =
        wonTaskIds.filter((id) => !Object.hasOwn(bid.taskPrices, id));
    if (unpriced.length > 0) {
      const titles =
          unpriced.map((id) => taskById.get(id).title).join(", ");
      problems.push(`${bid.providerName} never priced ${titles}.`);
      return;
    }
    const isWholeBid =
        wonTaskIds.length === Object.keys(bid.taskPrices).length;
    const amounts = isWholeBid && bid.bundlePriceSen != null ?
        splitBundlePrice(bid.taskPrices, bid.bundlePriceSen) :
        Object.fromEntries(wonTaskIds.map((id) => [id, bid.taskPrices[id]]));
    awards.push({providerId, taskAmountsSen: amounts});
  });

  return {awards, problems};
}

/** What a set of awards costs, added up across every task in them. */
function totalSenOf(awards) {
  return awards.reduce((sum, award) =>
    sum + Object.values(award.taskAmountsSen)
        .reduce((inner, sen) => inner + sen, 0), 0);
}

/** Prices the requestor's hand-picked award, or returns the problems with it. */
function manualOption({tasks, bids, providerByTaskId, cheapestCostSen}) {
  const {awards, problems} = checkManualAward({tasks, bids, providerByTaskId});
  if (problems.length > 0) return {manual: null, problems};
  const manual = option({
    key: "manual",
    label: "Your pick",
    partial: {costSen: totalSenOf(awards), awards},
    tasks,
    bids,
    trustByProvider: trustByProviderFrom(bids),
    cheapestCostSen,
  });
  return {manual, problems: []};
}

/** The shape the award engine needs from one task's job document. */
function taskFromSnap(snap) {
  return {
    id: snap.id,
    title: snap.data().title || "Task",
    status: snap.data().status,
  };
}

/** The shape the award engine needs from a bundle bid, incl. Trust Score. */
function bidFromSnap(doc) {
  return {
    providerId: doc.id,
    providerName: doc.data().providerName || "Provider",
    // A hidden ("New") score counts as the neutral baseline when ranking.
    trustScore: doc.data().providerScoreVisible === true ?
        doc.data().providerTrustScore || 0 :
        NEUTRAL_TRUST,
    scoreVisible: doc.data().providerScoreVisible === true,
    taskPrices: doc.data().taskPrices || {},
    bundlePriceSen: doc.data().bundlePriceSen == null ?
        null :
        doc.data().bundlePriceSen,
  };
}

/** Reads a bundle, its tasks and its pending bids, in the shapes above. */
async function readBundleForAward(db, bundleId, uid) {
  const bundleSnap = await db.doc(`bundles/${bundleId}`).get();
  const bundle = bundleSnap.data();
  if (!bundle) {
    throw new functions.https.HttpsError(
        "not-found", "That bundle no longer exists.");
  }
  if (bundle.requestorId !== uid) {
    throw new functions.https.HttpsError(
        "permission-denied", "Only the client who posted it can award " +
        "this bundle.");
  }
  const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
  const taskSnaps = taskIds.length === 0 ?
      [] :
      await db.getAll(...taskIds.map((id) => db.doc(`jobs/${id}`)));
  const tasks = taskSnaps.filter((s) => s.exists).map(taskFromSnap);

  const bidSnaps =
      await db.collection(`bundles/${bundleId}/bundleBids`).get();
  const bids = bidSnaps.docs
      .filter((doc) => doc.data().status === "pending")
      .map(bidFromSnap);

  return {bundle, tasks, bids};
}

/** The 3 award options for the requestor, plus "Your pick" if one is sent. */
exports.previewBundleAward = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");
  const picks = data?.providerByTaskId == null ?
      null : checkPicks(data.providerByTaskId);
  const db = admin.firestore();
  const {bundle, tasks, bids} = await readBundleForAward(db, bundleId, uid);

  // Checked here so the app does not show options awardBundle would refuse.
  if (!bundleBiddingOpen(bundle)) {
    throw new functions.https.HttpsError(
        "failed-precondition",
        "Bidding on this bundle has closed, so it can no longer be " +
        "awarded.");
  }

  // Uses the cap saved on the bundle when posted, not today's PlatformConfig.
  const openTasks = tasks.filter((t) => t.status === "open");
  const options = buildAwardOptions({
    tasks: openTasks,
    bids,
    capPct: bundle.consolidationCapPct || 0,
    capSen: bundle.consolidationCapSen || 0,
  });
  if (picks == null) return {options, bidCount: bids.length};

  const {manual, problems} = manualOption({
    tasks: openTasks,
    bids,
    providerByTaskId: picks,
    cheapestCostSen: options.length > 0 ? options[0].totalSen : 0,
  });
  return {options, bidCount: bids.length, manual, problems};
});

/** Days a released task gets to find a provider; the requestor can override. */
const RELEASED_DEADLINE_DAYS = 7;

/** The new deadline for tasks nobody wins, as a Timestamp. */
function releasedDeadline(millis) {
  if (millis == null) {
    return Timestamp.fromMillis(
        Date.now() + RELEASED_DEADLINE_DAYS * 24 * 60 * 60 * 1000);
  }
  if (!Number.isInteger(millis) || millis <= Date.now()) {
    throw bad("The new deadline for released tasks must be in the future.");
  }
  return Timestamp.fromMillis(millis);
}

/** The write for an unawarded task: released to bidding, or cancelled. */
// Dropping uses the same fields as cancelBundle.
function leftoverTaskUpdate({drop, uid, deadline}) {
  if (drop) {
    return {
      status: "cancelled",
      cancelledBy: uid,
      cancelledAt: FieldValue.serverTimestamp(),
      cancellationReason:
          "The client awarded the rest of the bundle and dropped this task.",
    };
  }
  return {deadline, bidCount: 0, releasedAt: FieldValue.serverTimestamp()};
}

/** The requestor's task-to-provider picks, checked for shape only. */
function checkPicks(raw) {
  const picks = raw == null ? {} : raw;
  if (typeof picks !== "object" || Array.isArray(picks)) {
    throw bad("Pick a provider for at least one task.");
  }
  const entries = Object.entries(picks);
  if (entries.length === 0) throw bad("Pick a provider for at least one task.");
  if (entries.some(([, providerId]) => typeof providerId !== "string")) {
    throw bad("That award is not valid.");
  }
  return Object.fromEntries(entries);
}

/** Awards a whole bundle in one transaction. */
// Prices are re-read from stored bids; the client only says who wins what.
exports.awardBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");
  const picks = checkPicks(data?.providerByTaskId);
  const dropUnawarded = data?.dropUnawarded === true;
  // A dropped task needs no new deadline.
  const deadline = dropUnawarded ?
      null : releasedDeadline(data?.releasedDeadlineMillis);
  const expectedTotalSen = data?.expectedTotalSen;

  const db = admin.firestore();

  const result = await db.runTransaction(async (tx) => {
    const bundleRef = db.doc(`bundles/${bundleId}`);
    const walletRef = db.doc(`users/${uid}`);

    // Read the bundle first: a transaction cannot read after it writes.
    const bundleSnap = await tx.get(bundleRef);
    const bundle = bundleSnap.data();
    if (bundle && bundle.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the client who posted it can award " +
          "this bundle.");
    }
    if (!bundle || !bundleBiddingOpen(bundle)) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "This bundle is no longer open for awarding.", {reason: "race"});
    }

    const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
    const taskRefs = taskIds.map((id) => db.doc(`jobs/${id}`));
    const [walletSnap, ...taskSnaps] =
        await tx.getAll(walletRef, ...taskRefs);

    // Read before any writes: a suspended requestor is refused first.
    const wallet = walletSnap.data() || {};
    if (wallet.suspended === true) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Your account is suspended. Contact support if you think this " +
          "is a mistake.");
    }

    // Queried inside the transaction so bids added after the preview count.
    const bidsSnap = await tx.get(db.collection(
        `bundles/${bundleId}/bundleBids`).where("status", "==", "pending"));

    const liveTasks = taskSnaps.filter((s) => s.exists).map(taskFromSnap);
    const openTasks = liveTasks.filter((t) => t.status === "open");
    const openIds = new Set(openTasks.map((t) => t.id));
    if (Object.keys(picks).some((taskId) => !openIds.has(taskId))) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "One of those tasks is no longer open.", {reason: "race"});
    }

    const bids = bidsSnap.docs.map(bidFromSnap);

    // The same check the preview ran, against the bids as they stand now.
    const {awards, problems} = checkManualAward(
        {tasks: openTasks, bids, providerByTaskId: picks});
    if (problems.length > 0) throw bad(problems[0]);

    // Safety net: a partial award could still price a task at RM 0.
    const zeroed = awards.some((award) =>
      Object.values(award.taskAmountsSen).some((sen) => sen < 1));
    if (zeroed) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "One of these tasks would be awarded at RM 0.");
    }

    const totalSen = awards.reduce((sum, award) =>
      sum + Object.values(award.taskAmountsSen)
          .reduce((inner, sen) => inner + sen, 0), 0);
    if (expectedTotalSen != null && expectedTotalSen !== totalSen) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "The bids changed while you were choosing. Check the options again.",
          {reason: "changed", totalSen});
    }

    const available =
        (wallet.walletBalanceSen || 0) - (wallet.escrowLockedSen || 0);
    if (available < totalSen) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Insufficient available balance to award this bundle.", {
            reason: "insufficient_balance",
            shortfallSen: totalSen - available,
            availableSen: available,
            requiredSen: totalSen,
          });
    }

    // Writes. Each awarded task becomes an ordinary one-provider job.
    const wonTaskIds = new Set();
    awards.forEach((award) => {
      const bid = bids.find((b) => b.providerId === award.providerId);
      Object.entries(award.taskAmountsSen).forEach(([taskId, amountSen]) => {
        wonTaskIds.add(taskId);
        const taskRef = db.doc(`jobs/${taskId}`);
        tx.update(taskRef, {
          status: "in_progress",
          acceptedProviderId: award.providerId,
          acceptedProviderName: bid.providerName,
          acceptedBidAmountSen: amountSen,
          fundedAtAward: true,
          schedulingRequired: true,
        });
        writeFundedMilestone(tx, {
          jobRef: taskRef,
          title: liveTasks.find((t) => t.id === taskId).title,
          requestorId: uid,
          providerId: award.providerId,
          amountSen,
        });
      });
      notifyUser(tx, award.providerId, {
        type: "bid_accepted",
        title: "You won a bundle bid!",
        body: `You won ${Object.keys(award.taskAmountsSen).length} task(s) ` +
            `of "${bundle.title || "a bundle"}". The payment is secured in ` +
            "escrow - you can get started.",
        route: `/jobs/${Object.keys(award.taskAmountsSen)[0]}`,
      });
    });

    // The money moves into escrow once, for the whole award.
    tx.update(walletRef, {
      walletBalanceSen: (wallet.walletBalanceSen || 0) - totalSen,
    });

    // Every bid lands on accepted, partly accepted or rejected.
    bidsSnap.docs.forEach((doc) => {
      const award = awards.find((a) => a.providerId === doc.id);
      const priced = Object.keys(doc.data().taskPrices || {}).length;
      const won = award ? Object.keys(award.taskAmountsSen).length : 0;
      tx.update(doc.ref, {
        status: won === 0 ?
            "rejected" :
            won === priced ? "accepted" : "partly_accepted",
      });
    });

    // Unawarded tasks go back to bidding with a new deadline and `releasedAt`,
    // or are cancelled if the requestor only wanted part of the bundle.
    const leftoverTaskIds = openTasks.map((t) => t.id)
        .filter((id) => !wonTaskIds.has(id));
    leftoverTaskIds.forEach((taskId) => {
      tx.update(db.doc(`jobs/${taskId}`),
          leftoverTaskUpdate({drop: dropUnawarded, uid, deadline}));
    });

    // Plain fields (no counter doc) so admins can count split awards.
    const awardedProviderCount =
        new Set(awards.map((a) => a.providerId)).size;
    tx.update(bundleRef, {
      status: "awarded",
      awardedAt: FieldValue.serverTimestamp(),
      awardedTotalSen: totalSen,
      awardedProviderCount,
      splitAward: awardedProviderCount > 1,
      releasedTaskCount: dropUnawarded ? 0 : leftoverTaskIds.length,
      droppedTaskCount: dropUnawarded ? leftoverTaskIds.length : 0,
    });

    return {
      taskCount: wonTaskIds.size,
      providerCount: awards.length,
      totalSen,
      releasedTaskIds: dropUnawarded ? [] : leftoverTaskIds,
      droppedTaskIds: dropUnawarded ? leftoverTaskIds : [],
    };
  });

  return result;
});

// Exported for tests only; index.js re-exports just the callables.
exports.splitBundlePrice = splitBundlePrice;
exports.offersFor = offersFor;
exports.buildAwardOptions = buildAwardOptions;
exports.checkManualAward = checkManualAward;
exports.allowanceSen = allowanceSen;
exports.readBundleForAward = readBundleForAward;
exports.manualOption = manualOption;
exports.leftoverTaskUpdate = leftoverTaskUpdate;
