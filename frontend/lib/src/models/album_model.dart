class CnestAlbum {
  final String id;
  final String name;
  final String? coverFileId;
  final bool isSmart;
  final String? smartQuery;

  /// 'photo' = gallery album, 'audio' = music playlist. Same tables, two UIs.
  final String kind;
  final DateTime createdAt;
  final DateTime updatedAt;
  int fileCount;

  CnestAlbum({
    required this.id,
    required this.name,
    this.coverFileId,
    this.isSmart = false,
    this.smartQuery,
    this.kind = 'photo',
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
      'kind': kind,
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
      kind: map['kind'] ?? 'photo',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']),
      fileCount: map['file_count'] ?? 0,
    );
  }
}
