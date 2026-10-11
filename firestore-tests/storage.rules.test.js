// Security-rules tests for `storage.rules` (companion to rules.test.js). Needs
// the Firestore emulator too, because `isAdmin()` cross-reads the user doc.
//
// `contentType` is client-supplied and never verified by Cloud Storage, so these
// pin the accident guard, not a security boundary. The real file-type check is
// the magic-byte test in `functions/ssm.js`.

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
const OVER_10_MB = new Uint8Array(11 * 1024 * 1024);
OVER_10_MB.set(PDF_BYTES);

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

  const asOwner = () => testEnv.authenticatedContext(OWNER).storage();

  const verificationRef = (storage, name, uid = OWNER) =>
    ref(storage, `verification/${uid}/${name}`);

  describe("verification/ uploads", () => {
    it("accepts a PDF from the owner", async () => {
      await assertSucceeds(uploadBytes(
          verificationRef(asOwner(), "ssm_document_1.pdf"),
          PDF_BYTES,
          {contentType: "application/pdf"}));
    });

    it("accepts an image from the owner", async () => {
      await assertSucceeds(uploadBytes(
          verificationRef(asOwner(), "id_document_1.jpg"),
          JPEG_BYTES,
          {contentType: "image/jpeg"}));
    });

    // [name, storage, file name, uid folder, bytes, content type]
    const rejected = [
      ["a content type that is neither image nor PDF", asOwner,
        "payload.html", OWNER, JPEG_BYTES, "text/html"],
      ["an empty file", asOwner,
        "empty.pdf", OWNER, new Uint8Array([]), "application/pdf"],
      ["a file over the 10 MB cap", asOwner,
        "huge.pdf", OWNER, OVER_10_MB, "application/pdf"],
      ["an upload into another user's folder",
        () => testEnv.authenticatedContext(STRANGER).storage(),
        "ssm_document_1.pdf", OWNER, PDF_BYTES, "application/pdf"],
      ["an unauthenticated upload",
        () => testEnv.unauthenticatedContext().storage(),
        "ssm_document_1.pdf", OWNER, PDF_BYTES, "application/pdf"],
    ];
    for (const [name, storage, file, uid, bytes, contentType] of rejected) {
      it(`rejects ${name}`, async function () {
        this.timeout(60000);
        await assertFails(uploadBytes(
            verificationRef(storage(), file, uid), bytes, {contentType}));
      });
    }
  });

  describe("verification/ reads", () => {
    it("lets the owner read their own document back", async () => {
      const storage = asOwner();
      const target = verificationRef(storage, "ssm_document_1.pdf");
      await uploadBytes(target, PDF_BYTES, {contentType: "application/pdf"});
      await assertSucceeds(getBytes(target));
    });

    // The emulator logs a "Null value error" at storage.rules line 12 while
    // this passes: isAdmin()'s `firestore.get(...)` can't be resolved in this
    // harness, so the deny is reached by an evaluation error, not a clean
    // false. These prove the owner/stranger split, NOT that an admin can read.
    it("denies another signed-in user", async () => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await uploadBytes(
            ref(context.storage(), `verification/${OWNER}/ssm_document_1.pdf`),
            PDF_BYTES,
            {contentType: "application/pdf"});
      });
      const storage = testEnv.authenticatedContext(STRANGER).storage();
      await assertFails(
          getBytes(ref(storage, `verification/${OWNER}/ssm_document_1.pdf`)));
    });
  });
});
