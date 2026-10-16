// Appointment scheduling: after an award, both sides agree a visit time
// (proposeAppointment / respondToAppointment / withdrawAppointmentProposal),
// then the provider reports markOnTheWay / markArrived on the day.
// The validation helpers are pure so `npm test` covers them without Firebase.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {
  callerUid, bad, docId, jobRole, counterpartyUid, notifyUser, logJobEvent,
} = require("./common");

const MIN_LEAD_MS = 30 * 60 * 1000;
const MAX_AHEAD_MS = 90 * 24 * 60 * 60 * 1000;
const LATE_WINDOW_MS = 24 * 60 * 60 * 1000;
const SOON_MS = 2 * 60 * 60 * 1000;
const VISIT_DAY_MS = 3 * 60 * 60 * 1000;
const ETA_MINUTES = [15, 30, 45, 60];
const MAX_OPTIONS = 3;
const MAX_ALSO = 10;
const MAX_NOTE_LEN = 300;

/**
 * What:   Epoch-millisecond check.
 * Input:  Any [value].
 * Output: True for a positive integer.
 */
const isMs = (value) => Number.isInteger(value) && value > 0;

/**
 * What:   Validator for a visit proposal.
 * Input:  [job] doc data, [options] and [endAt] (epoch ms), [note], [nowMs].
 * Output: An error message, or null when valid.
 * How:    Job in progress with no cancellation request; 1-3 unique options
 *         30 min to 90 days ahead; endAt after the last option within 90 days.
 */
function validateProposal({job, options, endAt, note, nowMs}) {
  if (job?.status !== "in_progress") return "This job is not in progress.";
  if (job.cancellationRequestedBy) {
    return "Resolve the pending cancellation request first.";
  }
  if (!Array.isArray(options) || options.length < 1 ||
      options.length > MAX_OPTIONS || !options.every(isMs)) {
    return `Pick 1 to ${MAX_OPTIONS} times.`;
  }
  if (new Set(options).size !== options.length) {
    return "Each time must be different.";
  }
  if (options.some((ms) => ms < nowMs + MIN_LEAD_MS)) {
    return "Each time must be at least 30 minutes from now.";
  }
  if (options.some((ms) => ms > nowMs + MAX_AHEAD_MS)) {
    return "Each time must be within the next 90 days.";
  }
  if (endAt != null) {
    const latest = Math.max(...options);
    if (!isMs(endAt) || endAt <= latest) {
      return "The finish time must be after the last visit time.";
    }
    if (endAt > latest + MAX_AHEAD_MS) {
      return "The finish time must be within 90 days of the visit.";
    }
  }
  if (note != null && (typeof note !== "string" ||
      note.length > MAX_NOTE_LEN)) {
    return `The note can be up to ${MAX_NOTE_LEN} characters.`;
  }
  return null;
}

/**
 * What:   Late-reschedule check.
 * Input:  Confirmed start (epoch ms or null) and [nowMs].
 * Output: True when a confirmed visit starts in under 24 hours.
 */
function isLateReschedule(appointmentStartMs, nowMs) {
  return appointmentStartMs != null &&
      appointmentStartMs - nowMs < LATE_WINDOW_MS;
}

/**
 * What:   Reminder picker for a confirmed visit.
 * Input:  The job's `appointment` (startAt Timestamp, reminder flags), [nowMs].
 * Output: "2h", "24h", or null when nothing is due.
 * Notes:  The 2h reminder also covers the 24h one, so it never fires late.
 */
function reminderDue(appointment, nowMs) {
  const left = appointment.startAt.toMillis() - nowMs;
  if (left <= 0) return null;
  if (left <= SOON_MS) return appointment.reminded2h ? null : "2h";
  if (left <= LATE_WINDOW_MS) return appointment.reminded24h ? null : "24h";
  return null;
}

/**
 * What:   Visit time label for the timeline and notifications.
 * Input:  Epoch ms.
 * Output: e.g. `Mon 12 Oct, 10:00 am` in Asia/Kuala_Lumpur time.
 */
