/**
 * Security-rules test suite for `storage.rules`.
 *
 * Companion to `rules.test.js`, which covers Firestore. Until this file existed
 * `storage.rules` had no automated coverage at all - which mattered once the
 * `verification/` path gained a size cap and a content-type allowlist, because
 * a rule that is too strict silently breaks real uploads and a rule that is too
 * loose silently protects nothing.
 *
 * Run with both emulators (from this directory):
 *   npx firebase-tools emulators:exec --only firestore,storage "npm test"
 *
 * Storage needs Firestore alongside it because `isAdmin()` in storage.rules
 * cross-reads the user's Firestore document.
 *
 * Note on what these prove: `contentType` is client-supplied metadata that
 * Cloud Storage never verifies, so these tests pin the *guard*, not a security
 * boundary. The real file-type check is the magic-byte test in
 * `functions/ssm.js`.
 */

const fs = require("fs");
const path = require("path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {ref, uploadBytes, getBytes} = require("firebase/storage");

const RULES_PATH = path.resolve(__dirname, "../storage.rules");

const OWNER = "owner-uid";
const STRANGER = "stranger-uid";

/** A minimal but genuine PDF header, so the bytes match the declared type. */
const PDF_BYTES = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37]);
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0]);

describe("storage.rules", () => {
  /** @type {import("@firebase/rules-unit-testing").RulesTestEnvironment} */
  let testEnv;

  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "fairbid-storage-test",
      storage: {rules: fs.readFileSync(RULES_PATH, "utf8")},
    });
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  afterEach(async () => {
    await testEnv.clearStorage();
  });

  /** The signed-in owner's view of Storage. */
  const asOwner = () => testEnv.authenticatedContext(OWNER).storage();

  const verificationRef = (storage, name, uid = OWNER) =>
    ref(storage, `verification/${uid}/${name}`);

  describe("verification/ uploads", () => {
    it("accepts a PDF from the owner", async () => {
      await assertSucceeds(uploadBytes(
          verificationRef(asOwner(), "ssm_document_1.pdf"),
          PDF_BYTES,
          {contentType: "application/pdf"},
      ));
    });

    it("accepts an image from the owner", async () => {
      await assertSucceeds(uploadBytes(
          verificationRef(asOwner(), "id_document_1.jpg"),
          JPEG_BYTES,
          {contentType: "image/jpeg"},
      ));
    });

    it("rejects a content type that is neither image nor PDF", async () => {
      await assertFails(uploadBytes(
          verificationRef(asOwner(), "payload.html"),
          JPEG_BYTES,
          {contentType: "text/html"},
      ));
    });

    it("rejects an empty file", async () => {
      await assertFails(uploadBytes(
          verificationRef(asOwner(), "empty.pdf"),
          new Uint8Array([]),
          {contentType: "application/pdf"},
      ));
    });

    // Deliberately over the 10 MB cap rather than near it, so the test proves
    // the rule rather than a rounding boundary.
    it("rejects a file over the 10 MB cap", async function () {
      this.timeout(60000);
      const big = new Uint8Array(11 * 1024 * 1024);
      big.set(PDF_BYTES);
      await assertFails(uploadBytes(
          verificationRef(asOwner(), "huge.pdf"),
          big,
          {contentType: "application/pdf"},
      ));
    });

    it("rejects an upload into another user's folder", async () => {
      const storage = testEnv.authenticatedContext(STRANGER).storage();
      await assertFails(uploadBytes(
          verificationRef(storage, "ssm_document_1.pdf", OWNER),
          PDF_BYTES,
          {contentType: "application/pdf"},
      ));
    });

    it("rejects an unauthenticated upload", async () => {
      const storage = testEnv.unauthenticatedContext().storage();
      await assertFails(uploadBytes(
          verificationRef(storage, "ssm_document_1.pdf"),
          PDF_BYTES,
          {contentType: "application/pdf"},
      ));
    });
  });

  describe("verification/ reads", () => {
    it("lets the owner read their own document back", async () => {
      const storage = asOwner();
      const target = verificationRef(storage, "ssm_document_1.pdf");
      await uploadBytes(target, PDF_BYTES, {contentType: "application/pdf"});
      await assertSucceeds(getBytes(target));
    });

    // NOTE: the emulator logs a "Null value error" at storage.rules line 12
    // while this passes. That is isAdmin()'s `firestore.get(...)`, which the
    // storage rules runtime cannot resolve in this harness - cross-service
    // reads are not wired up by @firebase/rules-unit-testing, and seeding a
    // user document does not change it. The deny below is therefore correct
    // but reached by an evaluation error rather than a clean false, so these
    // tests prove the owner/stranger split and NOT that an admin can read.
    // Admin access to verification/ remains uncovered.
    it("denies another signed-in user", async () => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await uploadBytes(
            ref(context.storage(), `verification/${OWNER}/ssm_document_1.pdf`),
            PDF_BYTES,
            {contentType: "application/pdf"},
        );
      });
      const storage = testEnv.authenticatedContext(STRANGER).storage();
      await assertFails(
          getBytes(ref(storage, `verification/${OWNER}/ssm_document_1.pdf`)));
    });
  });

  // Site handover evidence (docs/BUNDLE_BIDDING.md phase 4):
  // `handovers/{jobId}/{fileName}`. Every check in that rule reads
  // `job().acceptedProviderId`/`requestorId` via `firestore.get(...)`, same
  // as `isAdmin()` above - and in this harness, an AUTHENTICATED request
  // through such a rule doesn't just evaluate to false, it hangs until the
  // mocha timeout (confirmed against the unmodified rules too, so it's an
  // emulator/harness limitation, not a bug in this rule). Only the
  // unauthenticated case - denied before `job()` is ever reached, by
  // short-circuiting on `request.auth != null` - resolves cleanly here.
  describe("handovers/ uploads", () => {
    it("rejects an unauthenticated upload", async () => {
      const storage = testEnv.unauthenticatedContext().storage();
      await assertFails(uploadBytes(
          ref(storage, "handovers/job1/photo.jpg"),
          JPEG_BYTES,
          {contentType: "image/jpeg"},
      ));
    });
  });
});
