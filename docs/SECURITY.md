# FairBid — Security & Threat Model

## 1. Overview

FairBid holds real value in escrow (wallet balances and milestone payments) and
stakes each provider's standing on a **Trust Score** that drives job ranking. A
marketplace where money *and* reputation move is only as trustworthy as its
weakest write path. This chapter documents FairBid's security model, the threats
it defends against, an adversarial audit of the implementation, and the
vulnerabilities that were found and fixed — each one now covered by an automated
test.

## 2. Security architecture

Three principles underpin the design:

1. **The client is never trusted with money or reputation.** Every field that
   represents value or trust — `walletBalanceSen`, `escrowLockedSen`,
   `trustScore`, the `trust` breakdown, `ratingSum`/`ratingCount`,
   `jobsCompleted`, `disputesLost` — is written **only** by Cloud Functions
   running with the Firebase Admin SDK (which bypasses security rules). Firestore
   rules **deny every client write** to these fields, at both creation and
   update time.
2. **Firestore Security Rules are the authorization boundary.** All direct
   client reads/writes pass through rules that enforce ownership, role and state
   preconditions. Rules are treated as untrusted-input validation, not as UI
   convenience.
3. **Secrets never ship in the app.** API keys (Gemini, and the payment gateway)
   live in Google Cloud Secret Manager and are read only inside Cloud Functions;
   the distributed APK contains none.

Every money movement — accept-bid escrow lock, milestone fund/release, dispute
resolution, top-up and withdrawal — runs inside a **Firestore transaction** in a
Cloud Function, so concurrent requests cannot interleave to double-spend, and
**all reads precede all writes** as the API requires.

## 3. Threat model

Adversaries considered:

- **Malicious provider** — wants to win jobs unfairly, forge reputation, or
  extract money.
- **Malicious requestor** — wants free work, or to drain/forge their own wallet.
- **Colluding pair** — a provider *and* requestor account controlled by one
  attacker (the most powerful realistic adversary).
- **Forged server callbacks** — a third party POSTing to public webhook
  endpoints (relevant to the payment integration).
- **Concurrent / replayed requests** — race conditions, and at-least-once
  Cloud Function trigger retries.
- **Prompt-injection / SSRF** via the AI assist features.

## 4. Adversarial audit — vulnerabilities found and fixed

An adversarial review of the shipped implementation surfaced the following
defects. Each was fixed and is locked in by an automated test.

### 4.1 [CRITICAL] Negative-bid escrow underflow → wallet theft

A bid's `amountSen` was validated on the client but **not server-side**. An
attacker controlling one approved-provider and one requestor account could write
a bid with `amountSen: -100000` directly to Firestore. Accepting it drove the
requestor's `escrowLockedSen` **negative**, which inflated their *available*
balance (`walletBalanceSen − escrowLockedSen`) and let them withdraw money that
was never deposited.

**Fix:** the bid create/update rule now requires
`amountSen is int && > 0 && <= 100_000_000`, and `acceptBid` re-validates the
stored amount server-side before locking escrow — defence in depth, so even a
legacy or forged document fails safely rather than corrupting the ledger.

### 4.2 [HIGH] Trust-Score forgery and review spam

The review-create rule checked the two parties but not the rating value, nor a
one-review-per-job constraint. A colluding pair could spam unlimited 5★ reviews
(each firing the score recompute) to max a provider's Trust Score, and a single
`rating: 100000` — or a non-numeric rating — could poison or `NaN` the stored
aggregate.

**Fix:** the rule now requires `rating is int && rating >= 1 && rating <= 5` and
binds the review document id to `{jobId}_{reviewerId}`, enforcing one review per
reviewer per job at the authorization boundary (not just in client code).

### 4.3 [HIGH] Bid trust-snapshot forgery → ranking manipulation

Each bid carries a `providerTrustScore` snapshot that the requestor's "Best
Value" ranking blends with price. A provider could write
`providerTrustScore: 1000` on their own bid to top the ranking regardless of
their real score — directly defeating the platform's core fairness promise.

