// Security-rules tests for `firestore.rules`, run against the Firestore
// emulator (see ./README.md). Each case proves one ALLOW or DENY the rules claim.

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

const approvedProvider = {
  role: "provider",
  verificationStatus: "approved",
  trustScore: 42,
  trust: {scoreVisible: true},
};

// ---------------------------------------------------------------------------
// Bids - jobs/{jobId}/bids/{bidId}, bidId == provider uid.
// ---------------------------------------------------------------------------
describe("Bids", () => {
  const JOB_ID = "job1";
  const PROVIDER = "provider1"; // trustScore 42, scoreVisible true, approved
  const REQUESTOR = "requestor1";
  const bidPath = (jobId, uid = PROVIDER) => `jobs/${jobId}/bids/${uid}`;

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
      [`users/${PROVIDER}`, approvedProvider],
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`jobs/${JOB_ID}`, {requestorId: REQUESTOR, status: "open"}],
    ]);
  });

  it("allows create with a valid amount and a truthful trust snapshot on an open job", async () => {
    await assertSucceeds(
        setDoc(doc(dbAs(PROVIDER), bidPath(JOB_ID)), validBid()));
  });

  const denied = {
    "a negative amountSen": {amountSen: -100},
    "a zero amountSen": {amountSen: 0},
    "a non-integer amountSen": {amountSen: 12.5},
    "an amountSen over the 100,000,000 cap": {amountSen: 100000001},
    "a providerTrustScore that isn't the stored one": {providerTrustScore: 999},
    "a providerScoreVisible that isn't the stored one":
        {providerScoreVisible: false},
    "a providerPhotoUrl that isn't the stored one":
        {providerPhotoUrl: "https://evil.example/stolen.jpg"},
    "status accepted (accepting is server-only)": {status: "accepted"},
  };
  for (const [name, overrides] of Object.entries(denied)) {
    it(`denies create with ${name}`, async () => {
      await assertFails(setDoc(
          doc(dbAs(PROVIDER), bidPath(JOB_ID)), validBid(overrides)));
    });
  }

  it("lets a provider edit their pending bid but not flip it to accepted", async () => {
    await seed([[bidPath(JOB_ID), validBid()]]);
    const ref = doc(dbAs(PROVIDER), bidPath(JOB_ID));
    await assertSucceeds(updateDoc(ref, {amountSen: 40000}));
    await assertSucceeds(updateDoc(ref, {status: "pending"}));
    await assertFails(updateDoc(ref, {status: "accepted"}));
  });

  it("denies create once the job's bidding deadline has passed", async () => {
    await seed([[`jobs/expired`, {
      requestorId: REQUESTOR,
      status: "open",
      deadline: new Date(Date.now() - 60_000),
    }]]);
    await assertFails(
        setDoc(doc(dbAs(PROVIDER), bidPath("expired")), validBid()));
  });

  it("allows create while the job's bidding deadline is still in the future", async () => {
    await seed([[`jobs/future`, {
      requestorId: REQUESTOR,
      status: "open",
      deadline: new Date(Date.now() + 3_600_000),
    }]]);
    await assertSucceeds(
        setDoc(doc(dbAs(PROVIDER), bidPath("future")), validBid()));
  });

  it("allows create with a providerPhotoUrl matching the stored profile", async () => {
    const PHOTO_PROVIDER = "provider1-with-photo";
    await seed([[`users/${PHOTO_PROVIDER}`, {
      ...approvedProvider,
      profilePhotoUrl: "https://example.com/me.jpg",
    }]]);
    await assertSucceeds(setDoc(
        doc(dbAs(PHOTO_PROVIDER), bidPath(JOB_ID, PHOTO_PROVIDER)), validBid({
          providerId: PHOTO_PROVIDER,
          providerPhotoUrl: "https://example.com/me.jpg",
        })));
  });

  it("denies create by a non-approved provider", async () => {
    await seed([[`users/provider2`, {
      role: "provider",
      verificationStatus: "pending",
      trustScore: 0,
      trust: {scoreVisible: false},
    }]]);
    await assertFails(setDoc(
        doc(dbAs("provider2"), bidPath(JOB_ID, "provider2")), validBid({
          providerId: "provider2",
          providerTrustScore: 0,
          providerScoreVisible: false,
        })));
  });

  it("denies create when the job isn't open", async () => {
    await seed([[`jobs/in-progress`,
      {requestorId: REQUESTOR, status: "in_progress"}]]);
    await assertFails(
        setDoc(doc(dbAs(PROVIDER), bidPath("in-progress")), validBid()));
  });
});

