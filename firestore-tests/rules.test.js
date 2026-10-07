/**
 * Security-rules test suite for `firestore.rules`.
 *
 * These tests exercise the *real* rules engine via the Firestore emulator
 * (through `@firebase/rules-unit-testing`) - unlike the Dart widget tests,
 * which run against in-memory fakes and never evaluate a single rule. Every
 * `it()` below proves one specific ALLOW or DENY the rules claim to enforce.
 *
 * Run with the emulator (from this directory):
 *   npx firebase-tools emulators:exec --only firestore "npm test"
 *
 * See ./README.md for details.
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  collection,
  collectionGroup,
  query,
  where,
  setDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  getDocs,
  serverTimestamp,
  Timestamp,
} = require("firebase/firestore");

const RULES_PATH = path.resolve(__dirname, "../firestore.rules");

/** @type {import("@firebase/rules-unit-testing").RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "fairbid-test",
    firestore: {
      rules: fs.readFileSync(RULES_PATH, "utf8"),
    },
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

afterEach(async () => {
  await testEnv.clearFirestore();
});

/** Seed one or more documents bypassing all security rules. */
async function seed(docs) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const [path_, data] of docs) {
      await setDoc(doc(db, path_), data);
    }
  });
}

/** Firestore client authenticated as the given uid. */
function dbAs(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

// ---------------------------------------------------------------------------
// Bids - jobs/{jobId}/bids/{bidId}, bidId == provider uid.
// ---------------------------------------------------------------------------
describe("Bids", () => {
  const JOB_ID = "job1";
  const PROVIDER = "provider1"; // trustScore 42, scoreVisible true, approved
  const REQUESTOR = "requestor1";

  const validBid = (overrides = {}) => ({
    providerId: PROVIDER,
    amountSen: 50000,
    providerTrustScore: 42,
    providerScoreVisible: true,
    status: "pending",
    ...overrides,
  });

  beforeEach(async () => {
    await seed([
      [
        `users/${PROVIDER}`,
        {
          role: "provider",
          verificationStatus: "approved",
          trustScore: 42,
          trust: { scoreVisible: true },
        },
      ],
      [`users/${REQUESTOR}`, { role: "requestor" }],
      [`jobs/${JOB_ID}`, { requestorId: REQUESTOR, status: "open" }],
    ]);
  });

  it("allows create with a valid amount and a truthful trust snapshot on an open job", async () => {
    const db = dbAs(PROVIDER);
    await assertSucceeds(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`), validBid()));
  });

  it("denies create once the job's bidding deadline has passed", async () => {
    const EXPIRED_JOB = "job1-expired";
    await seed([
      [`jobs/${EXPIRED_JOB}`, {
        requestorId: REQUESTOR,
        status: "open",
        deadline: new Date(Date.now() - 60_000), // a minute ago
      }],
    ]);
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${EXPIRED_JOB}/bids/${PROVIDER}`), validBid()));
  });

  it("allows create while the job's bidding deadline is still in the future", async () => {
    const FUTURE_JOB = "job1-future";
    await seed([
      [`jobs/${FUTURE_JOB}`, {
        requestorId: REQUESTOR,
        status: "open",
        deadline: new Date(Date.now() + 3_600_000), // an hour ahead
      }],
    ]);
    const db = dbAs(PROVIDER);
    await assertSucceeds(
        setDoc(doc(db, `jobs/${FUTURE_JOB}/bids/${PROVIDER}`), validBid()));
  });

  it("denies create when amountSen is negative", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({amountSen: -100})));
  });

  it("denies create when amountSen is zero", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({amountSen: 0})));
  });

  it("denies create when amountSen is non-integer", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({amountSen: 12.5})));
  });

  it("denies create when amountSen exceeds the 100,000,000 cap", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({amountSen: 100000001})));
  });

  it("denies create when providerTrustScore doesn't match the provider's stored profile", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({providerTrustScore: 999})));
  });

  it("denies create when providerScoreVisible doesn't match the provider's stored profile", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({providerScoreVisible: false})));
  });

  it("denies create when providerPhotoUrl doesn't match the provider's stored profile", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PROVIDER}`),
            validBid({providerPhotoUrl: "https://evil.example/stolen.jpg"})));
  });

  it("allows create with a providerPhotoUrl matching the provider's stored profile", async () => {
    const PHOTO_PROVIDER = "provider1-with-photo";
    await seed([
      [
        `users/${PHOTO_PROVIDER}`,
        {
          role: "provider",
          verificationStatus: "approved",
          trustScore: 42,
          trust: {scoreVisible: true},
          profilePhotoUrl: "https://example.com/me.jpg",
        },
      ],
    ]);
    const db = dbAs(PHOTO_PROVIDER);
    await assertSucceeds(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${PHOTO_PROVIDER}`), validBid({
          providerId: PHOTO_PROVIDER,
          providerPhotoUrl: "https://example.com/me.jpg",
        })));
  });

  it("denies create by a non-approved provider", async () => {
    const UNAPPROVED = "provider2";
    await seed([
      [
        `users/${UNAPPROVED}`,
        {
          role: "provider",
          verificationStatus: "pending",
          trustScore: 0,
          trust: {scoreVisible: false},
        },
      ],
    ]);
    const db = dbAs(UNAPPROVED);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/bids/${UNAPPROVED}`), validBid({
          providerId: UNAPPROVED,
          providerTrustScore: 0,
          providerScoreVisible: false,
        })));
  });

  it("denies create when the job isn't open", async () => {
    const CLOSED_JOB = "job1-in-progress";
    await seed([
      [`jobs/${CLOSED_JOB}`, {requestorId: REQUESTOR, status: "in_progress"}],
    ]);
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${CLOSED_JOB}/bids/${PROVIDER}`), validBid()));
  });
});

