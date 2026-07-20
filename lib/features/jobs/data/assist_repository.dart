import 'package:cloud_functions/cloud_functions.dart';

/// Optional Gemini-backed suggestions for the Post-a-Job form, proxied
/// through the `suggestJobDetails` Cloud Function so the API key never ships
/// in the APK. Every method returns null when no suggestion is available
/// (offline, quota reached, unparseable reply) — the form must work
/// unchanged without them. UI/controllers depend on this interface so tests
/// can use a fake.
abstract interface class AssistRepository {
  /// Expands the requestor's rough note into a structured job description,
  /// or null when no suggestion could be made.
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
  });

  /// An indicative fair-price range (in sen) for the described job, or null.
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
  });
}

/// Firebase-backed [AssistRepository] over the `suggestJobDetails` callable.
class FirebaseAssistRepository implements AssistRepository {
  FirebaseAssistRepository({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<Map<String, dynamic>?> _call({
    required String kind,
    required String category,
    required String roughText,
  }) async {
    // Advisory only: swallow every failure into "no suggestion" — a broken
    // assist must never surface as a form error.
    try {
      final result = await _functions
          .httpsCallable('suggestJobDetails')
          .call<Map<Object?, Object?>?>({
        'kind': kind,
        'category': category,
        'roughText': roughText,
      });
      final data = result.data;
      return data == null ? null : Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
  }) async {
    final data = await _call(
        kind: 'description', category: category, roughText: roughText);
    final description = data?['description'] as String?;
    return description == null || description.isEmpty ? null : description;
  }

  @override
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
  }) async {
    final data =
        await _call(kind: 'price', category: category, roughText: description);
    final minSen = (data?['minSen'] as num?)?.toInt();
    final maxSen = (data?['maxSen'] as num?)?.toInt();
    if (minSen == null || maxSen == null) return null;
    return (minSen: minSen, maxSen: maxSen);
  }
}
