import 'package:fairbid/core/location/address_hint.dart';
import 'package:fairbid/core/location/penang.dart';
import 'package:fairbid/core/location/penang_districts.dart';
import 'package:fairbid/core/location/region.dart';
import 'package:fairbid/core/location/region_picker_screen.dart';
import 'package:fairbid/core/theme/app_theme.dart';
import 'package:fairbid/features/jobs/domain/service_address.dart';
import 'package:fairbid/features/jobs/presentation/detail/service_address_sheet.dart';
import 'package:fairbid/features/onboarding/presentation/onboarding_controller.dart';
import 'package:fairbid/features/onboarding/presentation/steps/service_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' show Placemark;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await PenangDistricts.instance.ensureLoaded();
  });

  group('Penang location scoping', () {
    test('Region.label composes town/district/state and tolerates legacy '
        'data', () {
      const withTown = Region(
        districtCode: 'TL',
        districtName: 'Timur Laut',
        town: 'George Town',
      );
      expect(withTown.label, 'George Town, Timur Laut, Penang');

      const withoutTown = Region(
        districtCode: 'BD',
        districtName: 'Barat Daya',
      );
      expect(withoutTown.label, 'Barat Daya, Penang');

      expect(Region.fromMap(null), isNull);
      expect(
        Region.fromMap(const {'address': 'Some legacy free text'}),
        isNull,
      );

      final rebuilt = Region.fromMap(withTown.toMap());
      expect(rebuilt?.label, withTown.label);
    });

    test(
      'PenangDistricts classifies known points and rejects the sea',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final districts = PenangDistricts.instance;
        await districts.ensureLoaded();

        expect(districts.districtCodeAt(kGeorgeTown), 'TL');
        expect(districts.districtCodeAt(const LatLng(5.2945, 100.2640)), 'BD');
        expect(districts.districtCodeAt(const LatLng(5.3991, 100.3638)), 'SPU');
        expect(districts.districtCodeAt(const LatLng(5.3630, 100.4667)), 'SPT');
        expect(districts.districtCodeAt(const LatLng(5.1656, 100.4790)), 'SPS');

        // A point out in the sea belongs to none of the 5 districts.
        expect(districts.districtCodeAt(const LatLng(5.30, 100.10)), isNull);
        expect(districts.isInPenang(const LatLng(5.30, 100.10)), isFalse);
      },
    );

    testWidgets('confirm is disabled when the centre is outside Penang', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const RegionPickerScreen(initialCenter: LatLng(5.30, 100.10)),
        ),
      );
      // No pumpAndSettle: the map's tile layer fetches over the network and
      // would otherwise stall the "settle" wait indefinitely. A couple of
      // pumps is enough for PenangDistricts.ensureLoaded() (a local asset
      // read) to resolve.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this location'),
      );
      expect(button.onPressed, isNull);
      expect(find.text('Choose a spot within Penang.'), findsOneWidget);
    });

    testWidgets('picking a district updates the dropdown and unlocks confirm', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const RegionPickerScreen(initialCenter: kGeorgeTown),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // George Town auto-classifies to Timur Laut by this point, so the
      // field already shows a value rather than the hint - target the
      // District dropdown by its label instead of assuming tree order.
      await tester.tap(districtDropdown());
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Barat Daya').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Barat Daya'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Use this location'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('provider onboarding Coverage Area drives the Penang picker', (
      tester,
    ) async {
      // The smallest host that exercises ServiceStep's real picker wiring:
      // an OnboardingController (backed by the fake repo) provided directly
      // to the widget, rather than driving the full multi-stage flow.
      final auth = FakeAuthRepository();
      final controller = OnboardingController(
        FakeOnboardingRepository(auth),
        FakeDocumentStorageRepository(),
      );
      await controller.loadFor('uid-1');

      // Tall surface: ServiceStep's card (category, coverage area, rate,
      // portfolio) is taller than the default test viewport, and the
      // picker's dropdown row needs the default width to avoid overflow.
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ChangeNotifierProvider<OnboardingController>.value(
            value: controller,
            child: const Scaffold(
              body: SingleChildScrollView(child: ServiceStep()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.data.districtCode, isNull);
      expect(find.text('Pick your coverage area in Penang'), findsOneWidget);

      await pickPenangLocation(
        tester,
        placeholder: 'Pick your coverage area in Penang',
      );

      // The structured pick landed on the provider's OnboardingData, not
      // just a display string.
      expect(controller.data.districtCode, 'BD');
      expect(controller.data.town, isNull);
      expect(controller.data.lat, isNotNull);
      expect(controller.data.lng, isNotNull);
      expect(controller.data.coverageArea, 'Barat Daya, Penang');
      expect(find.text('Barat Daya, Penang'), findsOneWidget);
    });
  });

  group('Address autofill from the map pin', () {
    test('AddressHint maps a placemark into form-ready fields', () {
      final hint = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '12',
        thoroughfare: 'Jalan Mawar 3',
        postalCode: '11900',
        locality: 'Bayan Lepas',
        subLocality: 'Batu Maung',
      ));

      expect(hint.line1, '12, Jalan Mawar 3');
      expect(hint.postcode, '11900');
      expect(hint.city, 'Bayan Lepas');
      expect(hint.isEmpty, isFalse);
    });

    test('AddressHint drops blanks and never repeats the house number', () {
      // The common Malaysian case: a street but no house number, and empty
      // strings where the geocoder had nothing.
      final noNumber = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '',
        thoroughfare: 'Lebuh Chulia',
        postalCode: '',
      ));
      expect(noNumber.line1, 'Lebuh Chulia');
      expect(noNumber.postcode, isNull);
      expect(noNumber.city, isNull);

      // Android sometimes folds the number into `street`; don't double it up.
      final folded = AddressHint.fromPlacemark(const Placemark(
        subThoroughfare: '12',
        street: '12 Jalan Mawar 3',
      ));
      expect(folded.line1, '12 Jalan Mawar 3');

      expect(const AddressHint().isEmpty, isTrue);
    });

    test('matchTown only ever returns one of the fixed town options', () {
      final hint = AddressHint.fromPlacemark(const Placemark(
        subLocality: 'george town',
        locality: 'Somewhere Else',
      ));

      // Case-insensitive, but the returned value is the canonical spelling
      // from the caller's list - never the geocoder's own string.
      expect(hint.matchTown(kPenangTowns['TL']!), 'George Town');
      // A locality that isn't a known town yields nothing rather than
      // leaking raw geocoder output into the stored region.
      expect(
        AddressHint.fromPlacemark(const Placemark(locality: 'Kuala Lumpur'))
            .matchTown(kPenangTowns['TL']!),
        isNull,
      );
    });

    testWidgets('the address sheet pre-fills from the hint', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ServiceAddressSheet(
            defaultCity: 'Bayan Lepas',
            hint: AddressHint.fromPlacemark(const Placemark(
              subThoroughfare: '12',
              thoroughfare: 'Jalan Mawar 3',
              postalCode: '11900',
              locality: 'Somewhere Else',
            )),
          ),
        ),
      ));
      await tester.pump();

      // Read the controllers rather than the rendered text: a field's hint
      // ("11900") is a Text too, so find.text would double-count it.
      expect(
        _fieldValues(tester),
        containsAll(<String>['12, Jalan Mawar 3', '11900', 'Bayan Lepas']),
      );
      // The curated town from the picker beats the geocoder's city label.
      expect(_fieldValues(tester), isNot(contains('Somewhere Else')));
      expect(
        find.textContaining('Filled in from your map pin'),
        findsOneWidget,
      );
    });

    testWidgets('an existing address always beats the hint', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ServiceAddressSheet(
            initial: const ServiceAddress(
              line1: '9, Lorong Kenari',
              postcode: '11700',
              city: 'Gelugor',
            ),
            hint: AddressHint.fromPlacemark(const Placemark(
              subThoroughfare: '12',
              thoroughfare: 'Jalan Mawar 3',
              postalCode: '11900',
            )),
          ),
        ),
      ));
      await tester.pump();

      expect(
        _fieldValues(tester),
        containsAll(<String>['9, Lorong Kenari', '11700', 'Gelugor']),
      );
      expect(_fieldValues(tester), isNot(contains('12, Jalan Mawar 3')));
      // No "check this" notice when nothing was guessed.
      expect(find.textContaining('Filled in from your map pin'), findsNothing);
    });
  });
}

/// The current text of every editable field on screen - lets a test assert
/// what a form was pre-filled with without tripping over placeholder hints,
/// which render as ordinary [Text] too.
List<String> _fieldValues(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .map((field) => field.controller.text)
    .toList();
