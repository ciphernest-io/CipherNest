/// Extracts a MediaStore numeric id from the content URIs Android pickers
/// hand back. Pure string logic — unit-tested.
///
/// Two families resolve to a MediaStore id:
///  * `content://media/external/video/media/123` — the direct MediaStore
///    URI (camera-adjacent pickers).
///  * `content://com.android.providers.media.documents/document/video%3A123`
///    — the Storage Access Framework's media-documents provider, which is
///    what file_picker's custom-extension mode actually returns. Its
///    document id URL-encodes `type:id`.
///
/// Anything else (externalstorage documents, downloads paths, cloud
/// providers) has no MediaStore id — returns null.
library;

String? extractMediaStoreId(String uri) {
  if (uri.startsWith('content://media/')) {
    final trailing = uri.split('/').last;
    // Guard against query strings / fragments picked up by trailing.
    return RegExp(r'^\d+').firstMatch(trailing)?.group(0);
  }

  const mediaDocsPrefix =
      'content://com.android.providers.media.documents/document/';
  if (uri.startsWith(mediaDocsPrefix)) {
    final String docId;
    try {
      docId = Uri.decodeComponent(uri.substring(mediaDocsPrefix.length));
    } catch (_) {
      return null; // malformed percent-encoding
    }
    final sep = docId.indexOf(':');
    if (sep <= 0) return null;
    final kind = docId.substring(0, sep);
    // `msf` = MediaStore file ids served through the downloads provider
    // on API 29+ — still valid MediaStore ids.
    const kinds = {'image', 'video', 'audio', 'msf'};
    if (!kinds.contains(kind)) return null;
    final id = docId.substring(sep + 1);
    if (id.isEmpty || !RegExp(r'^\d+$').hasMatch(id)) return null;
    return id;
  }

  return null;
}
