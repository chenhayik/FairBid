# FairBid - One-payment escrow, optional stages and appointments

## Goal

After a bid is accepted, a normal job should go straight to agreeing a visit time. The whole price is secured in escrow at award, and paid out in one go when the work is done. Staged payments stay available for big jobs, where they protect both sides, but nobody has to plan, approve or fund stages for a RM150 aircon service.

Happy path today: award → provider proposes a plan → requestor approves → requestor funds → provider marks done → requestor releases. No visit time is ever agreed in the app.

Happy path after this: award (money moves to escrow) → provider proposes a time → requestor confirms → provider marks done → requestor releases, or it auto-releases after 7 days.

## Current state (read before planning)

- `acceptBid` and `awardBundle` move no money. They add the accepted amount to the requestor's `escrowLockedSen`, a commitment against their balance.
- The provider proposes a plan with `proposeMilestonePlan` (1-20 stages, summing exactly to `acceptedBidAmountSen`). The requestor then calls `approveMilestonePlan` (stages become `pending`) or `rejectMilestonePlan`.
- `fundMilestone` moves each stage's amount from `walletBalanceSen` into escrow and reduces `escrowLockedSen`. The provider marks it `submitted` with a direct client write (`firestore.rules`: funded → submitted, only `status` and `submissionNote`). `releaseMilestone` pays the provider and completes the job once every stage is terminal and the plan covers the price (`completesJob` in `functions/price_change.js`).
- Disputes are per stage. A refund ruling returns the stage to `pending` for rework and re-locks the amount.
- Cancellation (mutual consent, or `adminCancelJob`) is refused while any stage is funded, submitted or disputed (`hasHeldEscrow`). `finaliseCancellation` deletes unfunded stages and unlocks the rest of the commitment.
- Price change (`requestPriceChange` / `respondToPriceChange`) requires the new price to exceed the funded total. It moves `escrowLockedSen` by the difference and leaves an unplanned remainder that the provider must re-plan.
- Categories come from `kServiceCategories`. There is no Renovation category: renovation work falls under Home Repair.

## Decided - do not re-litigate

- Keep milestones as the underlying model; the UI calls them "stages". A one-payment job is simply a one-stage plan, so disputes, the ledger, Earnings, reviews and completion keep working unchanged.
- The full price is funded at award.
- Staged payments are offered only for Home Repair jobs or jobs priced above RM 3,000.
- Payment auto-releases 7 days after the provider marks a stage done, unless the requestor releases it or raises a dispute first.
- An agreed appointment is required before the provider can mark work done.
- Stages may have an optional due date. It is informational: money is released only when the work is done.
- No date-based payouts. Recurring bookings (weekly cleaning, etc.) are out of scope.

## Phase 1 - fund at award, one stage

- `acceptBid`: keep today's check (`walletBalanceSen - escrowLockedSen` covers the price). Then, in the same transaction:
  - subtract the price from `walletBalanceSen`;
  - create one milestone: description "Full job", amount = `acceptedBidAmountSen`, `status: "funded"`, order 0;
  - write a `fund` ledger entry;
  - set `fundedAtAward: true` on the job.

  `escrowLockedSen` is no longer touched for these jobs.
- `awardBundle`: the same, once per awarded task, each stage worth that task's `acceptedBidAmountSen`. The existing whole-sen split of a bundle price already makes these add up exactly to the total. It stays one wallet write and one transaction.
- Legacy: jobs already in progress without `fundedAtAward` keep today's flow (propose, approve, fund). Keep every existing callable working for them. Don't migrate old jobs.
- Cancellation for `fundedAtAward` jobs: allowed while no stage is `submitted` or `disputed`. Funded stages that haven't been submitted are refunded to the requestor's `walletBalanceSen` (with a `refund` ledger entry) and deleted. Released stages stay paid. `adminCancelJob` follows the same rule.
- Price change for `fundedAtAward` jobs:
  - Increase: the difference must be covered by the available balance when the requestor agrees. It moves wallet → escrow. If the job has exactly one stage and it hasn't been submitted, that stage's amount grows. Otherwise a new funded stage "Price change" is added.
  - Decrease: the difference is refunded to the requestor from funded, unsubmitted stages, taking from the last stage first. It can't be more than those stages hold together.
  - A disputed stage still blocks a price change. `completesJob` still requires the plan to equal the price.
- Dispute refunds keep today's behaviour: the stage returns to `pending` and must be funded again through `fundMilestone`. That is a rare path, so it keeps the legacy funding step.
- Job detail: for `fundedAtAward` jobs the bottom bar never shows "Propose milestones", "Approve plan" or "Fund". The stage card reads "RM X secured in escrow".

## Phase 2 - appointments