// ---------------------------------------------------------------------------
// Reviews - users/{revieweeId}/reviews/{reviewId}, reviewId == {jobId}_{reviewerId}
// (or {bundleId}_{reviewerId} for a bundled task).
// ---------------------------------------------------------------------------
describe("Reviews", () => {
  const REQUESTOR = "requestor2";
  const PROVIDER = "provider2";
  const STRANGER = "stranger1";
  const BUNDLE_ID = "bundle-rev";

  /** Writes a review as [reviewer] onto [reviewee]'s profile. */
  const review = (reviewer, reviewee, reviewId, jobId, rating = 4) =>
    setDoc(doc(dbAs(reviewer), `users/${reviewee}/reviews/${reviewId}`),
        {reviewerId: reviewer, jobId, rating});

  const job = (extra) => ({
    requestorId: REQUESTOR, acceptedProviderId: PROVIDER, ...extra,
  });

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`users/${PROVIDER}`, {role: "provider"}],
      [`users/${STRANGER}`, {role: "requestor"}],
      ["jobs/done", job({status: "completed"})],
      ["jobs/open", job({status: "open"})],
      [`bundles/${BUNDLE_ID}`, {requestorId: REQUESTOR, status: "awarded"}],
      ["jobs/taskA", job({status: "completed", bundleId: BUNDLE_ID})],
      ["jobs/taskB", job({status: "completed", bundleId: BUNDLE_ID})],
    ]);
  });

  it("allows a valid 1-5 review at the correct doc id by a participant on a completed job", async () => {
    await assertSucceeds(
        review(REQUESTOR, PROVIDER, `done_${REQUESTOR}`, "done", 5));
  });

  for (const rating of [0, 6, 3.5]) {
    it(`denies create when rating (${rating}) is outside 1..5 or non-integer`, async () => {
      await assertFails(
          review(REQUESTOR, PROVIDER, `done_${REQUESTOR}`, "done", rating));
    });
  }

  it("denies create when the doc id isn't {jobId}_{reviewerId} (spam vector)", async () => {
    await assertFails(review(REQUESTOR, PROVIDER, "not-the-right-id", "done"));
  });

  it("denies create when the job isn't completed", async () => {
    await assertFails(
        review(REQUESTOR, PROVIDER, `open_${REQUESTOR}`, "open"));
  });

  it("denies create when the reviewer isn't a participant of the job", async () => {
    await assertFails(
        review(STRANGER, PROVIDER, `done_${STRANGER}`, "done"));
  });

  it("denies create on your own profile", async () => {
    await assertFails(
        review(REQUESTOR, REQUESTOR, `done_${REQUESTOR}`, "done"));
  });

  it("allows a bundle-keyed id for a bundled task, denies a job-keyed one", async () => {
    await assertFails(
        review(REQUESTOR, PROVIDER, `taskA_${REQUESTOR}`, "taskA", 5));
    await assertSucceeds(
        review(REQUESTOR, PROVIDER, `${BUNDLE_ID}_${REQUESTOR}`, "taskA", 5));
  });

  it("denies a second review for another task of the same bundle and pair", async () => {
    const id = `${BUNDLE_ID}_${REQUESTOR}`;
    await assertSucceeds(review(REQUESTOR, PROVIDER, id, "taskA", 5));
    // The doc now exists, so this takes the update path, which only allows
    // flagging - not a second, differently-scored review.
    await assertFails(review(REQUESTOR, PROVIDER, id, "taskB", 4));
  });
});

