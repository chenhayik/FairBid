/// Where a face sits in a photo, as fractions (0-1) of the image so it stays
/// valid at any resolution. [aspect] is image width / height.
class FaceBox {
  const FaceBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.aspect,
  });

  final double left, top, width, height, aspect;

  Map<String, dynamic> toMap() => {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
        'aspect': aspect,
      };

  /// Null when [map] is absent or incomplete, so callers fall back to the
  /// full image.
  static FaceBox? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    double? read(String k) => (map[k] as num?)?.toDouble();
    final left = read('left'), top = read('top');
    final width = read('width'), height = read('height');
    final aspect = read('aspect');
    if (left == null ||
        top == null ||
        width == null ||
        height == null ||
        aspect == null ||
        width <= 0 ||
        height <= 0 ||
        aspect <= 0) {
      return null;
    }
    return FaceBox(
        left: left, top: top, width: width, height: height, aspect: aspect);
  }

  @override
  bool operator ==(Object other) =>
      other is FaceBox &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.aspect == aspect;

  @override
  int get hashCode => Object.hash(left, top, width, height, aspect);
}
