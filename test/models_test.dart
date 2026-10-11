import 'package:fairbid/core/location/geo.dart';
import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/util/money.dart';
import 'package:fairbid/core/util/ssm_number.dart';
import 'package:fairbid/features/auth/domain/app_user.dart';
import 'package:fairbid/features/auth/domain/user_role.dart';
import 'package:fairbid/features/profile/domain/public_profile.dart';
import 'package:fairbid/features/profile/domain/review.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';


void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('SSM number', () {
    test('decodes the current 12-digit format', () {
      final ssm = SsmNumber.parse('201903350205')!;
      expect(ssm.format, SsmNumberFormat.current);
      expect(ssm.year, 2019);
      expect(ssm.entityType, SsmEntityType.business);
      expect(ssm.normalized, '201903350205');
    });

    test('accepts the combined form printed on certificates', () {
      final ssm = SsmNumber.parse('201903350205 (003058656-T)')!;
      expect(ssm.normalized, '201903350205');
      expect(ssm.legacyNumber, '003058656T');
    });

    test('normalises valid numbers so the same number matches', () {
      for (final (input, normalized) in [
        ('200803090077', '200803090077'),
        ('003058656-T', '003058656T'),
        ('SA0085324-V', 'SA0085324V'),
        ('499519-U', '499519U'),
        ('sa 0085324 - v', 'SA0085324V'),
      ]) {
        expect(SsmNumber.parse(input)?.normalized, normalized, reason: input);
      }
    });

    test('rejects an unknown entity type code, an implausible year or nothing', () {
      for (final input in ['201999350205', '999903350205', '', null]) {
        expect(SsmNumber.validate(input), isNotNull, reason: '$input');
      }
    });

    test('names the digit count on a near miss', () {
      expect(SsmNumber.validate('20190335020'), contains('12 digits'));
    });
  });

  group('Profile models', () {
    test('AppUser exposes profile field defaults', () {
      const user = AppUser(
        uid: 'u',
        email: 'e@x.com',
        displayName: 'A',
        role: UserRole.provider,
      );
      expect(user.bio, isNull);
      expect(user.walletBalanceSen, 0);
      expect(user.ratingCount, 0);
      expect(user.ratingSum, 0);
      expect(user.averageRating, isNull);
    });

    test('AppUser.averageRating divides sum by count', () {
      const user = AppUser(
        uid: 'u',
        email: 'e@x.com',
        displayName: 'A',
        role: UserRole.provider,
        ratingCount: 4,
        ratingSum: 18,
      );
      expect(user.averageRating, 4.5);
    });

    test('Review round-trips through toMap/fromMap', () {
      const review = Review(
        id: 'r1',
        reviewerId: 'rev',
        reviewerName: 'Sarah Connor',
        rating: 5,
        comment: 'Great work.',
        jobId: 'job-1',
        jobTitle: 'Fix sink',
      );
      final parsed = Review.fromMap('r1', review.toMap());
      expect(parsed.reviewerName, 'Sarah Connor');
      expect(parsed.rating, 5);
      expect(parsed.comment, 'Great work.');
      expect(parsed.jobId, 'job-1');
      expect(parsed.jobTitle, 'Fix sink');
    });

    test('PublicProfile.fromMap maps every public field and cannot expose '
        'private ones', () {
      // A realistic doc carrying every field the mapper is forbidden from
      // reading (email/phone/wallet/payout/private-doc-only/coordinates/
      // raw disputesLost/suspension), alongside the fields it should map.
      final map = <String, dynamic>{
        'displayName': 'Jane Doe',
        'email': 'jane@example.com',
        'role': 'provider',
        'bio': 'Experienced plumber.',
        'location': 'Some free-text address',
        'baseTown': 'Bayan Lepas',
        'baseLat': 5.35,
        'baseLng': 100.28,
        'baseAddress': '12, Jalan Mawar 3',
        'walletBalanceSen': 999999,
        'escrowLockedSen': 5000,
        'verificationStatus': 'approved',
        'trustScore': 620,
        'trust': {
          'reviewScore': 80,
          'trackRecordScore': 70,
          'verificationScore': 100,
          'profileScore': 60,
          'composite': 620,
          'scoreVisible': true,
        },
        'ratingCount': 12,
        'ratingSum': 55,
        'jobsCompleted': 8,
        'jobsPosted': 3,
        'hireRate': 66,
        'disputesLost': 2,
        'suspended': true,
        'suspensionReason': 'spam',
        'profilePhotoUrl': 'https://example.com/me.jpg',
        'idDocumentUrl': 'https://example.com/id.jpg',
        'selfieUrl': 'https://example.com/selfie.jpg',
        'createdAt': DateTime(2025, 3, 1),
        'onboarding': {
          'providerType': 'individual',
          'category': 'Plumbing',
          'skills': ['Pipe repair', 'Leak detection'],
          'coverageArea': 'George Town, Bayan Lepas',
          'hourlyRate': '60',
          'portfolioImageUrls': ['https://example.com/p1.jpg'],
          'portfolioLinks': ['https://example.com/portfolio'],
          'certificateUrls': [
            'https://example.com/c1.pdf',
            'https://example.com/c2.pdf',
          ],
          'bankName': 'Maybank',
          'accountHolder': 'Jane Doe',
          'accountLast4': '6789',
          'branchCode': '1234',
        },
      };

      final profile = PublicProfile.fromMap('uid-1', map);

      // Public fields map correctly.
      expect(profile.displayName, 'Jane Doe');
      expect(profile.bio, 'Experienced plumber.');
      // Prefers the structured town over the free-text location field.
      expect(profile.location, 'Bayan Lepas');
      expect(profile.trustScore, 620);
      expect(profile.scoreVisible, isTrue);
      expect(profile.ratingCount, 12);
      expect(profile.averageRating, closeTo(55 / 12, 0.001));
      expect(profile.jobsCompleted, 8);
      expect(profile.jobsPosted, 3);
      expect(profile.hireRate, 66);
      expect(profile.category, 'Plumbing');
      expect(profile.skills, ['Pipe repair', 'Leak detection']);
      expect(profile.coverageArea, 'George Town, Bayan Lepas');
      expect(profile.portfolioImageUrls, ['https://example.com/p1.jpg']);
      expect(profile.portfolioLinks, ['https://example.com/portfolio']);
      expect(profile.memberSince, DateTime(2025, 3, 1));

      // Certificates are exposed only as a count, never the URLs - and
      // [PublicProfile] has no field/getter at all that could return them,
      // nor one for email/phone/wallet/payout/coordinates/suspension: the
      // type itself is the proof those values can never surface through
      // this model, regardless of what the source map carries.
      expect(profile.certificateCount, 2);
    });

    test('PublicProfile.hireRate is null when jobsPosted is zero', () {
      // Never a forged "0%" for a client who hasn't posted a job yet.
      final profile = PublicProfile.fromMap('uid-2', {
        'role': 'requestor',
        'jobsPosted': 0,
        'hireRate': 0,
      });
      expect(profile.jobsPosted, 0);
      expect(profile.hireRate, isNull);
    });

    test('PublicProfile falls back to the free-text location field', () {
      final profile = PublicProfile.fromMap('uid-3', {
        'role': 'requestor',
        'location': 'Georgetown',
      });
      expect(profile.location, 'Georgetown');
    });
  });

  group('Money & distance', () {
    test('formatRm formats sen as RM', () {
      expect(formatRm(0), 'RM\u00A00.00');
      expect(formatRm(12550), 'RM\u00A0125.50');
      expect(formatRm(100000), 'RM\u00A01,000.00');
    });

    test('formatBudget handles fixed, range and hourly', () {
      expect(formatBudget(), isNull);
      expect(formatBudget(minSen: 10000), 'RM\u00A0100.00');
      expect(
        formatBudget(minSen: 10000, maxSen: 25000),
        'RM\u00A0100.00 – RM\u00A0250.00',
      );
      expect(formatBudget(minSen: 5000, hourly: true), 'RM\u00A050.00/hr');
    });

    test('parseRmToSen parses money text', () {
      expect(parseRmToSen(''), isNull);
      expect(parseRmToSen('125.50'), 12550);
      expect(parseRmToSen('1,000'), 100000);
    });

    test('distanceKm ~0 for same point, positive otherwise', () {
      const kl = LatLng(3.139, 101.6869);
      expect(distanceKm(kl, kl), lessThan(0.001));
      expect(distanceKm(kl, const LatLng(3.2, 101.75)), greaterThan(1));
    });
  });
}
