class Collection {
  final String id;
  final String name;
  final String? description;
  final String type;
  final String visibility;
  final int itemCount;
  final List<String> posterPaths;

  const Collection({
    required this.id,
    required this.name,
    this.description,
    required this.type,
    required this.visibility,
    required this.itemCount,
    required this.posterPaths,
  });

  factory Collection.fromJson(Map<String, dynamic> json) {
    return Collection(
      id: json['id'].toString(),
      name: json['name'] as String,
      description: json['description'] as String?,
      type: json['type'] as String,
      visibility: json['visibility'] as String,
      itemCount: json['itemCount'] as int? ?? 0,
      posterPaths: (json['posterPaths'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  bool get isSmart => type == 'smart';
  bool get isManual => type == 'manual';
  bool get isShared => visibility == 'shared';
}
