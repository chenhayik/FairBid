import 'package:cloud_functions/cloud_functions.dart';

/// What:   A post drafted from one rough note.
/// Input:  Built by FirebaseAssistRepository.suggestDraft().
/// Output: Title, category, description; the budget range is null when the model won't commit.
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

/// What:   Optional Gemini suggestions for the Post-a-Job form.
/// Input:  Callable `suggestJobDetails` (via FirebaseAssistRepository), so the API key stays server-side.
/// Output: A draft or price range, or null when unavailable (offline, quota, bad reply).
abstract interface class AssistRepository {
  /// Turns one rough note into a draft post (category inferred), or null.
  Future<JobDraft?> suggestDraft({
    required String roughText,
    String? photoUrl,
  });

  /// An indicative fair-price range in sen, or null; [photoUrl] lets the model see the job.
  Future<({int minSen, int maxSen})?> suggestPriceRange({
    required String category,
    required String description,
    String? photoUrl,
  });
}

/// What:   Cloud Functions [AssistRepository].
/// Input:  FirebaseFunctions.
/// Output: Draft suggestions from the AI callable.
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
    // Advisory only: any failure becomes "no suggestion", never a form error.
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
