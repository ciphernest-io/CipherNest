import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

class ImagePickerService {
  static final ImagePicker _picker = ImagePicker();

  // Keep for backward compatibility if needed
  static Future<Uint8List?> pickImageAsBytes() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (image == null) return null;

    return await image.readAsBytes();
  }

  // NEW: Picks either Image or Video and returns the handle
  static Future<XFile?> pickMedia() async {
    return await _picker.pickMedia();
  }
}