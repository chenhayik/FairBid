# FairBid - Bundled job postings with partial bids

Feature spec, researched 2026-09-10/11 and written 2026-09-12; nothing is built yet. It doubles as the prompt for the implementation session - hand the whole file over as-is.

## Goal

Let a requestor group 2-6 related tasks into ONE posting (a "bundle") instead of posting each task separately. A provider can bid on the whole bundle or only the tasks they can do. Awards should steer toward keeping as many tasks as possible with one provider - split awards cause coordination overhead and handoff disputes - without making the requestor overpay.

## Current system

- `jobs/{jobId}` has a single `acceptedProviderId` / `acceptedProviderName` / `acceptedBidAmountSen`. Bids: `jobs/{jobId}/bids/{providerId}`, one per provider. The `acceptBid` Cloud Function (`functions/index.js`) accepts one bid, rejects the rest, adds the amount to the requestor's `escrowLockedSen` and sets the job to `in_progress`.
- Milestones, chat (conversation id `jobId_providerId`), reviews, disputes, cancellation, notifications, Trust Score updates and `firestore.rules` (`isAcceptedProvider`) all assume one job = one provider.
- `closeExpiredJobs` cancels open jobs past their deadline every 6 hours.
- `onJobCompleted` adds 1 to `jobsCompleted` for both parties per completed job; this feeds the Trust Score track record and score visibility (`functions/trust.js`). Reviews: `users/{revieweeUid}/reviews/{jobId}_{reviewerUid}`.
- Best Value: `_compositeScore` in `job_detail_screen.dart`, weights in `PlatformConfig` (price 0.6, trust 0.4). Categories: `kServiceCategories`.

## Decided architecture - do not re-litigate

- `bundles/{bundleId}` is the posting: requestor, title, description, shared location and photos, deadline, status (`open` / `awarded` / `cancelled` / `expired`), ordered task ids, and a snapshot of the consolidation cap.
- Every task is an ORDINARY job in `jobs/{jobId}` with `bundleId` and `bundleOrder`, its own title, description, category and optional budget, and copies of the bundle's location and deadline. Each task keeps its own category, so an electrician filtering the feed by Electrical finds the electrical task in a bathroom bundle.
- Every awarded task is a normal one-provider job, so escrow, milestones, chat, disputes and cancellation keep working per task. Do NOT add a tasks array to `Job` and do NOT make `acceptedProviderId` plural.
- A `createBundle` callable validates the bundle (at most 6 tasks - add `maxBundleTasks` to `PlatformConfig` - plus lots and dependencies) and writes the bundle and its jobs atomically.

## Requestor side

- Post-a-job gains "Add another task" and "Start from a template".
- The bundle screen shows a provider x task price matrix plus the three award options (see Award).
- My Jobs groups a bundle's tasks, with progress worked out from the tasks (e.g. "2 of 4 in progress").
- The requestor can cancel an open bundle, which cancels all its tasks.

## Provider bidding

- Bundle tasks appear in the feed like any job, with a "Part of a 4-task bundle" chip; tapping one opens the bundle bid sheet.
- One package bid per provider per bundle at `bundles/{bundleId}/bundleBids/{providerId}`. Do not name it `bids`: `watchMyBids` runs `collectionGroup('bids')` and would read a bundle id as a job id. Add bundle bids to the provider's Pending Bids with their own collection-group rule.
- The bid form is exactly:
  - a price for each task the provider picks, labelled "Price if you get only this task", covering the whole task as described;
  - an optional bundle price, lower than the sum of the task prices, charged ONLY if the provider wins every task in their bid;
  - an "All or nothing" toggle: if on, the requestor may award all of the bid's tasks or none;
  - estimated duration and message, as on today's bid sheet.

  Nothing more expressive (no either/or packages, no tiered discounts).
- Bids are private: readable only by the bidder and the bundle's requestor. (The current per-job bid read rule is being tightened in a separate task - do not copy it.) Reuse the existing bid-rule checks: approved provider, not suspended, amount caps, Trust Score and photo snapshots pinned to the caller's profile.
- Bids can be edited or withdrawn while the bundle is open and before its deadline, mirroring `jobBiddingOpen`.
- Tasks in an open bundle reject ordinary per-job bids. Each task's `bidCount` counts the bundle bids that include it, kept up to date server-side.
- The bid sheet states the consolidation rule before the provider bids.

## Award

- The requestor awards the whole bundle in ONE action, any time before the deadline - the same timing as `acceptBid`. No task-by-task accepting. (Closing bidding first and awarding later would clash with `closeExpiredJobs`.)
- A `previewBundleAward` callable returns three options, each covering as many tasks as the bids allow:
  - **Cheapest:** lowest total;
  - **Fewest providers:** fewest providers, cheapest among those;
  - **Recommended:** fewest providers whose total is within the consolidation cap of Cheapest, ties broken by Trust Score then price; if none qualifies, it is the same as Cheapest.

  Each option shows the total in RM, the provider count, the extra cost vs Cheapest in RM and %, the Trust Score weighted by how much each provider is paid, any tasks left uncovered, and a warning if it splits dependent tasks between providers.
