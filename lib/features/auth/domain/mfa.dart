/// A second factor the user has enrolled (currently always an authenticator
/// app). [uid] is the stable id used to build a sign-in assertion.
class MfaFactor {
  const MfaFactor({
    required this.uid,
    required this.displayName,
    this.enrolledAt,
  });

  final String uid;
  final String displayName;
  final DateTime? enrolledAt;
}

/// A TOTP secret mid-enrolment: what to show the user, plus an opaque
/// [handle] holding Firebase's secret object, passed back to complete it.
///
/// Not persistable - the handle only lives in memory, so enrolment must
/// finish in one session (see the security screen).
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

/// A sign-in or re-auth blocked pending a second factor. [resolver] is
/// Firebase's resolver, opaque to the UI; reuse the same challenge across
/// retries rather than restarting sign-in.
class MfaChallenge {
  const MfaChallenge({required this.hints, required this.resolver});

  final List<MfaFactor> hints;
  final Object resolver;
}

/// Thrown instead of an [AuthException] when a sign-in or re-auth needs a
/// second factor. Carries the [challenge] the UI must resolve.
class MfaRequiredException implements Exception {
  const MfaRequiredException(this.challenge);
  final MfaChallenge challenge;
}
