# Firestore security-rules tests

Automated tests for `../firestore.rules`, run against the real Firestore
emulator via `@firebase/rules-unit-testing` + Mocha. Unlike the Dart widget
tests (which use in-memory fakes), these actually evaluate the deployed rules
engine, so they prove the rules deny/allow what they claim to.

## Requirements

- Node.js (developed/tested with Node 22).
- **Java**, required by the Firestore emulator (`firebase emulators:exec`
  shells out to a JVM). If `java -version` fails, install a JDK first -
  there is no pure-JS fallback for the emulator.

## Install

```
cd firestore-tests
npm install
```

## Run

From `firestore-tests/`, spin up the emulator, run the suite against it, and
tear the emulator down again, all in one command:

```
npx firebase-tools emulators:exec --only firestore "npm test"
```

`emulators:exec` reads `../firebase.json` for the emulator config (Firestore
on port 8080) and sets `FIRESTORE_EMULATOR_HOST` for the test process, which
`initializeTestEnvironment()` picks up automatically.

To iterate faster while writing tests, you can instead leave the emulator
running in one terminal (`npx firebase-tools emulators:start --only
firestore`, from the repo root or here) and just re-run `npm test` in
another - `FIRESTORE_EMULATOR_HOST` defaults to `localhost:8080`, matching
`firebase.json`.

## What's covered

`rules.test.js`, one `describe` block per collection:

- **Bids** (`jobs/{jobId}/bids/{bidId}`): amount validation (positive
  integer, ≤ 100,000,000), the `providerTrustScore`/`providerScoreVisible`/
  `providerPhotoUrl` snapshots must match the provider's own stored profile
  (can't forge a higher Best Value ranking or put someone else's photo on a
  bid), approved-provider-only, open-job-only.
- **Reviews** (`users/{revieweeId}/reviews/{reviewId}`): rating must be an
  integer 1–5, doc id must be `{jobId}_{reviewerId}` (blocks the
  multi-review-per-job spam vector), job must be `completed`, reviewer must
  be a participant, no self-reviews.
- **User profile self-writes** (`users/{uid}`): a user can update ordinary
  fields (`displayName`, `phone`, `bio`, ...) but not the Trust Score/wallet
  fields (`trustScore`, `ratingSum`, `ratingCount`, `jobsCompleted`,
  `disputesLost`, `trust`, `walletBalanceSen`, `escrowLockedSen`) or the
  public-profile client-history counters (`jobsPosted`, `jobsAssigned`,
  `hireRate`) - all Cloud-Function-only; a create is denied if it carries a
  nonzero wallet balance, any trust field, or a forged `jobsPosted`/
  `hireRate`.
- **Conversations** (`conversations/{id}`): an update can only touch the
  message-preview/unread-counter fields - writing `chatClosesAt` (the
  chat-reopen hole) or changing `participantIds` is denied.
- **Server-only collections**: `transactions/{id}` and `disputes/{id}` deny
  every client write; a `milestones` doc `create` is denied even for the
  job's own requestor/accepted provider - all three are Cloud-Function-only.
- **Service address privacy** (`jobs/{jobId}/private/address`): only the
  job's owner (read + write), its accepted provider (read only) and admins
  (read only) may read it - a signed-in non-participant is denied read; a
  suspended owner is denied write; delete is always denied.
- **Private payout doc** (`users/{uid}/private/payout`): payout bank details
  and the phone number, moved off the world-readable `users/{uid}` doc -
  only the owner (read + write) and admins (read only) may read it; another
  signed-in user is denied.

## Notes

- Each test seeds its own prerequisite documents (job status, provider
  trust snapshot, participant lists, etc.) with
  `testEnv.withSecurityRulesDisabled(...)`, then asserts the actual write
  under test with `assertFails`/`assertSucceeds`.
- `afterEach` calls `testEnv.clearFirestore()` so tests don't leak state
  into each other.
- This suite intentionally does **not** touch `firestore.rules`,
  `functions/`, or any Dart code - it only reads the rules file and asserts
  against it.
