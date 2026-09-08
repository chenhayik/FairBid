# FairBid frontend audit - Stage 2 plan

Stage 1 (shipped) covered the safety issues and the S-effort quick wins. This file
is the executable backlog for Stage 2. Every item below is grounded in the audit and
was verified against the code at the time of writing.

## Already done in the Stage 2 pass

Struck off the backlog below; kept here so the numbering still matches the audit.

- **S1 stream hoisting** - done via a new shared
  `lib/core/widgets/keyed_stream_builder.dart` (`KeyedStreamBuilder`), applied at all
  9 sites. Converting each screen to a `StatefulWidget` would have been far more
  churn for the same fix; the widget also documents the hazard in one place. Builders
  now branch on `hasData`/`hasError` instead of `connectionState`, and
  `_JobFilterBar` was moved outside its builder.
- **S2 card ripple** - `AppCard` now renders its fill *as* a `Material` and takes
  `onTap` and `color`. The 7 `InkWell(child: AppCard(...))` wrappers were rewritten,
  and `notifications_screen`'s hand-rolled tinted card now reuses `AppCard(color:)`.
  **Never wrap an `AppCard` in an `InkWell` again** - pass `onTap` instead.
- **S3 error branches** - added to all four outer streams (`job_detail_screen`,
  `public_profile_screen`, `conversation_thread_screen` via a new
  `_ChatUnavailableFooter`, `job_address_card`).
- **S12 reduced motion** - `lib/core/util/motion.dart` exposes `motion(context, d)`,
  wired into the two existing animations. **Route every new duration through it.**
- **D3 haptics** - done at all six confirmation sites plus `heavyImpact` on payment
  failure. Busy states for `_openJobChat` / `_withdrawBid` / `_cancelJob` /
  "Mark all read" are still outstanding.

Baseline held throughout: `flutter analyze` clean, 116/116 tests passing.

## Also done in the Stage 3 pass

- **`topUpWallet` closed.** It now refuses unless `FUNCTIONS_EMULATOR` is set, so
  the demo top-up cannot mint spendable balance in production. The client flag
  `PlatformConfig.demoTopUpEnabled` became an explicit
  `--dart-define=FAIRBID_DEMO_TOPUP=true` opt-in rather than `kDebugMode`, because
  the app has no emulator wiring and a debug build talks to the real project -
  keying off debug mode would have shown a button the backend then rejected.
- **D1, partly.** The category filter is now server-side, using the previously
  unused `(status, category, createdAt)` index, and the feed is bounded to
  `kOpenJobsPageSize` with a "Load more" control that grows the window rather than
  paging (so the list stays live). `watchMyBids` / `watchProviderMilestones` are
  still deliberately unbounded - see D1 above for why limiting them would corrupt
  money totals. Denormalised counters remain the outstanding half.
- **High-severity dependency patched** via `npm audit fix`. The remaining 8
  moderates need `firebase-admin` 12 -> 14, two majors on the money backend with no
  test exercising it; do that as its own change, not folded into something else.
- **Stale trust score on bids fixed by reading live, not by fanning out.**
  `Bid.providerTrustScore` is copied at bid time, but Best Value and the Trust
  sort ranked on that snapshot, so today's bids were ordered by last week's
  reputation while each provider's profile showed the current number. The bid
  list now resolves the live score via `PublicProfileRepository.fetchTrust` and
  applies it with `Bid.withTrust`, falling back to the stored snapshot until it
  lands (so the list still renders in one pass) and on error.

  A Cloud Functions fan-out was considered and rejected: trust changes on
  *profile edits* as well as reviews, it needs a new collection-group index that
  must be deployed separately, each fan-out write re-invokes `onBidAccepted`,
  and nothing in CI could exercise it since there are no functions-emulator
  tests. Reading live needs no index, no trigger and no consistency window, and
  the existing `allow read: if isSignedIn()` rule on `users/{userId}` already
  permits it. The cost is a handful of reads per bid-list view.

  **The other denormalised fields were left alone deliberately.** `bidCount`,
  `lastMessageText` and `unreadCounts` are actively maintained in the same
  transaction as the thing they describe; `Review`'s reviewer name, photo and
  job title are correct *because* they are frozen. Only the trust score was
  both stale and load-bearing.
