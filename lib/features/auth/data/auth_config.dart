/// What:   Web OAuth client ID (`client_type` 3 in google-services.json) for Google sign-in.
/// Input:  `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`, else the default below.
/// Output: google_sign_in 7.x needs it on Android to return an ID token Firebase accepts.
const String googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue:
      '203512303560-97vcsraib4kebej5fbcdh37oplc5rrh1.apps.googleusercontent.com',
);