function formatVisit(ms) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Kuala_Lumpur", weekday: "short", day: "numeric",
    month: "short", hour: "numeric", minute: "2-digit", hour12: true,
  }).formatToParts(ms).map((p) => [p.type, p.value]));
  return `${parts.weekday} ${parts.day} ${parts.month}, ${parts.hour}:` +
      `${parts.minute} ${parts.dayPeriod.toLowerCase()}`;
}

/**
 * What:   Validator for the visit-day actions (on my way, arrived).
 * Input:  [job] doc data and [nowMs].
 * Output: An error message, or null when valid.
 * How:    Job in progress, confirmed visit starting within 3 hours (or past),
 *         not yet arrived. Matches the card's button window.
 */
function validateVisitDay(job, nowMs) {
  if (job?.status !== "in_progress") return "This job is not in progress.";
  if (!job.appointment) return "Agree a visit time first.";
  if (job.appointment.startAt.toMillis() - nowMs > VISIT_DAY_MS) {
    return "You can do this from 3 hours before the visit.";
  }
  if (job.arrivedAt) return "You already marked yourself as arrived.";
  return null;
}

/** What: ETA check. Input: minutes. Output: true for 15/30/45/60. */
const isAllowedEta = (minutes) => ETA_MINUTES.includes(minutes);

/** What: Copy label. Input: caller role. Output: "The client"/"The provider". */
const roleLabel = (role) => role === "requestor" ? "The client" : "The provider";

/**
 * What:   Error builder for a caller who may not do this.
 * Input:  A readable [message].
 * Output: A `permission-denied` HttpsError to throw.
 */
const denied = (message) =>
  new functions.https.HttpsError("permission-denied", message);
/**
 * What:   Error builder for a job in the wrong state.
 * Input:  A readable [message].
 * Output: A `failed-precondition` HttpsError to throw.
 */
const precondition = (message) =>
  new functions.https.HttpsError("failed-precondition", message);

/**
 * What:   Job reader for the scheduling callables.
 * Input:  [tx], the [jobRef] and the caller [uid].
 * Output: `{job, role}`; throws `permission-denied` unless the caller is the
 *         job's requestor or accepted provider.
 */
async function readJob(tx, jobRef, uid) {
  const job = (await tx.get(jobRef)).data();
  const role = jobRole(job, uid);
  if (!role) throw denied("Only the job's participants can schedule a visit.");
  return {job, role};
}

/**
 * What:   Group check for a task that shares a visit proposal.
 * Input:  [main] job data, [sibling] job data (or undefined), and the
 *         validateProposal() arguments in [args].
 * Output: An error message, or null when [sibling] can take the same proposal.
 * How:    Same bundle, requestor and provider as [main], scheduling needed,
 *         then validateProposal() on the sibling.
 */
function validateSibling(main, sibling, args) {
  if (!main.bundleId || sibling?.bundleId !== main.bundleId ||
      sibling.requestorId !== main.requestorId ||
      sibling.acceptedProviderId !== main.acceptedProviderId ||
      !sibling.schedulingRequired) {
    return "Those tasks are not from the same bundle and provider.";
  }
  return validateProposal({job: sibling, ...args});
}

/**
 * What:   Same-proposal check used when a group is confirmed or withdrawn.
 * Input:  Two `appointmentProposal` maps (`by` uid, `at` Timestamp).
 * Output: True when both came from the same propose call.
 */
const sameProposal = (a, b) =>
  a?.by === b?.by && a?.at?.toMillis() === b?.at?.toMillis();

/**
 * What:   Reader for the other tasks that share [proposal].
 * Input:  [tx], [jobId] (the task being answered), its [proposal], caller [uid].
 * Output: [{ref, job}] for each group task still holding the same proposal.
 * Notes:  Reads only; the caller writes after. Skips tasks that are not
 *         in progress or not the caller's.
 */
async function readGroup(tx, jobId, proposal, uid) {
  const db = admin.firestore();
  const ids = (proposal.groupJobIds ?? []).filter((id) => id !== jobId);
  const snaps = await Promise.all(
      ids.map((id) => tx.get(db.doc(`jobs/${id}`))));
  return snaps
      .filter((snap) => snap.exists)
      .map((snap) => ({ref: snap.ref, job: snap.data()}))
      .filter(({job}) => job.status === "in_progress" && jobRole(job, uid) &&
          sameProposal(job.appointmentProposal, proposal));
}