// ---------------------------------------------------------------------------
// Bundles - bundles/{bundleId} and the bundle fields on a task job. Bundles
// are written only by Cloud Functions (admin SDK), and the tasks of an open
// bundle refuse ordinary per-job bids and single cancellation.
// ---------------------------------------------------------------------------
describe("Bundles", () => {
  const BUNDLE_ID = "bundle1";
  const TASK_ID = "task1";
  const PROVIDER = "provider1";
  const REQUESTOR = "requestor1";

  const validBid = {
    providerId: PROVIDER,
    amountSen: 50000,
    providerTrustScore: 42,
    providerScoreVisible: true,
    status: "pending",
  };
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
      [`users/${PROVIDER}`, approvedProvider],
      [`users/${REQUESTOR}`, {role: "requestor"}],
      [`bundles/${BUNDLE_ID}`, openBundle],
      [`jobs/${TASK_ID}`, {
        requestorId: REQUESTOR,
        status: "open",
        bundleId: BUNDLE_ID,
        bundleOrder: 0,
      }],
      // An ordinary job, so the checks below prove single-task behaviour is unchanged.
      [`jobs/plain1`, {requestorId: REQUESTOR, status: "open"}],
    ]);
  });

  it("lets any signed-in user read a bundle, but not a signed-out visitor", async () => {
    await assertSucceeds(getDoc(doc(dbAs(PROVIDER), `bundles/${BUNDLE_ID}`)));
    const visitor = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(visitor, `bundles/${BUNDLE_ID}`)));
  });

  it("denies every client write to a bundle, even by its owner", async () => {
    const db = dbAs(REQUESTOR);
    await assertFails(setDoc(doc(db, "bundles/forged"),
        {requestorId: REQUESTOR, status: "open", taskIds: []}));
    await assertFails(
        updateDoc(doc(db, `bundles/${BUNDLE_ID}`), {status: "cancelled"}));
    await assertFails(
        updateDoc(doc(db, `bundles/${BUNDLE_ID}`), {consolidationCapPct: 90}));
    await assertFails(deleteDoc(doc(db, `bundles/${BUNDLE_ID}`)));
  });

  it("denies posting a job that claims bundle membership", async () => {
    await assertFails(setDoc(doc(dbAs(REQUESTOR), "jobs/forged"), {
      requestorId: REQUESTOR, status: "open", bundleId: BUNDLE_ID,
      bundleOrder: 1,
    }));
  });

  it("denies a client reading or writing a completionCounts marker", async () => {
    // Server-owned by onJobCompleted; no rule matches, so it's default-deny.
    const db = dbAs(PROVIDER);
    const marker = `bundles/${BUNDLE_ID}/completionCounts/${PROVIDER}`;
    await assertFails(getDoc(doc(db, marker)));
    await assertFails(
        setDoc(doc(db, marker), {jobId: TASK_ID, at: serverTimestamp()}));
  });

  it("denies an ordinary per-job bid while the task's bundle is open", async () => {
    await assertFails(setDoc(
        doc(dbAs(PROVIDER), `jobs/${TASK_ID}/bids/${PROVIDER}`), validBid));
  });

  it("allows an ordinary per-job bid once the bundle is no longer open", async () => {
    await seed([[`bundles/${BUNDLE_ID}`, {...openBundle, status: "awarded"}]]);
    await assertSucceeds(setDoc(
        doc(dbAs(PROVIDER), `jobs/${TASK_ID}/bids/${PROVIDER}`), validBid));
  });

  it("leaves bidding on an ordinary single-task job unchanged", async () => {
    await assertSucceeds(setDoc(
        doc(dbAs(PROVIDER), `jobs/plain1/bids/${PROVIDER}`), validBid));
  });

  it("denies cancelling one task while its bundle is open", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {status: "cancelled"}));
  });

  it("allows cancelling a task once the bundle is no longer open", async () => {
    await seed([[`bundles/${BUNDLE_ID}`, {...openBundle, status: "cancelled"}]]);
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), `jobs/${TASK_ID}`), {status: "cancelled"}));
  });

  it("leaves cancelling an ordinary single-task job unchanged", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/plain1"), {status: "cancelled"}));
  });
});

