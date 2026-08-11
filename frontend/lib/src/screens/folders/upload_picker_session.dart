import 'dart:async';

import 'package:file_picker/file_picker.dart';

import '../../widgets/folder_picker_sheet.dart';

/// One pick-then-place upload in flight. Carried by reference through every
/// picker-mode FolderBrowserScreen push, completed exactly once.
///
/// The result is a [FolderPickResult], NOT a bare folder id: a null FUTURE
/// value means the user cancelled, while a result whose folderId is null
/// means "upload to the vault root" — a `Completer<String?>` could not
/// tell those apart.
class UploadPickerSession {
  final List<PlatformFile> files;

  /// Footer display: '3 files' or the single file's name.
  final String label;

  final Completer<FolderPickResult?> destination =
      Completer<FolderPickResult?>();

  UploadPickerSession({required this.files, required this.label});
}

/// RouteSettings name every picker-mode route carries — 'Upload here' and
/// 'Cancel' popUntil past ALL of them in one motion.
const String kUploadPickerRouteName = 'upload-picker';