- Posting: an optional preferred date and time window (morning, afternoon or evening) on the job. It is shown to bidders and pre-fills the provider's first proposal. It is optional so posting stays quick.
- Appointment on the job: `appointment: {startAt, endAt?, status: "proposed" | "confirmed", proposedBy, proposedAt, confirmedAt}`, plus `appointmentChanges` (a count). `endAt` is an optional finish date for multi-day work. Use the same step for remote categories (Tutoring, IT, Design), labelled "Start time".
- `proposeAppointment` callable: either party on an in-progress job proposes a start (and optional finish). It must be in the future, and at most 90 days out. It replaces any pending proposal. On a confirmed appointment it counts as a reschedule.
- `confirmAppointment` callable: only the other party can confirm. Confirming copies nothing else and notifies the proposer.
- Reschedule: either party proposes a new time, and the other confirms. The confirmed appointment stays in force until the new one is confirmed. A proposal made less than 24 h before a confirmed start is recorded as late (`lateRescheduleBy: uid`). v1 only records it; see Open decisions.
- Required: `firestore.rules` rejects the funded → submitted write unless `get(job).data.appointment.status == "confirmed"`. Legacy jobs without `fundedAtAward` are exempt.
- Bundles: each awarded task has its own appointment. A provider with several tasks in one bundle can "Use this time for my other tasks", which sends one proposal per task.
- Reminders: a scheduled function every 15 minutes notifies both parties 24 h and 2 h before a confirmed start. Flags on the appointment (`reminded24h`, `reminded2h`) prevent repeats.
- Timeline: events for proposed, confirmed and rescheduled appointments, logged by the existing job-event trigger pattern.
- Bottom bar order after award: provider "Propose a time" → requestor "Confirm time" (or "Suggest another") → provider "Mark as done" → requestor "Release payment".

## Phase 3 - auto-release

- Rules: the funded → submitted write must also set `submittedAt == request.time`.
- Pull the body of `releaseMilestone` into a shared helper, and use it from both the callable and the scheduled job, so there is one release path.
- A scheduled function (hourly) runs a collection-group query for milestones with `status == "submitted"` and `submittedAt` older than `autoReleaseDays` (7). It releases each one through the helper, with `releasedBy: "auto"` on the stage and ledger entry. A disputed stage is never `submitted`, so a dispute stops the clock. Needs a composite index (`status`, `submittedAt`).
- Tell the requestor when a stage is submitted ("auto-releases on 12 Oct") and again 2 days before.
- `autoReleaseDays` goes in `PlatformConfig`, with the Cloud Functions copy kept in sync.

## Phase 4 - optional stages, due dates, deposit

- Eligible when `category == "Home Repair"` or `acceptedBidAmountSen > 300000`. Put `stagedMinSen` and `stagedCategories` in `PlatformConfig`, mirrored in functions, and check on the server.
- The provider can "Split into stages" while no stage has been submitted, released or disputed. It reuses `ProposeMilestonesSheet` and `proposeMilestonePlan`. For `fundedAtAward` jobs the stages being replaced are funded, so the new plan must add up to the amount they hold. On approval the new stages are created `funded` and the old ones deleted, with no wallet movement. Rejection leaves the current plan in place.
- Due dates: optional `dueDate` on each stage. The provider gets a reminder the day before. Once a stage is past its date and not yet submitted, it shows an "Overdue" badge and both parties are notified once. Due dates never move money.
- Deposit: an optional first stage marked `deposit`, at most 30% of the price. It is released to the provider as soon as the requestor approves the plan; that approval is the requestor's consent. The sheet must say a deposit can't be recovered through a dispute.
- The plan sheet offers a template: deposit, progress stages, and a final 10% "Final inspection" stage.

## Out of scope

- Recurring bookings.
- Penalties for no-shows and late reschedules, beyond recording them.
- Calendar sync (Google Calendar / .ics).
- Migrating legacy in-progress jobs.

## Open decisions - ask the user before building

- Late reschedules and no-shows: only record them in v1, or also count them against the Trust Score?
- Deposit: keep the 30% cap and "released on approval", or leave deposits out of Phase 4?
- Should bundle tasks always be eligible for stages, or follow the same Home Repair / RM 3,000 rule as any other job?
- Not a code decision: check that holding the full price in escrow fits the toyyibPay setup and Bank Negara's e-money rules.

## Acceptance criteria

- New single jobs and bundle tasks are funded at award in one transaction, and fail cleanly if the wallet can't cover them. Legacy in-progress jobs behave exactly as before.
- A new job can go award → appointment → done → paid without anyone proposing, approving or funding a plan.
- Work can't be marked done without a confirmed appointment (rules-tested). Reminders fire once each.
- Cancellation before any stage is submitted refunds the requestor in full. Price increases and decreases keep wallet, escrow and plan totals consistent.
- A submitted stage auto-releases after 7 days unless it is released or disputed first. It pays exactly once, even if the scheduled job and a manual release race.
- Staged plans are offered only to eligible jobs, re-split funded money without moving it, and honour the deposit cap.
- Pure rules (eligibility, price-change deltas, cancellation refunds, auto-release and reminder due-ness) live in a dependency-free module with `npm test` coverage, like `price_change.js`. Rules tests cover the new write gates.

Build in phases, each testable on its own. Present the plan before writing code.
