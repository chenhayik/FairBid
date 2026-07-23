/**
 * Security-rules test suite for `firestore.rules`.
 *
 * These tests exercise the *real* rules engine via the Firestore emulator
 * (through `@firebase/rules-unit-testing`) — unlike the Dart widget tests,
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
  setDoc,
  updateDoc,
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
// Bids — jobs/{jobId}/bids/{bidId}, bidId == provider uid.
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
// Reviews — users/{revieweeId}/reviews/{reviewId}, reviewId == {jobId}_{reviewerId}.
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
// User profile self-writes — users/{uid}.
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
});

// ---------------------------------------------------------------------------
// Conversations — conversations/{id}.
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
// Server-only collections — transactions, disputes, milestones (create).
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