/** What: Copy suffix. Input: sibling count. Output: " and N other tasks" or "". */
const alsoTasks = (count) => count === 0 ? "" :
  ` and ${count} other task${count > 1 ? "s" : ""}`;

/**
 * What:   Callable that proposes 1-3 visit times.
 * Input:  {jobId, options: [ms], endAt?: ms, note?, alsoJobIds?: [jobId]} from
 *         JobRepository.proposeAppointment().
 * Output: Replaces any pending proposal; notifies the other party once and logs
 *         a timeline event per task. A late change is recorded in lateRescheduleBy.
 * How:    [alsoJobIds] (max 10) are same-bundle, same-provider tasks that get the
 *         same proposal, each carrying `groupJobIds` so one answer covers all.
 */
exports.proposeAppointment = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data?.jobId, "Job");
  const options = data.options;
  const endAt = data.endAt ?? null;
  const note = typeof data.note === "string" && data.note.trim() !== "" ?
      data.note.trim() : null;
  const also = data.alsoJobIds ?? [];
  if (!Array.isArray(also) || also.length > MAX_ALSO) {
    throw bad(`You can add up to ${MAX_ALSO} other tasks.`);
  }
  const alsoIds = [...new Set(also.map((id) => docId(id, "Job")))]
      .filter((id) => id !== jobId);
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);

  await db.runTransaction(async (tx) => {
    const {job, role} = await readJob(tx, jobRef, uid);
    const siblings = await Promise.all(
        alsoIds.map((id) => tx.get(db.doc(`jobs/${id}`))));
    const args = {options, endAt, note, nowMs: Date.now()};
    const problem = validateProposal({job, ...args}) ||
        siblings.map((s) => validateSibling(job, s.data(), args))
            .find(Boolean);
    if (problem) throw bad(problem);

    const at = Timestamp.now();
    const isLate = (j) =>
      isLateReschedule(j.appointment?.startAt?.toMillis() ?? null, args.nowMs);
    const times = options.map(formatVisit).join(" or ");
    const group = [{ref: jobRef, job},
      ...siblings.map((s) => ({ref: s.ref, job: s.data()}))];
    for (const {ref, job: j} of group) {
      tx.update(ref, {
        appointmentProposal: {
          options: options.map((ms) => Timestamp.fromMillis(ms)),
          endAt: endAt == null ? null : Timestamp.fromMillis(endAt),
          by: uid,
          at,
          note,
          late: isLate(j),
          ...(alsoIds.length ? {groupJobIds: group.map((g) => g.ref.id)} : {}),
        },
        ...(isLate(j) ? {lateRescheduleBy: FieldValue.arrayUnion(uid)} : {}),
      });
      logJobEvent(ref.id, null, "appointment_proposed",
          `${roleLabel(role)} proposed a visit time`, tx);
    }
    notifyUser(tx, counterpartyUid(job, role), {
      type: "appointment",
      title: isLate(job) ? "Visit change at short notice" :
        "Visit time proposed",
      body: `${roleLabel(role)} suggested ${times} for "${job.title}"` +
          `${alsoTasks(alsoIds.length)}.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * What:   Update that confirms [startAt] on one job.
 * Input:  [job] data, its [proposal], the confirmed [startAt] Timestamp, [uid].
 * Output: A Firestore update map: sets `appointment`, deletes the proposal and,
 *         on a reschedule, bumps appointmentChanges and clears the visit-day marks.
 */
function confirmUpdate(job, proposal, startAt, uid) {
  return {
    appointment: {
      startAt,
      endAt: proposal.endAt ?? null,
      confirmedAt: FieldValue.serverTimestamp(),
      confirmedBy: uid,
      // Confirmed inside 24h: skip straight to the 2h reminder.
      reminded24h: isLateReschedule(startAt.toMillis(), Date.now()),
    },
    appointmentProposal: FieldValue.delete(),
    ...(job.appointment != null ? {
      appointmentChanges: FieldValue.increment(1),
      onTheWayAt: FieldValue.delete(),
      etaMinutes: FieldValue.delete(),
      arrivedAt: FieldValue.delete(),
    } : {}),
  };
}

/**
 * What:   Callable for the non-proposing party to confirm one proposed time.
 * Input:  {jobId, optionIndex} from JobRepository.respondToAppointment().
 * Output: Sets `appointment` (bumps appointmentChanges on a reschedule),
 *         deletes the proposal and notifies the proposer once.
 * How:    A proposal with `groupJobIds` confirms every task in the group that
 *         still holds the same proposal, in the one transaction.
 */
exports.respondToAppointment = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data?.jobId, "Job");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);

  await db.runTransaction(async (tx) => {
    const {job, role} = await readJob(tx, jobRef, uid);
    const proposal = job.appointmentProposal;
    if (job.status !== "in_progress" || !proposal) {
      throw precondition("There is no visit time to answer.");
    }
    if (proposal.by === uid) {
      throw precondition(
          "You proposed this; the other party must respond.");
    }
    const proposerUid = counterpartyUid(job, role);

    const index = data.optionIndex;
    if (!Number.isInteger(index) || index < 0 ||
        index >= proposal.options.length) {
      throw bad("Pick one of the proposed times.");
    }
    const startAt = proposal.options[index];
    if (startAt.toMillis() < Date.now()) {
      throw precondition("That time has passed. Ask for new times.");
    }
    const siblings = await readGroup(tx, jobId, proposal, uid);
    const when = formatVisit(startAt.toMillis());
    const label = (j) => j.appointment != null ? "Visit rescheduled" :
      "Visit confirmed";
    for (const {ref, job: j} of [{ref: jobRef, job}, ...siblings]) {
      tx.update(ref, confirmUpdate(j, proposal, startAt, uid));
      logJobEvent(ref.id, null, "appointment_confirmed",
          `${label(j)}: ${when}`, tx);
    }
    notifyUser(tx, proposerUid, {
      type: "appointment",
      title: label(job),
      body: `${roleLabel(role)} confirmed ${when} for "${job.title}"` +
          `${alsoTasks(siblings.length)}.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * What:   Callable for the proposer to take back their proposal.
 * Input:  {jobId} from JobRepository.withdrawAppointmentProposal().
 * Output: Deletes the proposal (and its group's), notifies the other party
 *         once, logs an event per task.
 */
exports.withdrawAppointmentProposal =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = docId(data?.jobId, "Job");
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);

    await db.runTransaction(async (tx) => {
      const {job, role} = await readJob(tx, jobRef, uid);
      const proposal = job.appointmentProposal;
      if (!proposal) throw precondition("There is no visit time to withdraw.");
      if (proposal.by !== uid) {
        throw denied("Only the party that proposed can withdraw it.");
      }
      const siblings = await readGroup(tx, jobId, proposal, uid);
      for (const {ref} of [{ref: jobRef}, ...siblings]) {
        tx.update(ref, {appointmentProposal: FieldValue.delete()});
        logJobEvent(ref.id, null, "appointment_withdrawn",
            "Visit time proposal withdrawn", tx);
      }
      notifyUser(tx, counterpartyUid(job, role), {
        type: "appointment",
        title: "Visit proposal withdrawn",
        body: `${roleLabel(role)} withdrew the suggested times for ` +
            `"${job.title}"${alsoTasks(siblings.length)}.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * What:   Shared transaction for the provider's visit-day callables.
 * Input:  Callable [data]/[context]; [fields] job update, [notice] title and
 *         body(name, job), [event] type and title(name).
 * Output: Updates the job, notifies the requestor and logs a timeline event.
 * Notes:  Throws unless the caller is the accepted provider.
 */
async function visitDayAction(data, context, {fields, notice, event}) {
  const uid = callerUid(context);
  const jobId = docId(data?.jobId, "Job");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);

  await db.runTransaction(async (tx) => {
    const {job, role} = await readJob(tx, jobRef, uid);
    if (role !== "provider") throw denied("Only the provider can do this.");
    const problem = validateVisitDay(job, Date.now());
    if (problem) throw precondition(problem);
    tx.update(jobRef, fields);
    const name = job.acceptedProviderName || "The provider";
    notifyUser(tx, job.requestorId, {
      type: "appointment",
      title: notice.title,
      body: notice.body(name, job),
      route: `/jobs/${jobId}`,
    });
    logJobEvent(jobId, null, event.type, event.title(name), tx);
  });
}

/**
 * What:   Callable for the provider to say they are heading to the visit.
 * Input:  {jobId, etaMinutes: 15|30|45|60} from JobRepository.markOnTheWay().
 * Output: Sets onTheWayAt and etaMinutes (callable again to update the ETA),
 *         notifies the requestor and logs a timeline event.
 */
exports.markOnTheWay = functions.https.onCall(async (data, context) => {
  const eta = data?.etaMinutes;
  if (!isAllowedEta(eta)) throw bad("Pick 15, 30, 45 or 60 minutes.");
  await visitDayAction(data, context, {
    fields: {onTheWayAt: FieldValue.serverTimestamp(), etaMinutes: eta},
    notice: {
      title: "Provider on the way",
      body: (name, job) =>
        `${name} is on the way, about ${eta} min, for "${job.title}".`,
    },
    event: {
      type: "on_the_way",
      title: (name) => `${name} is on the way (about ${eta} min)`,
    },
  });
});

/**
 * What:   Callable for the provider to say they have arrived at the visit.
 * Input:  {jobId} from JobRepository.markArrived().
 * Output: Sets arrivedAt once, notifies the requestor and logs an event.
 */
exports.markArrived = functions.https.onCall((data, context) =>
  visitDayAction(data, context, {
    fields: {arrivedAt: FieldValue.serverTimestamp()},
    notice: {
      title: "Provider arrived",
      body: (name, job) => `${name} has arrived for "${job.title}".`,
    },
    event: {type: "arrived", title: (name) => `${name} arrived`},
  }));

/**
 * What:   Scheduled sweep that sends visit reminders 24h and 2h before.
 * Input:  Jobs whose appointment.startAt is in the next 24h (single-field query).
 * Output: A notification to both parties and the reminder flag set, once each.
 * Notes:  One batch (3 writes per visit), so about 160 visits per sweep max.
 */
exports.sendVisitReminders = functions.pubsub
    .schedule("every 15 minutes")
    .onRun(async () => {
      const now = Date.now();
      const db = admin.firestore();
      const snap = await db.collection("jobs")
          .where("appointment.startAt", ">", Timestamp.fromMillis(now))
          .where("appointment.startAt", "<=",
              Timestamp.fromMillis(now + LATE_WINDOW_MS))
          .get();
      const batch = db.batch();
      let sent = 0;
      for (const doc of snap.docs) {
        const job = doc.data();
        const due = job.status === "in_progress" ?
            reminderDue(job.appointment, now) : null;
        if (!due) continue;
        batch.update(doc.ref, due === "2h" ?
            {"appointment.reminded24h": true, "appointment.reminded2h": true} :
            {"appointment.reminded24h": true});
        const when = formatVisit(job.appointment.startAt.toMillis());
        for (const uid of [job.requestorId, job.acceptedProviderId]) {
          notifyUser(batch, uid, {
            type: "appointment",
            title: due === "2h" ? "Visit in 2 hours" : "Visit tomorrow",
            body: `"${job.title}" is booked for ${when}.`,
            route: `/jobs/${doc.id}`,
          });
        }
        sent++;
      }
      if (sent > 0) await batch.commit();
      functions.logger.info(`sendVisitReminders: ${sent} visit(s) reminded`);
    });

// Exported for tests; index.js re-exports the callables.
exports.reminderDue = reminderDue;
exports.validateProposal = validateProposal;
exports.validateVisitDay = validateVisitDay;
exports.validateSibling = validateSibling;
exports.sameProposal = sameProposal;
exports.isLateReschedule = isLateReschedule;
exports.formatVisit = formatVisit;
