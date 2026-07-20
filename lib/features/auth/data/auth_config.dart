/// One-time configuration values for authentication.
///
/// [googleServerClientId] is the **Web** OAuth client ID from
/// `google-services.json` (the `oauth_client` entry whose `client_type` is 3).
/// google_sign_in 7.x requires it on Android to return an ID token that
/// Firebase will accept.
///
/// It can be overridden at build time without editing this file:
///   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
const String googleServerClientId = String.fromEnvironment(
  // First arg is the --dart-define NAME to look up; the real ID is the default.
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue:
      '203512303560-97vcsraib4kebej5fbcdh37oplc5rrh1.apps.googleusercontent.com',
);

/// Whether a real value has been provided yet. When false, the Google button
/// shows a friendly "not configured" message instead of crashing.
bool get isGoogleSignInConfigured =>
    !googleServerClientId.startsWith('TODO_');
