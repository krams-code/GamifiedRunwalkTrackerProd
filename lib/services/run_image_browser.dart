import 'dart:typed_data';

class PreparedRunImage {
  PreparedRunImage(Uint8List png, String name);
  Future<String> share() => throw UnsupportedError('Browser export');
  String save() => throw UnsupportedError('Browser export');
  String open() => throw UnsupportedError('Browser export');
  void dispose() {}
}