- Consolidation cap: at most X% and at most RM Y above Cheapest (see Open decisions). Keep both in `PlatformConfig` with the Cloud Functions copy in sync, as the codebase does for other limits.
- Rank by coverage first, then ringgit. The Best Value composite compares bids within one list and can't be summed across tasks - keep it only as the per-task badge in the matrix.
- Compute the options exactly with dynamic programming over task subsets, respecting all-or-nothing and lots (64 states at 6 tasks; about 11,000 steps for 15 bidders). A partial award of a bid without all-or-nothing is priced at its task prices.
- The requestor can override and pick any valid assignment in the matrix, including leaving a task unawarded.
- An `awardBundle` callable re-checks everything server-side in one transaction, following the `acceptBid` pattern: caller owns the bundle; bundle open; each task awarded at most once; all-or-nothing and lots respected; prices recomputed from stored bids, never client input; every involved bid re-read and unchanged since the preview; available wallet balance covers the total. Then it:
  - sets each awarded task to `in_progress` with `acceptedProviderId`/`acceptedProviderName` and its `acceptedBidAmountSen`. When a bundle price applies, split it across that provider's tasks in proportion to their task prices, in whole sen that add up EXACTLY to the bundle price - each task's milestone plan must equal its `acceptedBidAmountSen`;
  - adds the total to `escrowLockedSen` once;
  - marks each bid accepted, partly accepted or rejected;
  - releases unawarded tasks (see Coverage and expiry);
  - sets the bundle to awarded and notifies everyone involved.

## Coverage and expiry

- Providers may bid on any subset. No minimum-coverage rules and no bundle-only bidding: both push specialists out.
- At award, tasks with no bids, or that the requestor chose not to award, become standalone jobs: they keep `bundleId` for display, take ordinary bids through the existing flow, and get a new deadline set by the requestor.
- If the deadline passes with no award, `closeExpiredJobs` already cancels the open tasks; extend it to mark the bundle expired too.

## Templates, lots and order

- A short const list of bundle templates (e.g. bathroom renovation, kitchen refresh, move-in prep), in the style of `kServiceCategories`. Each template lists tasks in order with categories, plus optional dependencies and lots.
- Dependencies are finish-to-start only: `startsAfterJobId` plus `gapDays` on the task. They come from templates and are read-only; custom bundles have independent tasks in v1.
- Tasks sharing a `lotId` (e.g. waterproofing + tiling) must be bid on and awarded together, to one provider. Use lots only where a split is technically risky.
- When a task completes, notify the provider of the task that depends on it. Before starting, that provider records a site handover (photos + note) on the job timeline - evidence for disputes, not a payment gate.

## Trust, reviews and cancellation

- Count a bundle once per participant, not once per task: `onJobCompleted` adds to `jobsCompleted` only for the first completed task per (bundle, participant) and skips the rest.
- One review per reviewer per counterparty per bundle: for bundled jobs, build the review doc id from the bundle id instead of the job id, and prompt for the review after the provider's last task in the bundle completes.
- Cancellation and disputes stay per task, through the existing flows. Cancellation already needs the other party's consent, so a provider can refuse to drop the task their bundle price depended on; the request should say so.

## Licensing

- Electrical work in Malaysia needs an Energy Commission-registered contractor; major plumbing reportedly needs a SPAN-licensed plumber. Show a licence notice on tasks in those categories and let providers attach a certificate (existing `certificateUrls`). No structured licence checks in v1.

## Out of scope (v2)

- "Named helpers": a lead provider names another approved FairBid provider for a task they can't do, with escrow, Trust Score and disputes going through the lead. Needs legal review first (CIPAA 2012 s.30 and s.35).
- Requestor-editable dependencies; structured licence checks.

## Open decisions - ask the user before building

- Consolidation cap: suggested start 5%, plus an RM ceiling the user picks. No research gives a best value; tune it from real split-award disputes.
- Default deadline for released tasks.

## Acceptance criteria

- Single-task jobs work exactly as today: posting, bidding, award, escrow, chat, reviews, cancellation.
- A provider can bid on any subset; all-or-nothing and lots are enforced server-side; a bundle price is charged only when the provider wins every task in their bid.
- A competitor cannot read another provider's bundle bid.
- One award action covers the whole bundle. It fails cleanly, with no partial writes, if any bid changed or the wallet can't cover it.
- Each awarded task's milestone plan can total its `acceptedBidAmountSen`.
- Unawarded tasks become standalone jobs; an unawarded bundle expires with its tasks.
- A bundle adds at most one `jobsCompleted` per participant and one review per reviewer and counterparty.
- Firestore rules tests cover every new rule; `flutter analyze` and the functions lint and tests pass.

## Deliverable

Plan in phases, each testable on its own: (1) data model, `createBundle`, rules and rules tests; (2) bidding; (3) award options and `awardBundle`; (4) release, expiry, templates, lots and ordering; (5) Trust and review counting. Present the plan before writing code. After launch, track how often awards are split and how many handover disputes follow before adding more bid options.
