import 'dart:convert';
import 'dart:io';

import 'package:fairbid/core/util/mykad_number.dart';
import 'package:flutter_test/flutter_test.dart';

// The shared vectors that also pin functions/mykad.js (`npm test`).
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/mykad_vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final today = DateTime.parse(fixture['today'] as String);

  for (final raw in fixture['vectors'] as List) {
    final v = raw as Map<String, dynamic>;
    test('MyKad vector: ${v['name']}', () {
      final input = v['input'] as String;
      final expected = (v['issues'] as List).cast<String>();
      expect(MyKadNumber.issues(input, today: today), expected);

      final parsed = MyKadNumber.parse(input, today: today);
      if (expected.isNotEmpty) {
        expect(parsed, isNull);
        return;
      }
      expect(parsed, isNotNull);
      expect(parsed!.normalized, v['normalized']);
      expect(parsed.masked, v['masked']);
      expect(parsed.dateOfBirth.toIso8601String().substring(0, 10), v['dob']);
      expect(parsed.isMale, v['isMale']);
      expect(parsed.pbNeedsReview, v['pbNeedsReview']);
    });
  }

  test('formatted puts the dashes back', () {
    final n = MyKadNumber.parse('900101071234', today: today)!;
    expect(n.formatted, '900101-07-1234');
    expect(n.pbCode, '07');
  });
}
