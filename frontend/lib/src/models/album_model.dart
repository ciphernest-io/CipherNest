class CnestAlbum {
  final String id;
  final String name;
  final String? coverFileId;
  final bool isSmart;
  final String? smartQuery;
  final DateTime createdAt;
  final DateTime updatedAt;
  int fileCount;

  CnestAlbum({
    required this.id,
    required this.name,
    this.coverFileId,
    this.isSmart = false,
    this.smartQuery,
    required this.createdAt,
    required this.updatedAt,
    this.fileCount = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'cover_file_id': coverFileId,
      'is_smart': isSmart ? 1 : 0,
      'smart_query': smartQuery,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory CnestAlbum.fromMap(Map<String, dynamic> map) {
    return CnestAlbum(
      id: map['id'],
      name: map['name'],
      coverFileId: map['cover_file_id'],
      isSmart: map['is_smart'] == 1,
      smartQuery: map['smart_query'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']),
      fileCount: map['file_count'] ?? 0,
    );
  }
}
