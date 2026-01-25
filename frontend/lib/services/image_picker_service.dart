import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class ImagePickerService {
  static final ImagePicker _picker = ImagePicker();

  static Future<Uint8List?> pickImageAsBytes() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (image == null) return null;

    return await image.readAsBytes();
  }
}