// ---------------------------------------------------------------------------
// Reviews - users/{revieweeId}/reviews/{reviewId}, reviewId == {jobId}_{reviewerId}.
// ---------------------------------------------------------------------------
describe("Reviews", () => {
  const REQUESTOR = "requestor2";
  const PROVIDER = "provider2";
  const STRANGER = "stranger1";
  const COMPLETED_JOB = "job2";
  const OPEN_JOB = "job2-open";

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      [`users/${STRANGER}`, {role: "requestor"}],
      [
        `jobs/${COMPLETED_JOB}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "completed",
        },
      ],
      [
        `jobs/${OPEN_JOB}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "open",
        },
      ],
    ]);
  });

  it("allows a valid 1-5 review at the correct doc id by a participant on a completed job", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${COMPLETED_JOB}_${REQUESTOR}`;
    await assertSucceeds(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: COMPLETED_JOB,
          rating: 5,
        }));
  });

  for (const rating of [0, 6, 3.5]) {
    it(`denies create when rating (${rating}) is outside 1..5 or non-integer`, async () => {
      const db = dbAs(REQUESTOR);
      const reviewId = `${COMPLETED_JOB}_${REQUESTOR}`;
      await assertFails(
          setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
            reviewerId: REQUESTOR,
            jobId: COMPLETED_JOB,
            rating,
          }));
    });
  }

  it("denies create when the doc id isn't {jobId}_{reviewerId} (spam vector)", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(
        setDoc(doc(db, `users/${PROVIDER}/reviews/not-the-right-id`), {
          reviewerId: REQUESTOR,
          jobId: COMPLETED_JOB,
          rating: 4,
        }));
  });

  it("denies create when the job isn't completed", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${OPEN_JOB}_${REQUESTOR}`;
    await assertFails(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: OPEN_JOB,
          rating: 4,
        }));
  });

  it("denies create when the reviewer isn't a participant of the job", async () => {
    const db = dbAs(STRANGER);
    const reviewId = `${COMPLETED_JOB}_${STRANGER}`;
    await assertFails(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: STRANGER,
          jobId: COMPLETED_JOB,
          rating: 4,
        }));
  });

  it("denies create on your own profile", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${COMPLETED_JOB}_${REQUESTOR}`;
    await assertFails(
        setDoc(doc(db, `users/${REQUESTOR}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: COMPLETED_JOB,
          rating: 4,
        }));
  });
});

// ---------------------------------------------------------------------------
// Reviews on a bundled task - one review per reviewer per counterparty per
// bundle (not per task), so the doc id is keyed to the bundle.
// ---------------------------------------------------------------------------
describe("Reviews - bundled tasks", () => {
  const REQUESTOR = "requestor3";
  const PROVIDER = "provider3";
  const BUNDLE_ID = "bundle-rev";
  const TASK_A = "task-rev-a";
  const TASK_B = "task-rev-b";

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      [
        `bundles/${BUNDLE_ID}`,
        {requestorId: REQUESTOR, status: "awarded", taskIds: [TASK_A, TASK_B]},
      ],
      [
        `jobs/${TASK_A}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "completed",
          bundleId: BUNDLE_ID,
        },
      ],
      [
        `jobs/${TASK_B}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "completed",
          bundleId: BUNDLE_ID,
        },
      ],
    ]);
  });

  it("allows a bundle-keyed id for a review on a bundled task", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${BUNDLE_ID}_${REQUESTOR}`;
    await assertSucceeds(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: TASK_A,
          rating: 5,
        }));
  });

  it("denies a job-keyed id for a review on a bundled task", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${TASK_A}_${REQUESTOR}`;
    await assertFails(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: TASK_A,
          rating: 5,
        }));
  });

  it("denies a second review for another task of the same bundle and pair", async () => {
    const db = dbAs(REQUESTOR);
    const reviewId = `${BUNDLE_ID}_${REQUESTOR}`;
    await assertSucceeds(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: TASK_A,
          rating: 5,
        }));
    // The doc now exists, so this hits the doc-exists write path, which the
    // update rule restricts to flagging - not a second, differently-scored
    // review for the other task.
    await assertFails(
        setDoc(doc(db, `users/${PROVIDER}/reviews/${reviewId}`), {
          reviewerId: REQUESTOR,
          jobId: TASK_B,
          rating: 4,
        }));
  });
});