- **The two untested funnels now have tests** (+5, suite at 121). Writing them
  surfaced a real bug: `PostJobController.setLocation` called `notifyListeners()`
  from `initState`, tripping `'!_dirty'` for every requestor with a saved default
  location. Fixed with a non-notifying `seedLocation`. Assertions are disabled in
  release builds, which is why this had gone unnoticed.

**Baseline to preserve:** `flutter analyze` clean, `flutter test` 116/116 passing.
Re-run both after every item. The repo is *not* `dart format` clean (104 of 127 files
differ from the formatter's style), so **do not run `dart format`** - match the
surrounding style by hand or the diff becomes unreviewable.

---

## Deferred from Stage 1, with the reason

These were planned for Stage 1 and deliberately not done. Each needs more than a
one-line change, and doing them carelessly causes a regression.

### D1. Query bounds - `.limit()` is NOT a safe one-liner here
**HIGH once the dataset grows · `job_repository.dart:93`, `bid_repository.dart:142`, `milestone_repository.dart:100`**

The audit proposed adding `.limit()` to three unbounded queries. Two of them **must
not** get a bare limit:

- `watchProviderMilestones` is folded into a money total - "Total Earnings"
  (`provider_home_screen.dart:183`) and the wallet's escrow stats
  (`earnings_screen.dart`). A limit would silently under-report earnings. That is a
  correctness bug strictly worse than the performance problem.
- `watchMyBids` is folded into a pending-bid count (`provider_home_screen.dart:155`).
  Same class of problem.
- `watchOpenJobs` feeds **client-side** filtering (`job_feed_screen.dart:_applyFilters`
  does category, text, budget and radius in Dart). Limiting the query truncates the
  universe the filters run over, so a category filter could return nothing simply
  because the newest 30 jobs are all in other categories.

**Correct fix, in this order:**
1. Push the category filter into the query - `where('category', isEqualTo: ...)`. The
   composite index `status + category + createdAt` **already exists** and is currently
   unused (`firestore.indexes.json:11-19`).
2. Add cursor pagination to the feed, copying the pattern already working in
   `user_reviews_screen.dart:65-93` + `review_repository.dart:75-90` (the app's only
   paginated list).
3. Only then add `.limit()` to the feed query.
4. For the two aggregate queries, replace the streams with **denormalised counters**
   (`pendingBidCount`, `totalEarnedSen`) maintained by the Cloud Functions that already
   fire on bid and milestone status changes, read from `AuthController.user`. That turns
   two collection-group listeners into zero.

**Effort:** L. Do not attempt as a quick win.

### D2. Unsaved-work guard on Post-a-Job
**MED · `post_job_screen.dart:255`**

`PopScope` needs care here and is why it was deferred:
- A dirty-check computed at build time goes **stale**, because typing in a `TextField`
  does not rebuild the parent. Either add listeners to the five controllers
  (`_title`, `_description`, `_address`, `_budgetMin`, `_budgetMax`) that `setState`
  when the dirty flag flips, or use `canPop: false` and decide inside the callback.
- With `canPop: false`, the guard also intercepts the screen's **own** successful pop in
  `_submit` (`post_job_screen.dart:183`). Needs a `_posted` bypass flag, or the user gets
  a "discard this job post?" dialog immediately after successfully posting.
- Use the official Flutter `PopScope` sample shape: capture
  `final navigator = Navigator.of(context)` *before* the await, then `navigator.pop()`.

Dirty = any of the five controllers non-empty, `_deadline != null`,
`controller.photoUrls.isNotEmpty`, or `controller.videoUrl != null`. Do **not** count
location - it is pre-filled from the onboarding default (`_locationDefaulted`).

Also apply `isDismissible: !busy` to `WalletAmountSheet`, which can currently be
swipe-dismissed while a payment call is in flight (`wallet_amount_sheet.dart:60`).

**Effort:** M. Add a widget test that types into the form, pops, and asserts the dialog.

### D3. Remaining haptics and busy states
**MED · S each**

Stage 1 did Accept Bid and Submit Bid. Still to do, all fire-and-forget via
`unawaited(HapticFeedback...)` - see below for why:
- job posted `post_job_screen.dart:183`
- milestone fund/deliver/release `milestone_section.dart:319-321` (the `outcome: 'ok'`
  branch of `_run` - one central place covers three actions)
- plan approved `milestone_section.dart:255`
- review submitted `leave_review_sheet.dart:90`
- top-up / withdraw `wallet_amount_sheet.dart:88`
- `heavyImpact()` on payment failure `milestone_section.dart:340`

Busy states still missing: `_openJobChat` (`job_detail_screen.dart:93`, does 2-3 round
trips before navigating), `_withdrawBid` (`:115`), `_cancelJob` (`:265`), and
"Mark all read" (`notifications_screen.dart:55`).

---

## Two hard-won lessons from Stage 1 - read before writing code

**1. Never `await` a haptic.** Awaiting `HapticFeedback.mediumImpact()` broke a passing
test: it put an async gap in front of `Navigator.pop()`, so the bid sheet was still up
when the next assertion ran. Worse, inside a `try` it meant a haptic failure would be
caught and reported to the user as a failed bid acceptance. Always
`unawaited(HapticFeedback.x())`.

**2. Clear a busy flag before awaiting an error dialog.** Resetting the spinner in a
`finally` left an indeterminate `CircularProgressIndicator` animating behind an awaited
`showDialog`, so `pumpAndSettle` never settled and the test timed out. The shape that
works (now in `_accept`, `job_detail_screen.dart:982`):

```dart
Object? failure;
setState(() => _busy = true);
try { await call(); } catch (e) { failure = e; }
if (!mounted) return;
setState(() => _busy = false);   // clear BEFORE reporting
if (failure == null) { ...success...; return; }
// ...then handle failure by type
```

Any Stage 2 item that adds a spinner plus an error dialog must follow this shape.

---

## Ranked Stage 2 backlog

### S1. Hoist streams out of `build()`
**HIGH · M · `job_feed_screen.dart:135`, `my_jobs_screen.dart:93`/`:186`, `saved_jobs_screen.dart:25`, `messages_screen.dart:51`, `provider_home_screen.dart:123`/`:149`/`:177`/`:216`, `profile_screen.dart:239`/`:521`, `requestor_home_screen.dart:47`, `dispute_queue_screen.dart:21`, `verification_queue_screen.dart:23`**

`.snapshots()` returns a new `Stream` per call, so `StreamBuilder` unsubscribes and
resubscribes on every rebuild, resetting to `waiting` and discarding good data. The
correct pattern is already in the codebase with explanatory comments -
`job_detail_screen.dart:53`, `milestone_section.dart:49`,
`conversation_thread_screen.dart:37-38`, `app_shell.dart:86-90` - it just was not
applied to the list screens.

- Hoist to `late final` fields; for args that change (`saved_jobs_screen`'s watchlist,
  `messages_screen`'s uid) resubscribe in `didUpdateWidget` only when the arg differs.
- Change `if (connectionState == waiting) return spinner;` to
  `if (!snapshot.hasData) return skeleton;` so retained data is never thrown away.
- Move `_JobFilterBar` **outside** its `StreamBuilder` in `my_jobs_screen.dart:118`, or
  the filter chips themselves vanish during the flash.

Stage 1's search debounce (`job_feed_screen.dart`) reduced the symptom but not the cause.
**Do this before S5 (skeletons)** - it removes most of the spurious spinners skeletons
would otherwise paper over.

### S2. Card taps have no ripple - ink paints under an opaque child
**HIGH · M · `app_widgets.dart:257` (`AppCard`) + ~13 call sites**

`_RenderInkFeatures.paint` draws ink, then `super.paint` draws children, so `AppCard`'s
opaque white `Container` completely covers the splash. Every list row in the app is a
visually dead tap.

Give `AppCard` an optional `onTap` and render its fill via `Ink(decoration:)` (or
`Material(color:) > InkWell`) so the ink layer sits above the fill. Then move the ~6
hand-rolled clones over: `job_card.dart:38`, `messages_screen.dart:106`,
`my_jobs_screen.dart:257`, `notifications_screen.dart:119`, `profile_screen.dart:366`
and `:490`, `job_detail_screen.dart:1226`.

### S3. Outer streams have no error branch - failures render as "this doesn't exist"
**HIGH · M · `job_detail_screen.dart:59`, `public_profile_screen.dart:49`, `conversation_thread_screen.dart:68`, `job_address_card.dart:54`**

Each reads `snapshot.data` and branches on null without checking `hasError`, so a
permission-denied or offline stream produces a confident falsehood: "Job not found. It
may have been removed by the requestor", "This account may have been deleted". The chat
case is worst - `conversation` stays null forever so `_Composer` renders
`enabled: false` with `onSend: null`: a permanently dead text box with no explanation.

Add `if (snapshot.hasError)` to each with a distinct "Couldn't load this right now"
state. For chat, use an explicit error footer alongside the existing `_ClosedChatFooter`
pattern at `:229`. A permission-denied stream is terminal, so the copy must tell the
user to back out and re-enter.

### S4. Retry affordances - 23 error states, zero retries
**MED · M · `app_widgets.dart:364` (`EmptyState`) + 11 sites**

Every error says "Please check your connection and try again" but nothing offers a
retry; `Retry`/`Try again` as a button label returns zero hits across `lib/`. Add
optional `actionLabel`/`onAction` to `EmptyState` (~15 lines), then bump a `_retryToken`
in state to rebuild the stream. Do the six highest-traffic sites first: feed, my jobs,
messages, notifications, wallet x2.

### S5. Skeleton screens
**MED · M · `job_feed_screen.dart:138`, `messages_screen.dart:54`, `job_detail_screen.dart:65` first**

Build one `Skeleton` primitive in `app_widgets.dart` (an `AnimatedBuilder` over a
gradient `ShaderMask` - no new dependency) plus `JobCardSkeleton`,
`ConversationTileSkeleton`, `DetailSkeleton`. **Gate the shimmer on reduced motion (S12)**
and remember lesson 2 above: an always-animating skeleton will hang `pumpAndSettle` in
any test that reaches it.

### S6. Image caching for avatars
**HIGH · M · `user_avatar.dart:48`**

Add `cached_network_image`. `NetworkImage` has no disk cache, so every cold start
re-downloads every avatar - and `UserAvatar` renders per conversation row, per bid, per
review, plus both profile headers. Swap only two implementations: `UserAvatar`
(`CachedNetworkImageProvider`) and a small shared `AppNetworkImage` for the scrolling
strips. Stage 1 already added `cacheWidth` at the four thumbnail sites, which solved the
decode-size half of the problem; this is the disk-cache half.

### S7. Post-a-Job submit placement
**MED · M · `post_job_screen.dart:415`, `:272`, `:149`**

The submit *spinner* is fine (Stage 1 confirmed `_SubmitOverlay` handles it). The
remaining defect is that submit sits at the bottom of a four-section scroll view while
all three failure channels render above it. Move submit into a pinned
`bottomNavigationBar` (pattern exists at `job_detail_screen.dart:428`), and
`Scrollable.ensureVisible` the first invalid field (helper at
`job_detail_screen.dart:188`). Pairs naturally with D2.

### S8. Provider navigation - finding jobs has no tab
**MED · M · `app_shell.dart:32`, `provider_home_screen.dart:66`, `app_router.dart:74`**

Bottom nav is Home / My Jobs / Messages / Profile; the job feed is a pushed route behind
a small "View all" link, below four stat cards. Add a `StatefulShellBranch` for `/jobs`
with role-conditional destinations, or at minimum move "Jobs near you" above the stat
grid. Note `/jobs` currently sits **outside** the shell - Stage 1 worked around this in
`pending_review_screen.dart` with `go('/home')` then `push('/jobs')`; moving it into the
shell would let that revert to a plain `go`.

### S9. Terminology: Client vs Requestor vs Customer
**MED · M**

Standardise on **Client** and **Provider** (Client is already the majority usage and the
friendlier word). Sweep `user_role.dart:13`, `job_detail_screen.dart:76`,
`job_address_card.dart:158`, `provider_home_screen.dart:224`, `post_job_screen.dart:266`,
`register_screen.dart:85`, `login_screen.dart:143`, `provider_type_step.dart:40`,
`platform_stats_screen.dart:120`, plus the Gemini system prompt at
`functions/index.js:2095`/`:2115` which says "customer". Keep `requestor` as the
storage/field name - that should not change. Sharpest case today: a user's own profile
says "Requestor" while their public profile says "Client".

### S10. Large text scale
**MED · M · `conversation_thread_screen.dart:91`, `bid_card.dart:77`, `job_detail_screen.dart:1177`, `milestone_section.dart:1199`, `form_widgets.dart:118`**

`toolbarHeight: 72` clips a two-line chat header at 2x scale. In `bid_card` the row is
`[Expanded(amount), Icon, Text(duration)]` with the duration unflexed, so the **bid
amount** is the first thing squeezed out. Drop the fixed toolbar height, wrap trailing
`Text` in `Flexible` with ellipsis, convert `_MicroProgress` to a `Wrap`. Add a widget
test at `TextScaler.linear(2.0)`.

### S11. Escrow tracker motion
**MED · M · `milestone_section.dart:65`, `:737` vs `:774`, `:1180`**

The app has exactly one animation. Expanding a milestone swaps a 20dp line for a ~250dp
card in a single frame. `AnimatedSize`/`AnimatedCrossFade` at ~200ms, `AnimatedSwitcher`
on `_StepCircle`. **Requires S12 first.**

### S12. Reduced motion helper
**S · do before S5 and S11**

Nothing in `lib/` consults `MediaQuery.disableAnimations`. Add to `core/util`:
`Duration motion(BuildContext c, Duration d) => MediaQuery.disableAnimationsOf(c) ? Duration.zero : d;`
and route every duration through it, starting with `job_detail_screen.dart:232` and
`app_widgets.dart:291`.

### S13. Bottom-bar "Fund RM 300" only scrolls
**MED · M · `job_detail_screen.dart:248`, labels at `:1527`-`:1578`**

Five money-denominated labels all map to `_scrollTo(...)`. Funding actually takes 4 taps.
Either relabel honestly, or wire the bar to invoke `MilestoneSection`'s existing
`_fund`/`_release` after scrolling.

### S14. Optimistic UI - two safe candidates only
**MED · S-M**

- **Bookmark** (`auth_controller.dart:155`): currently awaits the write *and* a full
  `refreshUser()` document re-read before `notifyListeners()`, so the icon lags 0.5-2s
  and the notify then cascades into S1. Flip an in-memory `Set<String>` synchronously,
  drop `refreshUser()`, revert on error.
- **Chat send** (`conversation_thread_screen.dart:47`): currently greys out the composer
  with the user's text still in it. Clear immediately, append a pending bubble, reconcile
  on snapshot.

**Not safe, do not attempt:** accept bid (three legitimate server failure modes), wallet
top-up/withdraw (server is sole arbiter by design). Milestone actions are already correct
- use them as the template.

### S15. Chat pagination
**MED · M · `chat_repository.dart:125`**

`.limit(50)` is right for a live listener, but the reversed `ListView.builder` has no
"load older" trigger, so message 51+ is permanently unreachable - usually where scope and
price were agreed. Same cursor pattern as `user_reviews_screen.dart:65-93`.

### S16. Shared-widget consolidation
**MED · M**

`location_field.dart:25` is duplicated at `post_job_screen.dart:499` and `:548` (the doc
comments admit the copy). The sticky bottom bar appears 5 times. `AppCard` is hand-rolled
at `job_detail_screen.dart:1364` and `notifications_screen.dart:122`;
`earnings_screen.dart:253` duplicates `StatCard`. Extract `TappableFieldRow` and
`BottomActionBar`, give `AppCard` a `color` param. Combines well with S2.

### S17. Smaller items
**LOW · S each**

- `PillBadge` contrast is still marginal after Stage 1's token work: `warningText` on the
  10% tint is 3.31:1, `danger` 4.28:1. Drop the tint to 6-8% *and* darken the accents, or
  set the label to `onSurface` and keep the accent for the icon (`app_widgets.dart:220`).
- Two brand blues side by side: `brandBlue #0052FF` (filled/outlined buttons, app bar)
  vs `colorScheme.primary #003EC7` (TextButton, IconButton.filled, cursors). Visible as
  "Cancel" vs "Accept Bid" in the same dialog. Pick one (`app_theme.dart:82` vs `:87`).
- Filter chips effectively invisible: inactive outline 1.62:1, and the *active* fill
  differs from the background by 1.04:1 (`job_feed_screen.dart:285`).
- Tap targets under 48dp: dispute-evidence remove x is ~18dp with no `Semantics`
  (`raise_dispute_sheet.dart:246`) while `post_job_screen.dart:790` does the identical
  affordance correctly - copy it. "Something wrong?" is 32dp
  (`milestone_section.dart:904`).
- Icon-only controls unlabelled: the password toggle in **every** `AppTextField`
  (`form_widgets.dart:83`), the five star buttons (`leave_review_sheet.dart:167`), and
  `StarRow` (`review_card.dart:104`) - a review's rating is entirely absent from the
  accessibility tree.
- "Something wrong?" opens a dispute that freezes escrowed money with no confirmation,
  while withdrawing a bid gets a full dialog. Relabel and state the consequence
  (`milestone_section.dart:913`).
- "Escrow" is used with no first-use explanation; the one good plain-language sentence
  (`milestone_section.dart:1354`) appears only after the user has met the word three
  times. Reuse it in `payout_step.dart:83` and the bid sheet.
- Video preview spins forever on failure - `hasError` never checked
  (`job_video_player.dart:55`).
- ~~Saved Jobs silently truncates at 30~~ - FIXED. `watchSavedJobs` now chunks the
  watchlist via the pure `chunkForWhereIn` helper and combines a stream per chunk,
  sorted newest-first. Deliberately *not* solved by moving the watchlist to a
  subcollection: `AppUser.isSaved` runs on every card in the feed and is free today
  because the array rides along with the profile document the app already streams;
  a subcollection would turn that into N reads on the most-viewed screen.
- Location placeholder says "e.g. Bangsar, Kuala Lumpur" in a Penang-only app
  (`post_job_screen.dart:386`).
- Admin verification docs vanish silently on error - `[...?snap.data]` null-spreads the
  error away, so an admin could approve someone believing they saw all documents
  (`verification_detail_screen.dart:117`).
- `outlineVariant` at 1.71:1 carries the "upcoming" milestone state, which has no glyph
  (`milestone_section.dart:1098`). Use `colorScheme.outline` (4.26:1).
- Restore `DESIGN.md` or rewrite the six comments that cite it - it does not exist
  (`app_theme.dart:6`/`:78`/`:153`, `app_widgets.dart:158`/`:309`, `bid_card.dart:22`).

---

## Open decision for the owner

**`topUpWallet` is callable by any authenticated user and credits real balance with no
payment** (`functions/index.js:766`). Only per-call and cumulative caps apply. Stage 1
gated the *client* button behind `PlatformConfig.demoTopUpEnabled` (= `kDebugMode`), but
the callable itself is unchanged, so the hole is reachable by anyone who can call the
function directly.

This was left alone deliberately: closing it is a backend authorization change on a money
path, it affects whatever you currently rely on for testing, and it takes effect on your
next deploy. Options:

- **Emulator-only:** `if (process.env.FUNCTIONS_EMULATOR !== 'true') throw ...` - works
  in dev, closed in production. Note this diverges from the client gate, which is
  `kDebugMode`: a debug build against the real project would show the button but get a
  server refusal.
- **Admin-only:** require an admin custom claim.
- **Remove it** and rely solely on the toyyibPay path (`createTopUpBill` /
  `reconcileTopUp`).

Recommend emulator-only, and change `demoTopUpEnabled` to match so client and server
agree.