// ---------------------------------------------------------------------------
// Server-owned job fields - jobs/{jobId}. Bundle, price-change, accept and
// scheduling fields are written only by Cloud Functions, never by the owner.
// ---------------------------------------------------------------------------
describe("Server-owned job fields", () => {
  const REQUESTOR = "requestor1";
  const now = () => Timestamp.now();

  beforeEach(async () => {
    await seed([
      [`users/${REQUESTOR}`, {role: "requestor"}],
      ["jobs/job1", {
        requestorId: REQUESTOR,
        status: "in_progress",
        acceptedBidAmountSen: 10000,
      }],
      ["jobs/funded1", {
        requestorId: REQUESTOR, status: "in_progress", fundedAtAward: true,
      }],
    ]);
  });

  const forged = {
    bundleId: "bundle1",
    bundleOrder: 3,
    releasedAt: new Date(),
    priceChangeRequest: {by: "requestor", newAmountSen: 1, reason: "x"},
    originalBidAmountSen: 1,
    priceChangeCount: 0,
    fundedAtAward: true,
    schedulingRequired: true,
    appointment: {startAt: now(), confirmedAt: now()},
    appointmentProposal: {options: [now()], by: REQUESTOR},
    appointmentChanges: 0,
    lateRescheduleBy: [REQUESTOR],
    onTheWayAt: now(),
    etaMinutes: 30,
    arrivedAt: now(),
  };
  for (const [field, value] of Object.entries(forged)) {
    it(`denies the owner writing ${field}`, async () => {
      await assertFails(updateDoc(
          doc(dbAs(REQUESTOR), "jobs/job1"), {[field]: value}));
    });
  }

  it("denies the owner clearing fundedAtAward", async () => {
    await assertFails(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/funded1"), {fundedAtAward: false}));
  });

  it("denies creating a job that carries a server-owned field", async () => {
    const create = (id, extra) => setDoc(doc(dbAs(REQUESTOR), `jobs/${id}`),
        {requestorId: REQUESTOR, status: "open", ...extra});
    await assertSucceeds(create("ok", {}));
    await assertFails(create("a", {fundedAtAward: true}));
    await assertFails(create("b", {appointment: {}}));
  });

  it("still lets the owner edit an ordinary field", async () => {
    await assertSucceeds(updateDoc(
        doc(dbAs(REQUESTOR), "jobs/job1"), {title: "Renamed"}));
  });
});

// ---------------------------------------------------------------------------
// Appointment delivery gate - a job that needs a visit time can only be
// delivered once it is confirmed.
// ---------------------------------------------------------------------------
describe("Appointment delivery gate", () => {
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

// ---------------------------------------------------------------------------
// User profile - users/{uid}: self-writes, sign-up, and privilege escalation.
// ---------------------------------------------------------------------------
describe("User profile", () => {
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
    await assertSucceeds(updateDoc(doc(dbAs(UID), `users/${UID}`), {
      displayName: "New Name",
      phone: "111",
      bio: "updated bio",
    }));
  });

  it("allows submitting for review (verificationStatus -> pending)", async () => {
    await assertSucceeds(updateDoc(doc(dbAs(UID), `users/${UID}`), {
      verificationStatus: "pending",
      displayName: "Mallory",
      onboarding: {step: "done"},
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
    // Cloud-Function-only client-history counters, so a hire rate can't be forged.
    {jobsPosted: 999},
    {jobsAssigned: 999},
    {hireRate: 100},
    // Admin role and KYC approval can't be self-granted.
    {role: "admin"},
    {verificationStatus: "approved"},
  ];

  for (const patch of forgedFieldPatches) {
    const field = Object.keys(patch)[0];
    it(`denies a self-update that touches ${field}`, async () => {
      await assertFails(updateDoc(doc(dbAs(UID), `users/${UID}`), patch));
    });
  }

  const deniedCreates = {
    "a nonzero walletBalanceSen": {walletBalanceSen: 500},
    "a trustScore": {trustScore: 50},
    "a trust map": {trust: {scoreVisible: true}},
    "a forged jobsPosted/hireRate": {jobsPosted: 40, hireRate: 90},
    "role admin": {role: "admin"},
  };
  for (const [name, extra] of Object.entries(deniedCreates)) {
    it(`denies create with ${name}`, async () => {
      await assertFails(setDoc(doc(dbAs("newcomer"), "users/newcomer"),
          {role: "requestor", ...extra}));
    });
  }

  it("allows a normal sign-up to create its own profile", async () => {
    await assertSucceeds(setDoc(doc(dbAs("newcomer"), "users/newcomer"), {
      role: "provider",
      displayName: "New Provider",
      email: "new@example.com",
      walletBalanceSen: 0,
      verificationStatus: "none",
      onboardingComplete: false,
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
    await seed([[`conversations/${CONVERSATION_ID}`, {
      participantIds: [REQUESTOR, PROVIDER],
      lastMessageText: "hi",
      lastMessageSenderId: REQUESTOR,
      lastMessageAt: Timestamp.now(),
      unreadCount: 0,
    }]]);
  });

  const update = (data) => updateDoc(
      doc(dbAs(REQUESTOR), `conversations/${CONVERSATION_ID}`), data);

  it("allows an update that only touches the preview/counter fields", async () => {
    await assertSucceeds(update({
      lastMessageText: "new message",
      lastMessageSenderId: REQUESTOR,
      lastMessageAt: serverTimestamp(),
      unreadCount: 2,
    }));
  });

  it("denies an update that writes chatClosesAt or changes participantIds", async () => {
    await assertFails(update({chatClosesAt: Timestamp.now()}));
    await assertFails(update({participantIds: [REQUESTOR, "some-other-uid"]}));
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
      [`jobs/${JOB_ID}`, {
        requestorId: REQUESTOR,
        acceptedProviderId: PROVIDER,
        status: "in_progress",
      }],
    ]);
  });

  it("denies any client write to transactions, disputes and milestone creates", async () => {
    const db = dbAs(REQUESTOR);
    const participantIds = [REQUESTOR, PROVIDER];
    await assertFails(setDoc(doc(db, "transactions/tx1"),
        {participantIds, amountSen: 1000}));
    await assertFails(setDoc(doc(db, "disputes/d1"),
        {participantIds, status: "open"}));
    const milestone = {providerId: PROVIDER, status: "proposed", amountSen: 1000};
    await assertFails(setDoc(doc(db, `jobs/${JOB_ID}/milestones/m1`), milestone));
    await assertFails(setDoc(
        doc(dbAs(PROVIDER), `jobs/${JOB_ID}/milestones/m1`), milestone));
  });
});

// ---------------------------------------------------------------------------
// Service address privacy - jobs/{jobId}/private/address. The precise address
// must never leak to a bidder who isn't the job's accepted provider.
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
      [`jobs/${JOB_ID}`, {
        requestorId: REQUESTOR,
        acceptedProviderId: PROVIDER,
        status: "in_progress",
      }],
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
    await assertSucceeds(getDoc(doc(dbAs(ADMIN), ADDRESS_PATH)));
  });

  it("denies read to a signed-in non-participant (some other provider)", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    await assertFails(getDoc(doc(dbAs(OTHER_PROVIDER), ADDRESS_PATH)));
  });

  it("denies write by a suspended owner", async () => {
    await seed([[`users/${REQUESTOR}`, {role: "requestor", suspended: true}]]);
    await assertFails(setDoc(doc(dbAs(REQUESTOR), ADDRESS_PATH), address()));
  });

  it("denies delete, even by the owner", async () => {
    await seed([[ADDRESS_PATH, address()]]);
    await assertFails(deleteDoc(doc(dbAs(REQUESTOR), ADDRESS_PATH)));
  });
});

// ---------------------------------------------------------------------------
// Private user docs - users/{uid}/private/{doc}: owner + admin read only.
// The owner writes `payout` and `verification`; the server-written verdict
// docs and the payout method can't be written by anyone on the client.
// ---------------------------------------------------------------------------
describe("Private user docs", () => {
  const OWNER = "user7";
  const OTHER = "user7-other";
  const ADMIN = "admin7";
  const at = (name) => `users/${OWNER}/private/${name}`;

  beforeEach(async () => {
    await seed([
      [`users/${OWNER}`, {role: "provider"}],
      [`users/${OTHER}`, {role: "provider"}],
      [`users/${ADMIN}`, {role: "admin"}],
    ]);
  });

  for (const name of ["payout", "verification"]) {
    it(`${name}: the owner reads and writes, an admin reads, others do neither`, async () => {
      await assertSucceeds(
          setDoc(doc(dbAs(OWNER), at(name)), {phone: "012-345 6789"}));
      await assertSucceeds(setDoc(
          doc(dbAs(OWNER), at(name)), {phone: "011-111 1111"}, {merge: true}));
      await assertSucceeds(getDoc(doc(dbAs(OWNER), at(name))));
      await assertSucceeds(getDoc(doc(dbAs(ADMIN), at(name))));
      await assertFails(getDoc(doc(dbAs(OTHER), at(name))));
      await assertFails(setDoc(doc(dbAs(OTHER), at(name)), {phone: "x"}));
    });
  }

  // Written only by Cloud Functions: if an applicant could write the verdict,
  // they could declare themselves verified.
  for (const name of ["ssmExtract", "idExtract", "payoutMethod"]) {
    it(`${name}: the owner and admins read it, but no client can write it`, async () => {
      await assertFails(
          setDoc(doc(dbAs(OWNER), at(name)), {verdict: "passed"}));
      await seed([[at(name), {verdict: "rejected"}]]);
      await assertFails(setDoc(
          doc(dbAs(OWNER), at(name)), {verdict: "passed"}, {merge: true}));
      await assertFails(
          updateDoc(doc(dbAs(OWNER), at(name)), {ownerNameMatches: true}));
      await assertFails(setDoc(doc(dbAs(OTHER), at(name)), {verdict: "passed"}));
      await assertSucceeds(getDoc(doc(dbAs(OWNER), at(name))));
      await assertSucceeds(getDoc(doc(dbAs(ADMIN), at(name))));
      await assertFails(getDoc(doc(dbAs(OTHER), at(name))));
    });
  }

  it("denies every client access to idRegistry", async () => {
    await seed([["idRegistry/abc", {uid: OWNER}]]);
    await assertFails(getDoc(doc(dbAs(OWNER), "idRegistry/abc")));
    await assertFails(getDoc(doc(dbAs(ADMIN), "idRegistry/abc")));
    await assertFails(setDoc(doc(dbAs(OWNER), "idRegistry/xyz"), {uid: OWNER}));
  });
});

// ---------------------------------------------------------------------------
// User reports - reports/{id}. Clients file them directly, so the create rule
// carries all the vetting; reads are admin-only so reported users stay hidden.
// ---------------------------------------------------------------------------
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
    await assertSucceeds(setDoc(doc(dbAs(REPORTER), REPORT_PATH), report()));
  });

  const denied = {
    "forging another user's reporterId": [REPORTER, {reporterId: ADMIN}],
    "reporting yourself": [REPORTER, {reportedUid: REPORTER}],
    "an empty reason": [REPORTER, {reason: ""}],
    "a report that is already resolved": [REPORTER, {status: "resolved"}],
    "a suspended user filing": [SUSPENDED, {reporterId: SUSPENDED}],
  };
  for (const [name, [uid, overrides]] of Object.entries(denied)) {
    it(`denies ${name}`, async () => {
      await assertFails(setDoc(doc(dbAs(uid), REPORT_PATH), report(overrides)));
    });
  }

  it("lets only an admin read a report", async () => {
    await seed([[REPORT_PATH, report({createdAt: Timestamp.now()})]]);
    await assertFails(getDoc(doc(dbAs(REPORTER), REPORT_PATH)));
    await assertFails(getDoc(doc(dbAs(REPORTED), REPORT_PATH)));
    await assertSucceeds(getDoc(doc(dbAs(ADMIN), REPORT_PATH)));
  });

  it("denies editing or deleting a filed report, even by an admin", async () => {
    await seed([[REPORT_PATH, report({createdAt: Timestamp.now()})]]);
    await assertFails(
        updateDoc(doc(dbAs(ADMIN), REPORT_PATH), {status: "resolved"}));
    await assertFails(deleteDoc(doc(dbAs(REPORTER), REPORT_PATH)));
  });
});