// ---------------------------------------------------------------------------
// Bundles - bundles/{bundleId} plus the bundle fields on a task job.
//
// A bundle and its tasks are authored only by the createBundle Cloud Function
// (admin SDK, bypasses rules), so every client write here must be denied -
// and the tasks of an open bundle must refuse ordinary per-job bids, which
// belong at bundles/{id}/bundleBids/{uid} instead.
// ---------------------------------------------------------------------------
describe("Bundles", () => {
  const BUNDLE_ID = "bundle1";
  const TASK_ID = "task1";
  const PROVIDER = "provider1"; // trustScore 42, scoreVisible true, approved
  const REQUESTOR = "requestor1";

  const validBid = (overrides = {}) => ({
    providerId: PROVIDER,
    amountSen: 50000,
    providerTrustScore: 42,
    providerScoreVisible: true,
    status: "pending",
    ...overrides,
  });

  const openBundle = {
    requestorId: REQUESTOR,
    status: "open",
    title: "Bathroom refresh",
    taskIds: [TASK_ID],
    consolidationCapPct: 5,
    consolidationCapSen: 50000,
  };

  beforeEach(async () => {
    await seed([
      [
        `users/${PROVIDER}`,
        {
          role: "provider",
          verificationStatus: "approved",
          trustScore: 42,
          trust: {scoreVisible: true},
        },
      ],
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`bundles/${BUNDLE_ID}`, openBundle],
      [`jobs/${TASK_ID}`, {
        requestorId: REQUESTOR,
        status: "open",
        bundleId: BUNDLE_ID,
        bundleOrder: 0,
      }],
      // An ordinary, bundle-free job, so every regression check below proves
      // single-task posting still behaves exactly as it did.
      [`jobs/plain1`, {requestorId: REQUESTOR, status: "open"}],
    ]);
  });

  it("lets any signed-in user read a bundle", async () => {
    await assertSucceeds(getDoc(doc(dbAs(PROVIDER), `bundles/${BUNDLE_ID}`)));
  });

  it("denies read to a signed-out visitor", async () => {
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, `bundles/${BUNDLE_ID}`)));
  });

  it("denies a requestor writing a bundle directly (createBundle only)", async () => {
    await assertFails(setDoc(doc(dbAs(REQUESTOR), "bundles/forged"), {
      requestorId: REQUESTOR,
      status: "open",
      taskIds: [],
    }));
  });

  it("denies the owner editing their own bundle", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}`), {status: "cancelled"}));
  });

  it("denies re-stamping the consolidation cap an award is judged against", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}`),
        {consolidationCapPct: 90}));
  });

  it("denies deleting a bundle, even by its owner", async () => {
    await assertFails(deleteDoc(doc(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}`)));
  });

  it("denies posting a job that claims bundle membership", async () => {
    await assertFails(setDoc(doc(dbAs(REQUESTOR), "jobs/forged"), {
      requestorId: REQUESTOR,
      status: "open",
      bundleId: BUNDLE_ID,
      bundleOrder: 1,
    }));
  });

  it("denies the owner grafting bundleId onto an existing plain job", async () => {
    await assertFails(
        updateDoc(doc(dbAs(REQUESTOR), "jobs/plain1"), {bundleId: BUNDLE_ID}));
  });

  it("denies the owner re-ordering a bundle task", async () => {
    await assertFails(updateDoc(doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {
      bundleOrder: 3,
    }));
  });

  it("denies the owner writing releasedAt on their task", async () => {
    // Server-owned, like bundleId: only awardBundle (admin SDK) sets it,
    // when a task goes unawarded back to ordinary bidding.
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {releasedAt: new Date()}));
  });

  it("still lets the owner edit an ordinary field on a bundle task", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {title: "Re-tile the shower"}));
  });

  it("denies an ordinary per-job bid while the task's bundle is open", async () => {
    await assertFails(setDoc(
        doc(dbAs(PROVIDER), `jobs/${TASK_ID}/bids/${PROVIDER}`), validBid()));
  });

  it("allows an ordinary per-job bid once the bundle is no longer open", async () => {
    // The phase-4 shape: an unawarded task released back to the normal flow.
    await seed([[`bundles/${BUNDLE_ID}`, {...openBundle, status: "awarded"}]]);
    await assertSucceeds(setDoc(
        doc(dbAs(PROVIDER), `jobs/${TASK_ID}/bids/${PROVIDER}`), validBid()));
  });

  it("leaves bidding on an ordinary single-task job exactly as it was", async () => {
    await assertSucceeds(setDoc(
        doc(dbAs(PROVIDER), `jobs/plain1/bids/${PROVIDER}`), validBid()));
  });

  it("denies a client reading or writing a completionCounts marker", async () => {
    // Server-owned by onJobCompleted (admin SDK); no rule matches this
    // subcollection, so it falls to the default deny.
    const db = dbAs(PROVIDER);
    await assertFails(
        getDoc(doc(db, `bundles/${BUNDLE_ID}/completionCounts/${PROVIDER}`)));
    await assertFails(setDoc(
        doc(db, `bundles/${BUNDLE_ID}/completionCounts/${PROVIDER}`),
        {jobId: TASK_ID, at: serverTimestamp()}));
  });
});


// ---------------------------------------------------------------------------
// User profile self-writes - users/{uid}.
// ---------------------------------------------------------------------------
describe("User profile self-writes", () => {
  const UID = "user1";

  const baseline = () => ({
    role: "requestor",
    displayName: "Old Name",
    phone: "000",
    bio: "hi",
    trustScore: 10,
    trust: {scoreVisible: true},
    ratingSum: 5,
    ratingCount: 1,
    jobsCompleted: 2,
    disputesLost: 0,
    walletBalanceSen: 1000,
    escrowLockedSen: 0,
  });

  beforeEach(async () => {
    await seed([[`users/${UID}`, baseline()]]);
  });

  it("allows a self-update to ordinary fields", async () => {
    const db = dbAs(UID);
    await assertSucceeds(updateDoc(doc(db, `users/${UID}`), {
      displayName: "New Name",
      phone: "111",
      bio: "updated bio",
    }));
  });

  const forgedFieldPatches = [
    {trustScore: 999},
    {ratingSum: 999},
    {ratingCount: 999},
    {jobsCompleted: 999},
    {disputesLost: 999},
    {trust: {scoreVisible: false}},
    {walletBalanceSen: 999999},
    {escrowLockedSen: 999999},
    // The public-profile client-history counters (see functions/index.js's
    // bumpJobsPostedOnCreate / bumpJobsAssignedOnAccept) are Cloud-Function-
    // only too, so a client can't forge a higher hire rate.
    {jobsPosted: 999},
    {jobsAssigned: 999},
    {hireRate: 100},
  ];

  for (const patch of forgedFieldPatches) {
    const field = Object.keys(patch)[0];
    it(`denies a self-update that touches ${field}`, async () => {
      const db = dbAs(UID);
      await assertFails(updateDoc(doc(db, `users/${UID}`), patch));
    });
  }

  it("denies create with a nonzero walletBalanceSen", async () => {
    const db = dbAs("user2");
    await assertFails(setDoc(doc(db, "users/user2"), {
      role: "requestor",
      walletBalanceSen: 500,
    }));
  });

  it("denies create with any trust field (trustScore)", async () => {
    const db = dbAs("user3");
    await assertFails(setDoc(doc(db, "users/user3"), {
      role: "requestor",
      trustScore: 50,
    }));
  });

  it("denies create with any trust field (trust map)", async () => {
    const db = dbAs("user4");
    await assertFails(setDoc(doc(db, "users/user4"), {
      role: "requestor",
      trust: {scoreVisible: true},
    }));
  });

  it("denies create with a forged jobsPosted/hireRate", async () => {
    const db = dbAs("user5");
    await assertFails(setDoc(doc(db, "users/user5"), {
      role: "requestor",
      jobsPosted: 40,
      hireRate: 90,
    }));
  });
});

// ---------------------------------------------------------------------------
// Conversations - conversations/{id}.
// ---------------------------------------------------------------------------
describe("Conversations", () => {
  const CONVERSATION_ID = "job4_provider4";
  const REQUESTOR = "requestor4";
  const PROVIDER = "provider4";

  beforeEach(async () => {
    await seed([
      [
        `conversations/${CONVERSATION_ID}`,
        {
          participantIds: [REQUESTOR, PROVIDER],
          lastMessageText: "hi",
          lastMessageSenderId: REQUESTOR,
          lastMessageAt: Timestamp.now(),
          unreadCount: 0,
        },
      ],
    ]);
  });

  it("allows an update that only touches the preview/counter fields", async () => {
    const db = dbAs(REQUESTOR);
    await assertSucceeds(
        updateDoc(doc(db, `conversations/${CONVERSATION_ID}`), {
          lastMessageText: "new message",
          lastMessageSenderId: REQUESTOR,
          lastMessageAt: serverTimestamp(),
          unreadCount: 2,
        }));
  });

  it("denies an update that writes chatClosesAt", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(
        updateDoc(doc(db, `conversations/${CONVERSATION_ID}`), {
          chatClosesAt: Timestamp.now(),
        }));
  });

  it("denies an update that changes participantIds", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(
        updateDoc(doc(db, `conversations/${CONVERSATION_ID}`), {
          participantIds: [REQUESTOR, "some-other-uid"],
        }));
  });
});

// ---------------------------------------------------------------------------
// Server-only collections - transactions, disputes, milestones (create).
// ---------------------------------------------------------------------------
describe("Server-only collections", () => {
  const JOB_ID = "job5";
  const REQUESTOR = "requestor5";
  const PROVIDER = "provider5";

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      [
        `jobs/${JOB_ID}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "in_progress",
        },
      ],
    ]);
  });

  it("denies any client write to transactions/{id}", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(setDoc(doc(db, "transactions/tx1"), {
      participantIds: [REQUESTOR, PROVIDER],
      amountSen: 1000,
    }));
  });

  it("denies any client write to disputes/{id}", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(setDoc(doc(db, "disputes/d1"), {
      participantIds: [REQUESTOR, PROVIDER],
      status: "open",
    }));
  });

  it("denies a milestones doc create, even by the job's accepted provider", async () => {
    const db = dbAs(PROVIDER);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/milestones/m1`), {
          providerId: PROVIDER,
          status: "proposed",
          amountSen: 1000,
        }));
  });

  it("denies a milestones doc create by the job's requestor", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(
        setDoc(doc(db, `jobs/${JOB_ID}/milestones/m1`), {
          providerId: PROVIDER,
          status: "proposed",
          amountSen: 1000,
        }));
  });
});

// ---------------------------------------------------------------------------
// Service address privacy - jobs/{jobId}/private/address. The crux of this
// feature: the precise service address must never leak to a bidder who
// isn't the job's accepted provider.
// ---------------------------------------------------------------------------
describe("Service address privacy", () => {
  const JOB_ID = "job6";
  const REQUESTOR = "requestor6";
  const PROVIDER = "provider6";
  const OTHER_PROVIDER = "provider6-other";
  const ADMIN = "admin6";
  const ADDRESS_PATH = `jobs/${JOB_ID}/private/address`;

  const address = () => ({
    line1: "12, Jalan Mawar 3",
    postcode: "11900",
    city: "Bayan Lepas",
    state: "Penang",
  });

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      [`users/${OTHER_PROVIDER}`, {role: "provider"}],
      [`users/${ADMIN}`, {role: "admin"}],
      [
        `jobs/${JOB_ID}`,
        {
          requestorId: REQUESTOR,
          acceptedProviderId: PROVIDER,
          status: "in_progress",
        },
      ],
    ]);
  });

  it("allows the owner to create and read the address", async () => {
    const db = dbAs(REQUESTOR);
    await assertSucceeds(setDoc(doc(db, ADDRESS_PATH), address()));
    await assertSucceeds(getDoc(doc(db, ADDRESS_PATH)));
  });

  it("allows the accepted provider to read but denies them writing it", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    const db = dbAs(PROVIDER);
    await assertSucceeds(getDoc(doc(db, ADDRESS_PATH)));
    await assertFails(setDoc(doc(db, ADDRESS_PATH), address()));
  });

  it("allows an admin to read the address", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    const db = dbAs(ADMIN);
    await assertSucceeds(getDoc(doc(db, ADDRESS_PATH)));
  });

  it("denies read to a signed-in non-participant (some other provider)", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    const db = dbAs(OTHER_PROVIDER);
    await assertFails(getDoc(doc(db, ADDRESS_PATH)));
  });

  it("denies write by a suspended owner", async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor", suspended: true}],
    ]);
    const db = dbAs(REQUESTOR);
    await assertFails(setDoc(doc(db, ADDRESS_PATH), address()));
  });

  it("denies delete, even by the owner", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    const db = dbAs(REQUESTOR);
    await assertFails(deleteDoc(doc(db, ADDRESS_PATH)));
  });
});

// ---------------------------------------------------------------------------
// Private payout doc - users/{uid}/private/payout. Payout bank details and
// the phone number moved here off the world-readable users/{uid} doc; this
// is the same owner+admin-only `private/{doc}` rule that already guards
// users/{uid}/private/verification, applied to a different doc id.
// ---------------------------------------------------------------------------
describe("Private payout doc", () => {
  const OWNER = "user7";
  const OTHER = "user7-other";
  const ADMIN = "admin7";
  const PAYOUT_PATH = `users/${OWNER}/private/payout`;

  const payout = () => ({
    phone: "012-345 6789",
    bankName: "Maybank",
    accountHolder: "Jane Doe",
    accountLast4: "6789",
    branchCode: "1234",
  });

  beforeEach(async () => {
    await seed([
      [`users/${OWNER}`, {role: "requestor"}],
      [`users/${OTHER}`, {role: "requestor"}],
      [`users/${ADMIN}`, {role: "admin"}],
    ]);
  });

  it("allows the owner to create, read and write it", async () => {
    const db = dbAs(OWNER);
    await assertSucceeds(setDoc(doc(db, PAYOUT_PATH), payout()));
    await assertSucceeds(getDoc(doc(db, PAYOUT_PATH)));
    await assertSucceeds(
        setDoc(doc(db, PAYOUT_PATH), {phone: "011-111 1111"},
            {merge: true}));
  });

  it("denies read to another signed-in user", async () => {
    await seed([[PAYOUT_PATH, payout()]]);
    const db = dbAs(OTHER);
    await assertFails(getDoc(doc(db, PAYOUT_PATH)));
  });

  it("denies write by another signed-in user", async () => {
    const db = dbAs(OTHER);
    await assertFails(setDoc(doc(db, PAYOUT_PATH), payout()));
  });

  it("allows an admin to read it", async () => {
    await seed([[PAYOUT_PATH, payout()]]);
    const db = dbAs(ADMIN);
    await assertSucceeds(getDoc(doc(db, PAYOUT_PATH)));
  });
});

// "Report this user", filed from a public profile. Unlike disputes and
// transactions, a client creates these directly, so the create rule carries
// all the vetting; reads stay admin-only so the collection can't be mined to
// discover who has been reported.
describe("Server-owned SSM extract doc", () => {
  const OWNER = "user8";
  const OTHER = "user8-other";
  const ADMIN = "admin8";
  const EXTRACT_PATH = `users/${OWNER}/private/ssmExtract`;
  const VERIFICATION_PATH = `users/${OWNER}/private/verification`;

  beforeEach(async () => {
    await seed([
      [`users/${OWNER}`, {role: "provider"}],
      [`users/${OTHER}`, {role: "provider"}],
      [`users/${ADMIN}`, {role: "admin"}],
    ]);
  });

  // The whole verification story rests on this one rule: the verdict is
  // written only by the extractSsmDocument Cloud Function (admin SDK, bypasses
  // rules). If an applicant could write it, they could declare themselves
  // verified.
  it("denies the owner writing their own verification verdict", async () => {
    await assertFails(setDoc(doc(dbAs(OWNER), EXTRACT_PATH),
        {verdict: "passed", failures: [], ownerNameMatches: true}));
  });

  it("denies the owner merging into an existing verdict", async () => {
    await seed([[EXTRACT_PATH, {verdict: "rejected", failures: ["not-a-pdf"]}]]);
    await assertFails(setDoc(doc(dbAs(OWNER), EXTRACT_PATH),
        {verdict: "passed"}, {merge: true}));
    await assertFails(
        updateDoc(doc(dbAs(OWNER), EXTRACT_PATH), {ownerNameMatches: true}));
  });

  it("denies another signed-in user writing or reading it", async () => {
    await seed([[EXTRACT_PATH, {verdict: "passed"}]]);
    await assertFails(setDoc(doc(dbAs(OTHER), EXTRACT_PATH), {verdict: "passed"}));
    await assertFails(getDoc(doc(dbAs(OTHER), EXTRACT_PATH)));
  });

  it("still lets the owner read their own verdict", async () => {
    await seed([[EXTRACT_PATH, {verdict: "needsReview"}]]);
    await assertSucceeds(getDoc(doc(dbAs(OWNER), EXTRACT_PATH)));
  });

  it("lets an admin read it for the review queue", async () => {
    await seed([[EXTRACT_PATH, {verdict: "needsReview"}]]);
    await assertSucceeds(getDoc(doc(dbAs(ADMIN), EXTRACT_PATH)));
  });

  // The carve-out must be narrow: sibling private docs stay owner-writable,
  // or onboarding itself breaks.
  it("leaves other private docs writable by their owner", async () => {
    await assertSucceeds(setDoc(doc(dbAs(OWNER), VERIFICATION_PATH),
        {ssmNumber: "201903350205"}));
  });

  it("denies the owner writing their own ID verdict, but lets them read it",
      async () => {
        const path = `users/${OWNER}/private/idExtract`;
        await assertFails(setDoc(doc(dbAs(OWNER), path),
            {verdict: "passed", failures: []}));
        await seed([[path, {verdict: "needsReview"}]]);
        await assertSucceeds(getDoc(doc(dbAs(OWNER), path)));
        await assertFails(getDoc(doc(dbAs(OTHER), path)));
      });

  it("denies the owner writing their payout method, but lets them read it",
      async () => {
        const path = `users/${OWNER}/private/payoutMethod`;
        await assertFails(setDoc(doc(dbAs(OWNER), path),
            {method: "bank", masked: "Maybank •••• 1234"}));
        await seed([[path, {method: "duitnow", masked: "DuitNow 012-•••• 678"}]]);
        await assertSucceeds(getDoc(doc(dbAs(OWNER), path)));
        await assertFails(getDoc(doc(dbAs(OTHER), path)));
      });

  it("denies every client access to idRegistry", async () => {
    const path = "idRegistry/abc";
    await seed([[path, {uid: OWNER}]]);
    await assertFails(getDoc(doc(dbAs(OWNER), path)));
    await assertFails(getDoc(doc(dbAs(ADMIN), path)));
    await assertFails(setDoc(doc(dbAs(OWNER), "idRegistry/xyz"), {uid: OWNER}));
  });
});

describe("User reports", () => {
  const REPORTER = "user8";
  const REPORTED = "user8-target";
  const ADMIN = "admin8";
  const SUSPENDED = "user8-suspended";
  const REPORT_PATH = "reports/report8";

  const report = (overrides = {}) => ({
    reporterId: REPORTER,
    reportedUid: REPORTED,
    reason: "Never showed up and was abusive on the phone.",
    status: "open",
    createdAt: serverTimestamp(),
    ...overrides,
  });

  beforeEach(async () => {
    await seed([
      [`users/${REPORTER}`, {role: "requestor"}],
      [`users/${REPORTED}`, {role: "provider"}],
      [`users/${ADMIN}`, {role: "admin"}],
      [`users/${SUSPENDED}`, {role: "requestor", suspended: true}],
    ]);
  });

  it("allows a signed-in user to report someone else", async () => {
    const db = dbAs(REPORTER);
    await assertSucceeds(setDoc(doc(db, REPORT_PATH), report()));
  });

  it("denies forging another user's reporterId", async () => {
    const db = dbAs(REPORTER);
    await assertFails(
        setDoc(doc(db, REPORT_PATH), report({reporterId: ADMIN})));
  });

  it("denies reporting yourself", async () => {
    const db = dbAs(REPORTER);
    await assertFails(
        setDoc(doc(db, REPORT_PATH), report({reportedUid: REPORTER})));
  });

  it("denies an empty reason", async () => {
    const db = dbAs(REPORTER);
    await assertFails(setDoc(doc(db, REPORT_PATH), report({reason: ""})));
  });

  it("denies filing a report that is already resolved", async () => {
    const db = dbAs(REPORTER);
    await assertFails(
        setDoc(doc(db, REPORT_PATH), report({status: "resolved"})));
  });

  it("denies a suspended user filing a report", async () => {
    const db = dbAs(SUSPENDED);
    await assertFails(
        setDoc(doc(db, REPORT_PATH), report({reporterId: SUSPENDED})));
  });

  it("denies read to the reporter and to the reported user", async () => {
    await seed([[REPORT_PATH, report({createdAt: Timestamp.now()})]]);
    await assertFails(getDoc(doc(dbAs(REPORTER), REPORT_PATH)));
    await assertFails(getDoc(doc(dbAs(REPORTED), REPORT_PATH)));
  });

  it("allows an admin to read a report", async () => {
    await seed([[REPORT_PATH, report({createdAt: Timestamp.now()})]]);
    await assertSucceeds(getDoc(doc(dbAs(ADMIN), REPORT_PATH)));
  });

  it("denies editing or deleting a filed report, even by an admin",
      async () => {
        await seed([[REPORT_PATH, report({createdAt: Timestamp.now()})]]);
        await assertFails(
            updateDoc(doc(dbAs(ADMIN), REPORT_PATH), {status: "resolved"}));
        await assertFails(deleteDoc(doc(dbAs(REPORTER), REPORT_PATH)));
      });
});

// ---------------------------------------------------------------------------
// Bundle bids - bundles/{bundleId}/bundleBids/{providerId}.
//
// A sealed package bid, written only by the submitBundleBid /
// withdrawBundleBid Cloud Functions (admin SDK, bypasses rules) and readable
// by the bidder and the bundle's requestor alone - a competitor who could
// read these prices could undercut them by a ringgit.
// ---------------------------------------------------------------------------
describe("Bundle bids", () => {
  const BUNDLE_ID = "bundle1";
  const TASK_ID = "task1";
  const PROVIDER = "provider1"; // trustScore 42, scoreVisible true, approved
  const RIVAL = "provider2";
  const REQUESTOR = "requestor1";
  const BID_PATH = `bundles/${BUNDLE_ID}/bundleBids/${PROVIDER}`;

  const storedBid = {
    providerId: PROVIDER,
    providerName: "Pro Fixer",
    providerTrustScore: 42,
    providerScoreVisible: true,
    taskPrices: {[TASK_ID]: 15000},
    estimatedDuration: "1 week",
    message: "Happy to take this on.",
    status: "pending",
  };

  const approvedProvider = {
    role: "provider",
    verificationStatus: "approved",
    trustScore: 42,
    trust: {scoreVisible: true},
  };

  beforeEach(async () => {
    await seed([
      [`users/${PROVIDER}`, approvedProvider],
      [`users/${RIVAL}`, approvedProvider],
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`bundles/${BUNDLE_ID}`, {
        requestorId: REQUESTOR,
        status: "open",
        title: "Bathroom refresh",
        taskIds: [TASK_ID],
      }],
      [`jobs/${TASK_ID}`, {
        requestorId: REQUESTOR,
        status: "open",
        bundleId: BUNDLE_ID,
        bundleOrder: 0,
        bundleTaskCount: 1,
      }],
      [BID_PATH, storedBid],
      // A rival's bid on the same bundle: what the reads below must NOT reach.
      [`bundles/${BUNDLE_ID}/bundleBids/${RIVAL}`,
        {...storedBid, providerId: RIVAL}],
    ]);
  });

  it("lets the bidder read their own bid", async () => {
    await assertSucceeds(getDoc(doc(dbAs(PROVIDER), BID_PATH)));
  });

  it("lets the bundle's requestor read a bid on their bundle", async () => {
    await assertSucceeds(getDoc(doc(dbAs(REQUESTOR), BID_PATH)));
  });

  it("denies a rival provider reading someone else's prices", async () => {
    await assertFails(getDoc(doc(dbAs(RIVAL), BID_PATH)));
  });

  it("denies read to a signed-out visitor", async () => {
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, BID_PATH)));
  });

  it("denies a provider writing a bid directly (submitBundleBid only)",
      async () => {
        await assertFails(setDoc(
            doc(dbAs(RIVAL), `bundles/${BUNDLE_ID}/bundleBids/${RIVAL}`),
            {...storedBid, providerId: RIVAL}));
      });

  it("denies a provider editing their own stored bid", async () => {
    await assertFails(updateDoc(
        doc(dbAs(PROVIDER), BID_PATH), {taskPrices: {[TASK_ID]: 1}}));
  });

  it("denies a provider deleting their bid (withdrawBundleBid only)",
      async () => {
        await assertFails(deleteDoc(doc(dbAs(PROVIDER), BID_PATH)));
      });

  it("denies the requestor writing a bid on their own bundle", async () => {
    await assertFails(setDoc(
        doc(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}/bundleBids/${REQUESTOR}`),
        {...storedBid, providerId: REQUESTOR}));
  });

  it("lets the requestor list every bid on their bundle", async () => {
    await assertSucceeds(getDocs(
        collection(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}/bundleBids`)));
  });

  it("denies a provider listing every bid on a bundle", async () => {
    await assertFails(getDocs(
        collection(dbAs(PROVIDER), `bundles/${BUNDLE_ID}/bundleBids`)));
  });

  it("lets a provider list their own bundle bids (Pending Bids)", async () => {
    await assertSucceeds(getDocs(query(
        collectionGroup(dbAs(PROVIDER), "bundleBids"),
        where("providerId", "==", PROVIDER))));
  });

  it("denies listing another provider's bundle bids", async () => {
    await assertFails(getDocs(query(
        collectionGroup(dbAs(PROVIDER), "bundleBids"),
        where("providerId", "==", RIVAL))));
  });
});

// ---------------------------------------------------------------------------
// Cancelling a task of a bundle - jobs/{jobId} while its bundle is open.
//
// Providers bid on the package, so a task cannot be dropped out from under
// them one at a time; the requestor cancels the whole posting through the
// cancelBundle callable. Once the bundle leaves 'open', its tasks are
// ordinary jobs again.
// ---------------------------------------------------------------------------
describe("Bundle task cancellation", () => {
  const BUNDLE_ID = "bundle1";
  const TASK_ID = "task1";
  const REQUESTOR = "requestor1";
  const openBundle = {
    requestorId: REQUESTOR,
    status: "open",
    taskIds: [TASK_ID],
  };

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`bundles/${BUNDLE_ID}`, openBundle],
      [`jobs/${TASK_ID}`, {
        requestorId: REQUESTOR,
        status: "open",
        bundleId: BUNDLE_ID,
        bundleOrder: 0,
      }],
      [`jobs/plain1`, {requestorId: REQUESTOR, status: "open"}],
    ]);
  });

  it("denies cancelling one task while its bundle is open", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {status: "cancelled"}));
  });

  it("allows cancelling a task once the bundle is no longer open", async () => {
    await seed([[`bundles/${BUNDLE_ID}`,
      {...openBundle, status: "cancelled"}]]);
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {status: "cancelled"}));
  });

  it("still lets the owner edit a bundle task's title", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {title: "Re-tile the shower"}));
  });

  it("leaves cancelling an ordinary single-task job exactly as it was",
      async () => {
        await assertSucceeds(updateDoc(
            doc(dbAs(REQUESTOR), "jobs/plain1"), {status: "cancelled"}));
      });
});

// ---------------------------------------------------------------------------
// Price-change fields - jobs/{jobId}. Written only by the price-change Cloud
// Functions; a requestor must not be able to reprice a job directly.
// ---------------------------------------------------------------------------
describe("Price change fields", () => {
  const REQUESTOR = "requestor1";

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      ["jobs/job1", {
        requestorId: REQUESTOR,
        status: "in_progress",
        acceptedBidAmountSen: 10000,
      }],
    ]);
  });

  const forged = {
    priceChangeRequest: {by: "requestor", newAmountSen: 1, reason: "x"},
    originalBidAmountSen: 1,
    priceChangeCount: 0,
  };
  for (const [field, value] of Object.entries(forged)) {
    it(`denies a requestor writing ${field}`, async () => {
      await assertFails(updateDoc(
          doc(dbAs(REQUESTOR), "jobs/job1"), {[field]: value}));
    });
  }

  it("still lets the owner edit an ordinary field", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/job1"), {title: "Renamed"}));
  });
});

// ---------------------------------------------------------------------------
// fundedAtAward - jobs/{jobId}. Set only by acceptBid / awardBundle, so a
// client must not write it.
// ---------------------------------------------------------------------------
describe("fundedAtAward field", () => {
  const REQUESTOR = "requestor1";

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      ["jobs/job1", {requestorId: REQUESTOR, status: "in_progress"}],
      ["jobs/funded1", {
        requestorId: REQUESTOR, status: "in_progress", fundedAtAward: true,
      }],
    ]);
  });

  it("denies the owner setting fundedAtAward", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/job1"), {fundedAtAward: true}));
  });

  it("denies the owner clearing fundedAtAward", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/funded1"), {fundedAtAward: false}));
  });

  it("denies creating a job that already carries fundedAtAward", async () => {
    await assertSucceeds(setDoc(doc(dbAs(REQUESTOR), "jobs/new0"), {
      requestorId: REQUESTOR, status: "open",
    }));
    await assertFails(setDoc(doc(dbAs(REQUESTOR), "jobs/new1"), {
      requestorId: REQUESTOR, status: "open", fundedAtAward: true,
    }));
  });

  it("still lets the owner edit an ordinary field", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/funded1"), {title: "Renamed"}));
  });
});

// ---------------------------------------------------------------------------
// Appointment fields - jobs/{jobId}. Written only by the scheduling callables.
// Delivering is blocked until a required visit time is confirmed.
// ---------------------------------------------------------------------------
describe("Appointment scheduling", () => {
  const REQUESTOR = "requestor1";
  const PROVIDER = "provider1";
  const job = (extra) => ({
    requestorId: REQUESTOR,
    acceptedProviderId: PROVIDER,
    status: "in_progress",
    ...extra,
  });

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      ["jobs/job1", job()],
      ["jobs/required1", job({schedulingRequired: true})],
      ["jobs/pending1", job({
        schedulingRequired: true,
        appointmentProposal: {options: [Timestamp.now()], by: PROVIDER},
      })],
      ["jobs/confirmed1", job({
        schedulingRequired: true,
        appointment: {startAt: Timestamp.now(), confirmedAt: Timestamp.now()},
      })],
      ...["job1", "required1", "pending1", "confirmed1"].map((id) => [
        `jobs/${id}/milestones/m0`,
        {providerId: PROVIDER, status: "funded", amountSen: 1000},
      ]),
    ]);
  });

  const forged = {
    schedulingRequired: true,
    appointment: {startAt: Timestamp.now(), confirmedAt: Timestamp.now()},
    appointmentProposal: {options: [Timestamp.now()], by: REQUESTOR},
    appointmentChanges: 0,
    lateRescheduleBy: [REQUESTOR],
    onTheWayAt: Timestamp.now(),
    etaMinutes: 30,
    arrivedAt: Timestamp.now(),
  };
  for (const [field, value] of Object.entries(forged)) {
    it(`denies a requestor writing ${field}`, async () => {
      await assertFails(updateDoc(
          doc(dbAs(REQUESTOR), "jobs/job1"), {[field]: value}));
    });
  }

  it("denies creating a job that carries appointment fields", async () => {
    await assertFails(setDoc(doc(dbAs(REQUESTOR), "jobs/new1"), {
      requestorId: REQUESTOR, status: "open", appointment: {},
    }));
  });

  const deliver = (jobId) => updateDoc(
      doc(dbAs(PROVIDER), `jobs/${jobId}/milestones/m0`),
      {status: "submitted", submissionNote: "done"});

  it("denies delivering while a required visit time is unconfirmed", async () => {
    await assertFails(deliver("required1"));
    await assertFails(deliver("pending1"));
  });

  it("allows delivering once the visit time is confirmed", async () => {
    await assertSucceeds(deliver("confirmed1"));
  });

  it("allows delivering when scheduling was never required", async () => {
    await assertSucceeds(deliver("job1"));
  });
});
