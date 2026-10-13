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
npx firebase-tools emulators:exec --only firestore,storage "npm test"
```

`emulators:exec` reads `../firebase.json` for the emulator config (Firestore
on port 8080) and sets `FIRESTORE_EMULATOR_HOST` for the test process, which
`initializeTestEnvironment()` picks up automatically.

To iterate faster, leave the emulators running in one terminal (`npx
firebase-tools emulators:start --only firestore,storage`, from the repo root
or here) and re-run `npm test` in another with `FIRESTORE_EMULATOR_HOST=127.0.0.1:8080`
and `FIREBASE_STORAGE_EMULATOR_HOST=127.0.0.1:9199` set.

## What's covered

`rules.test.js` (Firestore) and `storage.rules.test.js` (Storage): one `describe` per collection or path, each case proving a single allow or deny.

## Notes

- Each test seeds its own prerequisite documents (job status, provider
  trust snapshot, participant lists, etc.) with
  `testEnv.withSecurityRulesDisabled(...)`, then asserts the actual write
  under test with `assertFails`/`assertSucceeds`.
- `afterEach` calls `testEnv.clearFirestore()` so tests don't leak state
  into each other.
- This suite only reads the rules files and asserts against them; it never
  edits them.
