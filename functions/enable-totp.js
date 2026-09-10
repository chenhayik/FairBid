/**
 * One-off setup script: turns on TOTP (authenticator-app) multi-factor
 * authentication for this Firebase project.
 *
 * TOTP has no toggle in the Firebase Console - it can only be switched on
 * through the Admin SDK or the Identity Toolkit REST API. The project must
 * already be upgraded to Identity Platform, or the update is rejected.
 *
 * Usage, from the functions/ directory:
 *   node enable-totp.js --check <service-account.json>   # read config only
 *   node enable-totp.js <service-account.json>           # enable TOTP
 *
 * Keep the service-account key OUTSIDE this repository - it is a full-admin
 * credential and *.json is not gitignored here. Delete it when you are done.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const {initializeApp, cert} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");

const args = process.argv.slice(2);
const checkOnly = args.includes("--check");
const keyPath = args.find((arg) => arg !== "--check");

if (!keyPath) {
  console.error(
      "Usage: node enable-totp.js [--check] <path-to-service-account.json>");
  process.exit(1);
}

// PowerShell passes a leading "~" through literally, so expand it here.
const expanded = keyPath.startsWith("~") ?
  path.join(os.homedir(), keyPath.slice(1)) :
  keyPath;
const key = JSON.parse(
    fs.readFileSync(path.resolve(process.cwd(), expanded), "utf8"));

// Printed so a key for the wrong project is obvious before anything changes.
console.log("Project:", key.project_id);

initializeApp({credential: cert(key)});
const manager = getAuth().projectConfigManager();

const main = async () => {
  const before = await manager.getProjectConfig();
  console.log("Current MFA config:",
      JSON.stringify(before.multiFactorConfig ?? null, null, 2));

  if (checkOnly) return;

  const after = await manager.updateProjectConfig({
    multiFactorConfig: {
      state: "ENABLED",
      // factorIds is deliberately omitted - that field enables SMS, which
      // costs $0.24 per message to Malaysian numbers. TOTP sends nothing.
      providerConfigs: [
        {state: "ENABLED", totpProviderConfig: {adjacentIntervals: 5}},
      ],
    },
  });
  console.log("TOTP enabled. New MFA config:",
      JSON.stringify(after.multiFactorConfig, null, 2));
};

main().catch((error) => {
  console.error("Failed:", error.message);
  process.exit(1);
});
