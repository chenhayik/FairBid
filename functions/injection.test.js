// NoSQL injection tests for docId(), the check every callable runs on a
// document id sent by the app. Run with: node --test injection.test.js
const assert = require("node:assert");
const test = require("node:test");
const admin = require("firebase-admin");
const {docId} = require("./common");

const rejected = (value) => assert.throws(() => docId(value, "jobId"),
    (err) => err.code === "invalid-argument");

test("docId: rejects MongoDB-style operator objects", () => {
  rejected({$ne: null});
  rejected({$gt: ""});
  rejected(["job1", "job2"]);
  rejected(42);
});

test("docId: rejects an id with a path that points at another document", () => {
  // Without the check, Firestore would treat the slashes as a path.
  if (!admin.apps.length) admin.initializeApp({projectId: "fairbid-test"});
  const ref = admin.firestore().collection("jobs").doc("job1/bids/provider1");
  assert.strictEqual(ref.path, "jobs/job1/bids/provider1");
  rejected("job1/bids/provider1");
  rejected("../users/admin1");
});

test("docId: rejects empty, blank and over-long ids", () => {
  rejected("");
  rejected("   ");
  rejected(undefined);
  rejected("a".repeat(1501));
});

test("docId: accepts an ordinary document id", () => {
  assert.strictEqual(docId("Xk2p9QeL0aB7", "jobId"), "Xk2p9QeL0aB7");
});