**Fix:** the bid rule *pins* `providerTrustScore` (and `providerScoreVisible`)
to the caller's own stored profile value via a rules `get()`, so the snapshot
must equal reality.

### 4.4 [HIGH] Unbounded wallet minting

The demo top-up capped a single call but had no cumulative ceiling, so a client
could loop it to mint an arbitrary balance.

**Fix:** `topUpWallet` became a transaction that rejects any top-up which would
push the balance over a fixed ceiling (RM 50,000).

### 4.5 [MEDIUM] Non-idempotent reputation triggers

`recomputeTrustScore` and `onJobCompleted` used additive writes; Firestore's
at-least-once trigger delivery could double-count a rating or a completed job on
a retry.

**Fix:** each carries a deterministic processed-marker (`countedInTrust` on the
review document, `completionCounted` on the job), read and set inside the same
transaction as the increment, so a replayed event is a no-op.

### 4.6 [MEDIUM] Chat re-open via a permissive update rule

The conversation update rule allowed writing *any* field, including
`chatClosesAt` — so a participant could reopen a chat the server had closed
after a job ended.

**Fix:** the update rule allowlists only the last-message-preview and unread-
counter fields; `chatClosesAt` and `participantIds` can no longer be written by
a client.

### 4.7 Server-only bid acceptance and escrow bookkeeping

`acceptBid` was migrated from a client Firestore transaction to a Cloud Function
so the wallet-balance gate cannot be bypassed. An `escrowLockedSen` field tracks
committed-but-not-yet-funded amounts across the accept → fund → release/cancel
lifecycle, so a requestor cannot accept more work than their balance can
eventually fund, and cancellation never strands or leaks escrow.

### 4.8 Bidding-deadline enforcement

A job's optional bidding deadline is enforced **server-side**: the bid rule
(`jobBiddingOpen`) denies a bid once the deadline has passed — even before the
scheduled `closeExpiredJobs` sweep flips the job's status — rather than merely
hiding the button in the UI.

### 4.9 SSRF guard on AI image analysis

The multimodal AI quote fetches a job photo server-side to pass to Gemini. The
fetch is pinned to the project's own Storage bucket
(`https://firebasestorage.googleapis.com/v0/b/<bucket>/…`) with a byte cap and a
timeout, so a crafted `photoUrl` cannot make the function fetch an arbitrary
internal or external URL. Any image failure degrades to text-only rather than
erroring.

## 5. Defence-in-depth patterns

- **Rules *and* server re-validation.** Critical invariants are checked at the
  rules boundary and re-checked inside the Cloud Function that acts on them.
- **Deterministic document ids as idempotency keys** — reviews
  (`{jobId}_{reviewerId}`), milestones (`m{n}`), timeline events, and (for the
  payment integration) the gateway bill code.
- **Transactions, reads-before-writes**, for every balance mutation.
- **Secrets in Secret Manager**, never in the client bundle.

## 6. Testing methodology

Security properties are held in place by automated tests, not manual checking:

- **A Firestore-emulator rules suite** (`@firebase/rules-unit-testing`) — 38
  tests asserting the denials and allows above: negative / zero / over-cap /
  non-integer bids, forged trust snapshots, review rating and doc-id gating,
  the bidding-deadline gate, client writes to trust/wallet fields, and the
  server-only `transactions`/`disputes`/`events` collections.
- **Trust-Score parity vectors** shared between the Dart client and the Cloud
  Function implementation, so the two never drift.
- **85 Flutter widget tests** exercising the end-to-end flows against in-memory
  fakes.

## 7. Limitations and future work

- **Payments.** Wallet top-up is being moved from a demo stand-in to a sandbox
  payment gateway (toyyibPay — FPX / DuitNow QR). Credit remains
  server-authoritative: a verified webhook re-queries the gateway before
  crediting, and a deterministic bill-code idempotency key prevents
  double-credit. Production compliance (PCI-DSS, merchant onboarding) is out of
  scope for this project.
- **Identity / credential verification** (SSM, CIDB) is by manual admin review
  rather than API-verified against the issuing authority.
- **Rate limiting / abuse throttling** on callable functions relies on Firebase
  defaults; a production deployment would add per-user quotas.
