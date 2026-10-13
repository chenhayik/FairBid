/// What:   An enrolled second factor (always an authenticator app).
/// Input:  Firebase MultiFactorInfo via FirebaseAuthRepository.enrolledFactors().
/// Output: [uid] used to build a sign-in assertion.
class MfaFactor {
  const MfaFactor({required this.uid});

  final String uid;
}

/// What:   A TOTP secret mid-enrolment.
/// Input:  FirebaseAuthRepository.startTotpEnrollment().
/// Output: Key and QR URL to show; the opaque [handle] is passed back to complete it.
/// Notes:  The handle lives in memory only, so enrolment must finish in one session.
class TotpEnrollment {
  const TotpEnrollment({
    required this.secretKey,
    required this.qrCodeUrl,
    required this.handle,
  });

  /// The base32 key, for users who type it in instead of scanning.
  final String secretKey;

  /// The `otpauth://` URL behind the QR code.
  final String qrCodeUrl;

  final Object handle;
}

/// What:   A sign-in or re-auth blocked pending a second factor.
/// Input:  Firebase's resolver, opaque to the UI.
/// Output: Reuse the same challenge across retries rather than restarting sign-in.
class MfaChallenge {
  const MfaChallenge({required this.resolver});

  final Object resolver;
}

/// What:   Thrown instead of [AuthException] when a second factor is needed.
/// Input:  Raised by FirebaseAuthRepository._guardValue.
/// Output: Carries the [challenge] the UI must resolve.
class MfaRequiredException implements Exception {
  const MfaRequiredException(this.challenge);
  final MfaChallenge challenge;
}
