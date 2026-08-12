/**
 * ESLint flat config for the Cloud Functions.
 *
 * This code moves real money (escrow locks, top-ups, dispute payouts) in a
 * language that stays silent about typos: a misspelled field name reads as
 * `undefined` rather than failing, so `data().walletBalanceSpen || 0` would
 * quietly treat a funded wallet as empty. The Dart side has `flutter analyze`
 * for exactly this; this file is its counterpart.
 *
 * Deliberately weighted toward correctness rather than style. The formatting
 * already follows Google style by hand, and ESLint 10 has removed its own
 * stylistic rules, so enforcing layout here would mean adopting a separate
 * formatter for no real gain.
 */

const js = require("@eslint/js");
const globals = require("globals");

module.exports = [
  {
    ignores: ["node_modules/**", "eslint.config.js"],
  },

  js.configs.recommended,

  {
    files: ["**/*.js"],

    languageOptions: {
      ecmaVersion: 2023,
      // functions/package.json declares no "type", so these are CommonJS.
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },

    rules: {
      // --- Correctness -----------------------------------------------------

      // `catch (_)` is this codebase's deliberate "the reason does not matter,
      // fall back" idiom, matching the Dart side. Everything else unused is
      // still an error, since an unused variable usually means a rename or a
      // deletion only got half-applied.
      "no-unused-vars": ["error", {
        caughtErrorsIgnorePattern: "^_",
        argsIgnorePattern: "^_",
        varsIgnorePattern: "^_",
      }],

      // `==` coerces types, so `0 == "0"` is true. Dangerous around sen
      // amounts and status strings. "smart" still permits `x == null`, the
      // common and intentional null-or-undefined check.
      "eqeqeq": ["error", "smart"],

      // Throwing a bare string loses the stack trace, and Firebase expects
      // an HttpsError instance to map the error back to the client properly.
      "no-throw-literal": "error",

      // An `async` function with no `await` is usually a leftover or a
      // forgotten await, and it silently changes the return type to a
      // Promise for every caller.
      "require-await": "error",

      // Catches `if (x = 1)` where `==` was meant.
      "no-cond-assign": ["error", "always"],

      // Reassigning a parameter makes the original argument unrecoverable
      // and is a common source of confusion in long handlers.
      "no-param-reassign": "error",

      // A function that returns a value on some paths and nothing on others
      // hands callers `undefined` where they expect data.
      "consistent-return": "error",

      // --- Async safety ----------------------------------------------------

      // Reading then writing a shared value across an `await` is the classic
      // lost-update race. This is exactly the shape of a wallet balance
      // read-modify-write, so it is worth hearing about.
      "require-atomic-updates": "error",

      // --- Modern JS -------------------------------------------------------

      "no-var": "error",
      "prefer-const": "error",
    },
  },
];
