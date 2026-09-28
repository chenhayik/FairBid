import 'package:cloud_functions/cloud_functions.dart';

/// A whole post drafted from one rough note. The budget range is null when
/// the model would not commit to one.
class JobDraft {
  const JobDraft({
    required this.title,
    required this.category,
    required this.description,
    this.minSen,
    this.maxSen,
  });

  final String title;
  final String category;
  final String description;
  final int? minSen;
  final int? maxSen;
}

/// Optional Gemini-backed suggestions for the Post-a-Job form, proxied
/// through the `suggestJobDetails` Cloud Function so the API key never ships
/// in the APK. Every method returns null when no suggestion is available
/// (offline, quota reached, unparseable reply) - the form must work
/// unchanged without them. UI/controllers depend on this interface so tests
/// can use a fake.
abstract interface class AssistRepository {
  /// Turns one rough note into a whole draft post - title, category,
  /// description and an indicative budget - or null when none is available.
  /// The category is inferred here rather than asked for first.
  Future<JobDraft?> suggestDraft({
    required String roughText,
    String? photoUrl,
  });

  /// Expands the requestor's rough note into a structured job description,
  /// or null when no suggestion could be made. [photoUrl], when given, lets
  /// the model factor in a photo of the job.
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
    String? photoUrl,
  });

  /// An indicative fair-price range (in sen) for the described job, or null.
  /// [photoUrl], when given, lets the model factor in a photo of the job.
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
    String? photoUrl,
  });
}

/// Firebase-backed [AssistRepository] over the `suggestJobDetails` callable.
class FirebaseAssistRepository implements AssistRepository {
  FirebaseAssistRepository({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<Map<String, dynamic>?> _call({
    required String kind,
    String category = '',
    required String roughText,
    String? photoUrl,
  }) async {
    // Advisory only: swallow every failure into "no suggestion" - a broken
    // assist must never surface as a form error.
    try {
      final result = await _functions
          .httpsCallable('suggestJobDetails')
          .call<Map<Object?, Object?>?>({
        'kind': kind,
        'category': category,
        'roughText': roughText,
        'photoUrl': ?photoUrl,
      });
      final data = result.data;
      return data == null ? null : Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<JobDraft?> suggestDraft({
    required String roughText,
    String? photoUrl,
  }) async {
    final data =
        await _call(kind: 'draft', roughText: roughText, photoUrl: photoUrl);
    final title = data?['title'] as String?;
    final category = data?['category'] as String?;
    final description = data?['description'] as String?;
    if (title == null || category == null || description == null) return null;
    return JobDraft(
      title: title,
      category: category,
      description: description,
      minSen: (data?['minSen'] as num?)?.toInt(),
      maxSen: (data?['maxSen'] as num?)?.toInt(),
    );
  }

  @override
  Future<String?> suggestDescription({
    required String category,
    required String roughText,
    String? photoUrl,
  }) async {
    final data = await _call(
        kind: 'description',
        category: category,
        roughText: roughText,
        photoUrl: photoUrl);
    final description = data?['description'] as String?;
    return description == null || description.isEmpty ? null : description;
  }

  @override
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
    String? photoUrl,
  }) async {
    final data = await _call(
        kind: 'price',
        category: category,
        roughText: description,
        photoUrl: photoUrl);
    final minSen = (data?['minSen'] as num?)?.toInt();
    final maxSen = (data?['maxSen'] as num?)?.toInt();
    if (minSen == null || maxSen == null) return null;
    return (minSen: minSen, maxSen: maxSen);
  }
}
