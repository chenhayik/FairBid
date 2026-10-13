import 'dart:async';

import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/util/service_categories.dart';
import 'package:fairbid/core/widgets/face_crop.dart';
import 'package:fairbid/core/widgets/form_widgets.dart';
import 'package:fairbid/features/onboarding/data/face_checker.dart';
import 'package:fairbid/features/onboarding/domain/onboarding_data.dart';
import 'package:fairbid/features/onboarding/domain/id_extract.dart';
import 'package:fairbid/features/onboarding/domain/ssm_extract.dart';
import 'package:fairbid/features/onboarding/presentation/onboarding_controller.dart';
import 'package:fairbid/features/onboarding/presentation/requestor_onboarding_controller.dart';
import 'package:fairbid/features/onboarding/presentation/requestor_steps/details_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/identity_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/profile_step.dart';
import 'package:fairbid/features/onboarding/presentation/steps/service_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('SSM autofill chain', () {
    /// A picker that yields a file without touching the platform channel, so
    /// the upload path can be exercised in a widget test at all.
    Future<XFile?> fakePicker() async =>
        XFile('ssm.pdf', mimeType: 'application/pdf');

    const verdict = SsmExtract(
      verdict: SsmVerdict.passed,
      businessName: 'Jin Xiao Long Trading',
      registrationNumber: '201903350205',
    );

    OnboardingController build(FakeOnboardingRepository repo) =>
        OnboardingController(repo, FakeDocumentStorageRepository(),
            pdfPicker: fakePicker);

    test('a verdict written before this session still reaches the UI', () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = verdict;
      final controller = build(repo);

      await controller.loadFor('provider-1');
      await Future<void>.delayed(Duration.zero); // let the stream deliver

      expect(controller.ssmExtract, isNotNull,
          reason: 'resuming after an upload must still show the verdict');
    });

    test('the typed number is persisted before the document is uploaded',
        () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository());
      final controller = build(repo);
      await controller.loadFor('provider-1');
      controller
        ..data.providerType = ProviderType.business
        ..setSsmNumber('201903350205');

      await controller.pickSsmDocument();

      // The extract trigger fires the instant the bytes land, and reads the
      // number from Firestore - so it has to be saved first or the server's
      // cross-check compares against nothing.
      expect(repo.saved?.ssmNumberNormalized, '201903350205',
          reason: 'the server cannot cross-check a number it cannot see');
    });

    test('applying the verdict fills both fields', () async {
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = verdict;
      final controller = build(repo);
      await controller.loadFor('provider-1');
      await Future<void>.delayed(Duration.zero);

      controller.applySsmExtract();

      expect(controller.data.businessName, 'Jin Xiao Long Trading');
      expect(controller.data.ssmNumber, '201903350205');
      expect(controller.data.ssmNumberNormalized, '201903350205');
    });

    test('SsmExtract.fromMap reads what the Cloud Function writes', () {
      final extract = SsmExtract.fromMap({
        'verdict': 'needsReview',
        'failures': ['not-digitally-signed'],
        'businessName': 'Sunmal Dental Art',
        'registrationNumber': '200803090077',
        'entityStatus': 'ACTIVE',
        'ownership': 'SOLE PROPRIETORSHIP',
        'expiryDate': '2020-10-08',
        'businessStartDate': '2008-05-05',
        'natureOfBusiness': 'PERKHIDMATAN PERGIGIAN & KESIHATAN',
        'signaturePresent': false,
      });

      expect(extract, isNotNull);
      expect(extract!.verdict, SsmVerdict.needsReview);
      expect(extract.hasProposals, isTrue);
      expect(extract.reasons.single, contains('not a digitally certified copy'));
      expect(extract.expiryDate, '2020-10-08');
      expect(extract.natureOfBusiness, 'PERKHIDMATAN PERGIGIAN & KESIHATAN');
    });

    test('an expired registration reads as a plain-English reason', () {
      final extract = SsmExtract.fromMap({
        'verdict': 'rejected',
        'failures': ['registration-expired'],
        'expiryDate': '2020-10-08',
      });

      expect(extract!.verdict, SsmVerdict.rejected);
      expect(extract.reasons.single, contains('expired'));
    });

    test('the owner check is three-valued, not a boolean', () {
      SsmExtract? read(Object? value) => SsmExtract.fromMap({
            'verdict': 'passed',
            'ownerNameMatches': value,
          });

      expect(read(true)!.ownerNameMatches, isTrue);
      expect(read(false)!.ownerNameMatches, isFalse);
      // Absent means no Profile was supplied, or neither name was usable -
      // which is emphatically not the same as "the owner does not match".
      expect(read(null)!.ownerNameMatches, isNull);
    });

    test('a registered trade suggests a category, in Malay or English', () {
      expect(suggestedCategoryFor('PERKHIDMATAN PEMBERSIHAN AM'), 'Cleaning');
      expect(suggestedCategoryFor('KERJA-KERJA PERPAIPAN'), 'Plumbing');
      expect(suggestedCategoryFor('PENYAMAN UDARA'), 'Aircon Servicing');
      expect(suggestedCategoryFor('General cleaning services'), 'Cleaning');
    });

    test('an unmatched trade suggests nothing rather than guessing', () {
      // The Profile sample is a dental practice - not one of the ten
      // categories this app serves. A confident null beats a wrong guess,
      // because the suggestion is written into the applicant's form.
      expect(suggestedCategoryFor('PERKHIDMATAN PERGIGIAN & KESIHATAN'),
          isNull);
      expect(suggestedCategoryFor(null), isNull);
      expect(suggestedCategoryFor(''), isNull);
    });

    test('an unrecognised verdict is treated as no verdict', () {
      expect(SsmExtract.fromMap({'verdict': 'weird'}), isNull);
      expect(SsmExtract.fromMap(null), isNull);
    });
  });

  group('SSM autofill into the later stages', () {
    /// Builds a controller whose server verdict is already in, then pumps
    /// [step] - the autofill happens in each step's initState, so the
    /// assertions are on the controller rather than on rendered widgets.
    Future<OnboardingController> pumpStage(
      WidgetTester tester,
      Widget step, {
      String? natureOfBusiness,
      void Function(OnboardingData data)? seed,
    }) async {

      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..ssmExtract = SsmExtract(
          verdict: SsmVerdict.passed,
          businessName: 'Jin Xiao Long Trading',
          natureOfBusiness: natureOfBusiness,
        );
      final controller =
          OnboardingController(repo, FakeDocumentStorageRepository());
      // runAsync, because loadFor awaits a stream delivery and testWidgets'
      // fake-async zone will not drain it - a plain await here deadlocks.
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero); // let the verdict arrive
      });
      controller.data.providerType = ProviderType.business;
      seed?.call(controller.data);

      await pumpOnboardingStep(tester, controller, step, size: const Size(500, 2400));
      return controller;
    }

    testWidgets('stage 4 offers the registered name as the display name', (
      tester,
    ) async {
      await pumpStage(tester, const ProfileStep(),
          seed: (data) => data.businessName = 'Jin Xiao Long Trading');

      expect(find.widgetWithText(TextFormField, 'Jin Xiao Long Trading'),
          findsOneWidget);
    });

    testWidgets('stage 4 never overwrites a display name already chosen', (
      tester,
    ) async {
      await pumpStage(tester, const ProfileStep(), seed: (data) {
        data
          ..businessName = 'Jin Xiao Long Trading'
          ..displayName = 'Ah Long Plumbing';
      });

      expect(find.widgetWithText(TextFormField, 'Ah Long Plumbing'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Jin Xiao Long Trading'),
          findsNothing);
    });

    testWidgets('stage 5 suggests a category from the registered trade', (
      tester,
    ) async {
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'KERJA-KERJA PERPAIPAN');

      expect(controller.data.category, 'Plumbing');
    });

    testWidgets('stage 5 never overwrites a category already chosen', (
      tester,
    ) async {
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'KERJA-KERJA PERPAIPAN',
          seed: (data) => data.category = 'Tutoring');

      expect(controller.data.category, 'Tutoring');
    });

    testWidgets('stage 5 leaves the category alone for an unmatched trade', (
      tester,
    ) async {
      // The Profile sample is a dental practice - not a category this app
      // serves, so nothing should be filled in.
      final controller = await pumpStage(tester, const ServiceStep(),
          natureOfBusiness: 'PERKHIDMATAN PERGIGIAN & KESIHATAN');

      expect(controller.data.category, isNull);
    });
  });

  group('Business provider SSM step', () {
    /// Pumps the identity stage on its own, with the controller pre-loaded and
    /// the ID and selfie already uploaded - so the only thing standing between
    /// it and Continue is the SSM block under test.
    Future<OnboardingController> pumpStep(
      WidgetTester tester, {
      ProviderType type = ProviderType.business,
      IdDocumentType idType = IdDocumentType.passport,
      bool consent = true,
    }) async {

      // A verdict is preloaded so the ID card is not a never-settling spinner.
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository())
          ..idExtract = const IdExtract(verdict: IdVerdict.passed),
        FakeDocumentStorageRepository(),
      );
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..providerType = type
        ..idDocumentType = idType
        ..idDocumentUrl = 'https://fake.storage/id'
        ..selfieUrl = 'https://fake.storage/selfie'
        ..idConsentAt = consent ? DateTime(2026, 9, 30) : null;

      await pumpOnboardingStep(tester, controller, const IdentityStep(), settle: true, size: const Size(500, 2400));
      return controller;
    }

    FilledButton continueButton(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));

    /// The document is uploaded through the system file picker, which cannot
    /// run in a widget test - so apply the result the upload would have
    /// produced, then notify, exactly as `pickSsmDocument` does.
    void attachDocument(OnboardingController controller) {
      controller.data.ssmDocumentUrl = 'https://fake.storage/ssm';
      controller.selectProviderType(ProviderType.business);
    }

    testWidgets('individual providers never see the business block', (
      tester,
    ) async {
      await pumpStep(tester, type: ProviderType.individual);

      expect(find.text('Business registration'), findsNothing);
      // ID and selfie are already in place, so nothing else blocks Continue.
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a business is blocked until name, number and document are in', (
      tester,
    ) async {
      final controller = await pumpStep(tester);

      expect(find.text('Business registration'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull,
          reason: 'nothing supplied yet');

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '201903350205');
      await tester.pumpAndSettle();
      expect(continueButton(tester).onPressed, isNull,
          reason: 'the SSM document is required');

      attachDocument(controller);
      await tester.pump(); // a spinner is now on screen - see above
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('names what is still missing instead of only disabling', (
      tester,
    ) async {
      await pumpStep(tester);

      String hint() =>
          tester.widget<Text>(find.textContaining('Still needed:')).data!;

      // The button is driven by the same list as the hint, so the two can
      // never disagree - that is the point of the change.
      expect(continueButton(tester).onPressed, isNull);
      expect(hint(), contains('your registered business name'));
      expect(hint(), contains('a valid SSM registration number'));
      expect(hint(), contains('your SSM document'));

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await tester.pumpAndSettle();
      expect(hint(), isNot(contains('your registered business name')),
          reason: 'the hint must shrink as requirements are met');
    });

    testWidgets('shows a checking state between upload and verdict', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      attachDocument(controller); // uploaded, no verdict yet
      // pump(), not pumpAndSettle(): the checking card holds a
      // CircularProgressIndicator, which never stops animating and so never
      // lets the tree settle.
      await tester.pump();

      expect(find.textContaining('Checking your document'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('the owner check is offered but never gates Continue', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      expect(find.text('Confirm you are the owner (optional)'), findsOneWidget);

      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '201903350205');
      await tester.pumpAndSettle();
      attachDocument(controller);
      await tester.pump();

      // No Business Profile supplied - Continue must still be available, or
      // the "optional" framing is a lie.
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('an unparseable SSM number keeps Continue locked', (
      tester,
    ) async {
      final controller = await pumpStep(tester);
      await fillField(
          tester, 'Registered Business Name', 'Jin Xiao Long Trading');
      await fillField(tester, 'SSM Registration Number', '12345');
      await tester.pumpAndSettle();
      // Attached last: once the checking card is up, nothing settles.
      attachDocument(controller);
      await tester.pump();

      expect(continueButton(tester).onPressed, isNull);
    });

    testWidgets('the typed number is normalised for matching', (
      tester,
    ) async {
      final controller = await pumpStep(tester);

      await fillField(tester, 'SSM Registration Number', 'sa 0085324 - v');
      await tester.pumpAndSettle();

      expect(controller.data.ssmNumberNormalized, 'SA0085324V');
    });

    String hint(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining('Still needed:')).data!;

    testWidgets('an invalid MyKad number shows an error and blocks Continue', (
      tester,
    ) async {
      await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);

      expect(hint(tester), contains('a valid MyKad number'));
      await fillField(tester, 'MyKad Number', '901301-07-1234');
      await tester.pumpAndSettle();

      expect(find.text('The birth date in this number is not a real date.'),
          findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);
      expect(hint(tester), contains('a valid MyKad number'));
    });

    testWidgets('a valid MyKad number clears the requirement', (
      tester,
    ) async {
      final controller = await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);

      await fillField(tester, 'MyKad Number', '900101-07-1234');
      await tester.pumpAndSettle();

      expect(find.text('Still needed: a valid MyKad number.'), findsNothing);
      expect(controller.data.icNumber, '900101-07-1234');
      // A number typed after the photo went up invalidates the photo.
      expect(controller.data.idDocumentUrl, isNull);
    });

    testWidgets('Passport hides the MyKad field', (tester) async {
      await pumpStep(tester,
          type: ProviderType.individual, idType: IdDocumentType.mykad);
      expect(find.text('MyKad Number'), findsOneWidget);

      await tester.tap(find.text('Passport'));
      await tester.pumpAndSettle();

      expect(find.text('MyKad Number'), findsNothing);
      // The MyKad photo was never checked as a passport, so a fresh one is due.
      expect(hint(tester), isNot(contains('MyKad number')));
      expect(hint(tester), contains('a photo of your ID'));
    });

    test('changing the IC clears the uploaded ID, re-typing the same does not',
        () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      controller.data.idDocumentUrl = 'https://fake.storage/id';

      controller.setIcNumber('900101-07-1234');
      expect(controller.data.idDocumentUrl, isNull);

      controller.data.idDocumentUrl = 'https://fake.storage/id';
      controller.setIcNumber('900101071234'); // same digits, no dashes
      expect(controller.data.idDocumentUrl, isNotNull);

      controller.setIcNumber('850615-10-5567');
      expect(controller.data.idDocumentUrl, isNull);
    });

    test('the IC is private and the ID type is public', () {
      final data = OnboardingData()
        ..icNumber = '900101-07-1234'
        ..idDocumentType = IdDocumentType.passport;
      expect(data.toMap().containsKey('icNumber'), isFalse);
      expect(data.privateMap()['icNumber'], '900101-07-1234');
      expect(OnboardingData.fromMap(data.toMap()).idDocumentType,
          IdDocumentType.passport);
      expect(OnboardingData.fromMap(null).idDocumentType,
          IdDocumentType.mykad);
    });
  });

  group('Automated ID check', () {
    test('switching ID type clears the uploaded photo, same type keeps it', () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      controller.data.idDocumentUrl = 'https://fake.storage/id';

      controller.setIdDocumentType(IdDocumentType.mykad); // unchanged
      expect(controller.data.idDocumentUrl, isNotNull);

      controller.setIdDocumentType(IdDocumentType.passport);
      expect(controller.data.idDocumentUrl, isNull);
    });

    test('the ID type is saved before the photo uploads, for both types',
        () async {
      for (final type in IdDocumentType.values) {
        final events = <String>[];
        final controller = OnboardingController(
          _OrderRepo(FakeAuthRepository(), events),
          _OrderStorage(events),
          imagePicker: _FakePicker(),
          faceChecker: FakeFaceChecker(),
        );
        await controller.loadFor('provider-1');
        controller.data
          ..idDocumentType = type
          ..idConsentAt = DateTime(2026, 9, 30);

        await controller.pickIdDocument(ImageSource.gallery);

        expect(events, ['save:${type.name}', 'upload'], reason: type.name);
      }
    });

    test('IdExtract.fromMap reads the function output and tolerates gaps', () {
      final extract = IdExtract.fromMap({
        'verdict': 'rejected',
        'failures': ['ic-mismatch', 7, 'name-mismatch'],
        'maskedIc': '******-07-**34',
        'ageOk': true,
        'nameMatches': null,
        'storagePath': 'verification/u/id_document_1.jpg',
      });
      expect(extract!.verdict, IdVerdict.rejected);
      expect(extract.failures, ['ic-mismatch', 'name-mismatch']);
      expect(extract.maskedIc, '******-07-**34');
      expect(extract.ageOk, isTrue);
      expect(extract.nameMatches, isNull);
      expect(extract.genderConsistent, isNull);
      expect(IdExtract.fromMap({'verdict': 'weird'}), isNull);
      expect(IdExtract.fromMap(null), isNull);
      expect(idFailureLabel('ic-mismatch'), contains('does not match'));
      expect(idFailureLabel('mystery'), 'mystery');
    });

    Future<OnboardingController> pumpCard(
      WidgetTester tester, {
      IdExtract? extract,
    }) async {
      final repo = FakeOnboardingRepository(FakeAuthRepository())
        ..idExtract = extract;
      final controller =
          OnboardingController(repo, FakeDocumentStorageRepository());
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..idDocumentType = IdDocumentType.mykad
        ..icNumber = '900101-07-1234'
        ..idDocumentUrl = 'https://fake.storage/id'
        ..selfieUrl = 'https://fake.storage/selfie'
        ..idConsentAt = DateTime(2026, 9, 30);
      await pumpOnboardingStep(tester, controller, const IdentityStep(), size: const Size(500, 2400));
      return controller;
    }

    FilledButton continueButton(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'));

    testWidgets('shows a checking state until the verdict arrives', (
      tester,
    ) async {
      await pumpCard(tester);
      expect(find.textContaining('Checking your card'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a verdict that never comes degrades to a background note', (
      tester,
    ) async {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
        imagePicker: _FakePicker(),
        faceChecker: FakeFaceChecker(),
      );
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      controller.data
        ..icNumber = '900101-07-1234'
        ..idConsentAt = DateTime(2026, 9, 30)
        ..selfieUrl = 'https://fake.storage/selfie';
      await controller.pickIdDocument(ImageSource.gallery);
      await pumpOnboardingStep(tester, controller, const IdentityStep(), size: const Size(500, 2400));
      expect(find.textContaining('Checking your card'), findsOneWidget);

      await tester.pump(const Duration(seconds: 31));
      expect(find.textContaining('Checking your card'), findsNothing);
      expect(find.textContaining('finish checking this in the background'),
          findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a needs-review verdict lists each failure label', (
      tester,
    ) async {
      await pumpCard(tester,
          extract: const IdExtract(
              verdict: IdVerdict.needsReview,
              failures: ['name-mismatch', 'unknown-pb-code']));
      expect(find.text(idFailureLabel('name-mismatch')), findsOneWidget);
      expect(find.text(idFailureLabel('unknown-pb-code')), findsOneWidget);
      expect(find.text('An admin will review your documents.'), findsOneWidget);
    });

    testWidgets('a passed verdict says the card looks good', (tester) async {
      await pumpCard(tester,
          extract: const IdExtract(verdict: IdVerdict.passed));
      expect(find.text('Card details look good'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('a rejected verdict lists reasons but never blocks Continue', (
      tester,
    ) async {
      await pumpCard(tester,
          extract: const IdExtract(
              verdict: IdVerdict.rejected, failures: ['ic-mismatch']));
      expect(find.text(idFailureLabel('ic-mismatch')), findsOneWidget);
      expect(find.textContaining('retaking a clear'), findsOneWidget);
      expect(find.text('An admin will review your documents.'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('the card is hidden for passports', (tester) async {
      final controller = await pumpCard(tester);
      controller.setIdDocumentType(IdDocumentType.passport);
      await tester.pump();
      expect(find.textContaining('Checking your card'), findsNothing);
    });
  });

  group('Upload progress', () {
    Future<OnboardingController> build(
      _GatedStorage storage,
      FaceChecker faces,
    ) async {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        storage,
        imagePicker: _FakePicker(),
        faceChecker: faces,
      );
      await controller.loadFor('provider-1');
      controller.data
        ..icNumber = '900101-07-1234'
        ..idConsentAt = DateTime(2026, 9, 30);
      return controller;
    }

    // The ID box is the first UploadBox on the page (individual, MyKad).
    Finder idBox() => find.byType(UploadBox).at(0);

    Future<void> tapIdBox(WidgetTester tester) async {
      await tester.tap(find.textContaining('JPEG, PNG up to 10MB'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from gallery'));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('the ID box spins while its upload is pending', (tester) async {
      final storage = _GatedStorage();
      final controller = await build(storage, FakeFaceChecker());
      await pumpOnboardingStep(tester, controller, const IdentityStep(), size: const Size(500, 2400));

      await tapIdBox(tester);
      expect(find.descendant(of: idBox(), matching: find.text('Uploading…')),
          findsOneWidget);
      expect(
          find.descendant(
              of: idBox(), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      // The selfie box is untouched.
      expect(find.descendant(
          of: find.byType(UploadBox).at(1), matching: find.text('Uploading…')),
          findsNothing);

      storage.gate.complete('https://fake.storage/id');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Document uploaded'), findsOneWidget);
      expect(find.text('Uploading…'), findsNothing);
      await tester.pump(const Duration(seconds: 31)); // the ID-check wait timer
    });

    testWidgets('a pending face check shows "Checking photo…"', (tester) async {
      final faces = _GatedFaceChecker();
      final storage = _GatedStorage()..gate.complete('https://fake.storage/id');
      final controller = await build(storage, faces);
      await pumpOnboardingStep(tester, controller, const IdentityStep(), size: const Size(500, 2400));

      await tapIdBox(tester);
      expect(find.descendant(of: idBox(), matching: find.text('Checking photo…')),
          findsOneWidget);
      expect(
          find.descendant(
              of: idBox(), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);

      faces.gate.complete(const FaceCheckResult());
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Checking photo…'), findsNothing);
      expect(find.text('Document uploaded'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31)); // the ID-check wait timer
    });

    test('a second pick while one is in flight starts no second upload',
        () async {
      final storage = _GatedStorage();
      final controller = await build(storage, FakeFaceChecker());

      final first = controller.pickIdDocument(ImageSource.gallery);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isUploading('id_document'), isTrue);
      expect(controller.isUploading('selfie'), isFalse);

      await controller.pickSelfie(ImageSource.gallery); // ignored
      expect(storage.purposes, ['id_document']);

      storage.gate.complete('https://fake.storage/id');
      await first;
      expect(controller.isUploading('id_document'), isFalse);
      expect(controller.data.selfieUrl, isNull);
      controller.dispose(); // cancels the ID-check wait timer
    });

    testWidgets('the requestor profile photo box spins while uploading',
        (tester) async {
      final storage = _GatedStorage();
      final controller = RequestorOnboardingController(
        FakeRequestorOnboardingRepository(FakeAuthRepository()),
        storage,
        imagePicker: _FakePicker(),
      );
      await controller.loadFor('client-1');
      await pumpOnboardingStep(tester, controller, const DetailsStep(), size: const Size(500, 2400));

      await tester.tap(find.byType(UploadBox));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Uploading…'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(UploadBox),
              matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);

      storage.gate.complete('https://fake.storage/avatar');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Photo added'), findsOneWidget);
      expect(find.text('Uploading…'), findsNothing);
    });
  });

  group('Face check and consent', () {
    const box =
        FaceBox(left: 0.25, top: 0.25, width: 0.5, height: 0.5, aspect: 1.5);
    const noFace = FaceCheckResult(problem: 'Face the camera straight on.');

    Future<(OnboardingController, List<String>)> build(
      FakeFaceChecker faces, {
      bool consent = true,
    }) async {
      final events = <String>[];
      final controller = OnboardingController(
        _OrderRepo(FakeAuthRepository(), events),
        _OrderStorage(events),
        imagePicker: _FakePicker(),
        faceChecker: faces,
      );
      await controller.loadFor('provider-1');
      if (consent) controller.data.idConsentAt = DateTime(2026, 9, 30);
      return (controller, events);
    }

    test('FaceBox survives toMap/fromMap, and bad maps give null', () {
      expect(FaceBox.fromMap(box.toMap()), box);
      expect(FaceBox.fromMap(null), isNull);
      expect(FaceBox.fromMap({'left': 0.1}), isNull);
    });

    test('a face problem shows the message and uploads nothing', () async {
      final (controller, events) = await build(FakeFaceChecker(noFace));

      await controller.pickSelfie(ImageSource.gallery);

      expect(controller.errorMessage, noFace.problem);
      expect(events, isEmpty, reason: 'no save and no upload');
      expect(controller.data.selfieUrl, isNull);
      expect(controller.isBusy, isFalse);
    });

    test('a passing photo uploads and its face box lands in privateMap',
        () async {
      final faces = FakeFaceChecker(const FaceCheckResult(box: box));
      final (controller, events) = await build(faces);

      await controller.pickSelfie(ImageSource.gallery);
      await controller.pickIdDocument(ImageSource.gallery);

      expect(faces.calls, [FaceCheckKind.selfie, FaceCheckKind.idCard]);
      expect(events, contains('upload'));
      expect(controller.data.selfieUrl, isNotNull);
      final private = controller.data.privateMap();
      expect(private['selfieFaceBox'], box.toMap());
      expect(private['idFaceBox'], box.toMap());
      expect(controller.data.toMap().containsKey('selfieFaceBox'), isFalse);
    });

    test('changing the IC drops the old ID face box', () async {
      final (controller, _) =
          await build(FakeFaceChecker(const FaceCheckResult(box: box)));
      await controller.pickIdDocument(ImageSource.gallery);
      expect(controller.data.idFaceBox, box);

      controller.setIcNumber('900101-07-1234');
      expect(controller.data.idFaceBox, isNull);
    });

    test('without consent nothing is checked or uploaded', () async {
      final faces = FakeFaceChecker();
      final (controller, events) = await build(faces, consent: false);

      await controller.pickSelfie(ImageSource.gallery);
      await controller.pickIdDocument(ImageSource.gallery);

      expect(faces.calls, isEmpty);
      expect(events, isEmpty);
    });

    test('consent is stamped in privateMap only, and unticking clears it', () {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      expect(controller.data.privateMap()['idConsentAt'], isNull);

      controller.setIdConsent(true);
      expect(controller.data.privateMap()['idConsentAt'], isA<DateTime>());
      expect(controller.data.toMap().containsKey('idConsentAt'), isFalse);

      controller.setIdConsent(false);
      expect(controller.data.privateMap()['idConsentAt'], isNull);
    });

    testWidgets('uploads stay locked and the hint asks until consent is ticked',
        (tester) async {
      final controller = OnboardingController(
        FakeOnboardingRepository(FakeAuthRepository()),
        FakeDocumentStorageRepository(),
      );
      await tester.runAsync(() async {
        await controller.loadFor('provider-1');
        await Future<void>.delayed(Duration.zero);
      });
      await pumpOnboardingStep(tester, controller, const IdentityStep(), settle: true, size: const Size(500, 2400));
      String hint() =>
          tester.widget<Text>(find.textContaining('Still needed:')).data!;
      final selfieBox = find.textContaining('Make sure face and ID are clear');

      expect(hint(), contains('your consent to identity checks'));
      await tester.tap(selfieBox, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Add your selfie'), findsNothing);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(hint(), isNot(contains('consent')));
      expect(controller.data.idConsentAt, isNotNull);
      await tester.tap(selfieBox);
      await tester.pumpAndSettle();
      expect(find.text('Add your selfie'), findsOneWidget);
    });

    testWidgets('a failed image shows its icon inside the visible crop', (
      tester,
    ) async {
      for (final box in <FaceBox?>[
        const FaceBox(left: 0.4, top: 0.3, width: 0.2, height: 0.2, aspect: 1.5),
        null,
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: FaceCrop(url: 'https://fake.storage/gone.jpg', box: box),
          ),
        ));
        await tester.pumpAndSettle(); // the test HTTP client answers 400

        final icon = find.byIcon(Icons.broken_image_outlined);
        expect(icon, findsOneWidget, reason: 'box: $box');
        expect(icon.hitTestable(), findsOneWidget, reason: 'box: $box');
        final crop = tester.getRect(find.byType(FaceCrop));
        expect(crop.contains(tester.getCenter(icon)), isTrue, reason: 'box: $box');
      }
    });

    test('FaceCropLayout pads the box by 20% and scales it to the width', () {
      // Padded box is (0.15, 0.15, 0.7, 0.7); at 100 wide the image is 100/0.7.
      const b =
          FaceBox(left: 0.25, top: 0.25, width: 0.5, height: 0.5, aspect: 1);
      final l = FaceCropLayout.of(b, 100);
      expect(l.imageW, closeTo(142.857, 0.001));
      expect(l.imageH, closeTo(142.857, 0.001));
      expect(l.cropH, closeTo(100, 0.001));
      expect(l.left, closeTo(-21.428, 0.001));
      expect(l.top, closeTo(-21.428, 0.001));
    });

    test('FaceCropLayout keeps the padding inside the image', () {
      const b = FaceBox(left: 0, top: 0, width: 0.5, height: 0.5, aspect: 2);
      final l = FaceCropLayout.of(b, 100); // padded (0, 0, 0.6, 0.6)
      expect(l.left, 0);
      expect(l.top, 0);
      expect(l.imageW, closeTo(166.667, 0.001));
      expect(l.imageH, closeTo(83.333, 0.001));
      expect(l.cropH, closeTo(50, 0.001));
    });
  });

  group('Leaving onboarding', () {
    /// Registers a brand-new requestor, who the router sends into onboarding.
    Future<void> openOnboarding(WidgetTester tester) async {
      await pumpApp(tester, buildApp(FakeAuthRepository()..onboardingComplete = false));
      await openRegisterAs(tester, 'Hire');
      expect(find.text('How will you hire?'), findsOneWidget);
    }

    testWidgets('back on the first stage asks before signing out', (
      tester,
    ) async {
      await openOnboarding(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // It must ask, not act: this used to sign the user out on one tap.
      expect(find.text('Leave onboarding?'), findsOneWidget);
    });

    testWidgets('choosing Stay keeps the user in onboarding', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await tester.pumpAndSettle();

      expect(find.text('Leave onboarding?'), findsNothing);
      expect(find.text('How will you hire?'), findsOneWidget);
    });

    testWidgets('choosing Sign out leaves onboarding', (tester) async {
      await openOnboarding(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('How will you hire?'), findsNothing);
    });
  });
}

/// Records save/upload order so tests can assert what the server would see.
class _OrderRepo extends FakeOnboardingRepository {
  _OrderRepo(super.auth, this.events);

  final List<String> events;

  @override
  Future<void> save(String uid, OnboardingData data) async =>
      events.add('save:${data.idDocumentType.name}');
}

class _OrderStorage extends FakeDocumentStorageRepository {
  _OrderStorage(this.events);

  final List<String> events;

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) async {
    events.add('upload');
    return 'https://fake.storage/$uid/$purpose';
  }
}

/// Storage whose uploads stay pending until [gate] completes, so a test can
/// look at the UI mid-upload.
class _GatedStorage extends FakeDocumentStorageRepository {
  final gate = Completer<String>();
  final purposes = <String>[];

  @override
  Future<String> uploadVerificationImage({
    required String uid,
    required String purpose,
    required XFile file,
  }) {
    purposes.add(purpose);
    return gate.future;
  }

  @override
  Future<String> uploadAvatar({required String uid, required XFile file}) {
    purposes.add('avatar');
    return gate.future;
  }
}

/// Face checker that stays pending until [gate] completes.
class _GatedFaceChecker implements FaceChecker {
  final gate = Completer<FaceCheckResult>();

  @override
  Future<FaceCheckResult> check(String filePath, FaceCheckKind kind) =>
      gate.future;
}

class _FakePicker extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile('id.jpg');
}