// ---------------------------------------------------------------------------
// Bundle bids - bundles/{bundleId}/bundleBids/{providerId}. Sealed package
// bids, written only by Cloud Functions and readable by the bidder and the
// bundle's requestor alone.
// ---------------------------------------------------------------------------
describe("Bundle bids", () => {
  const BUNDLE_ID = "bundle1";
  const TASK_ID = "task1";
  const PROVIDER = "provider1";
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
      [BID_PATH, storedBid],
      // A rival's bid on the same bundle: what the reads below must NOT reach.
      [`bundles/${BUNDLE_ID}/bundleBids/${RIVAL}`,
        {...storedBid, providerId: RIVAL}],
    ]);
  });

  it("lets the bidder and the bundle's requestor read a bid", async () => {
    await assertSucceeds(getDoc(doc(dbAs(PROVIDER), BID_PATH)));
    await assertSucceeds(getDoc(doc(dbAs(REQUESTOR), BID_PATH)));
  });

  it("denies a rival provider or a signed-out visitor reading someone else's prices", async () => {
    await assertFails(getDoc(doc(dbAs(RIVAL), BID_PATH)));
    const visitor = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(visitor, BID_PATH)));
  });

  it("denies every client write to a bundle bid (callables only)", async () => {
    await assertFails(setDoc(
        doc(dbAs(RIVAL), `bundles/${BUNDLE_ID}/bundleBids/${RIVAL}`),
        {...storedBid, providerId: RIVAL}));
    await assertFails(setDoc(
        doc(dbAs(REQUESTOR), `bundles/${BUNDLE_ID}/bundleBids/${REQUESTOR}`),
        {...storedBid, providerId: REQUESTOR}));
    await assertFails(updateDoc(
        doc(dbAs(PROVIDER), BID_PATH), {taskPrices: {[TASK_ID]: 1}}));
    await assertFails(deleteDoc(doc(dbAs(PROVIDER), BID_PATH)));
  });

  it("lets the requestor list every bid on their bundle, but not a provider", async () => {
    const bids = (uid) => collection(dbAs(uid), `bundles/${BUNDLE_ID}/bundleBids`);
    await assertSucceeds(getDocs(bids(REQUESTOR)));
    await assertFails(getDocs(bids(PROVIDER)));
  });

  it("lets a provider list their own bundle bids, not another provider's", async () => {
    const mine = (providerId) => getDocs(query(
        collectionGroup(dbAs(PROVIDER), "bundleBids"),
        where("providerId", "==", providerId)));
    await assertSucceeds(mine(PROVIDER));
    await assertFails(mine(RIVAL));
  });
});
