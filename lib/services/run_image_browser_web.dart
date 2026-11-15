import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

class PreparedRunImage {
  late final web.File _file;
  late final String _url;
  final String _name;
  bool _disposed = false;

  PreparedRunImage(Uint8List png, this._name) {
    _file = web.File(
      [png.toJS].toJS,
      _name,
      web.FilePropertyBag(type: 'image/png'),
    );
    _url = web.URL.createObjectURL(_file);
  }

  Future<String> share() {
    final data = web.ShareData(
      files: [_file].toJS,
      title: 'HakbangHero run summary',
    );
    try {
      if (!web.window.navigator.canShare(data)) return Future.value(save());
      // No asynchronous file conversion between the user's tap and share().
      return web.window.navigator
          .share(data)
          .toDart
          .then(
            (_) =>
                'Image handed to the system share sheet. Publication is not confirmed.',
            onError: (Object error) {
              try {
                if ((error as web.DOMException).name == 'AbortError')
                  return 'Sharing cancelled.';
              } catch (_) {}
              return 'Sharing was not completed. Tap Save Image or Open Image.';
            },
          );
    } catch (_) {
      return Future.value(save());
    }
  }

  String save() {
    final link = web.HTMLAnchorElement()
      ..href = _url
      ..download = _name
      ..target = '_blank';
    web.document.body?.append(link);
    link.click();
    link.remove();
    return 'Image download requested. Check Downloads, or tap Open Image to save it using Safari.';
  }

  String open() {
    final opened = web.window.open(_url, '_blank');
    return opened == null
        ? 'The browser blocked opening the image. Allow pop-ups and tap Open Image again.'
        : 'Image opened. Use the browser share or image menu to save it to Files or Photos.';
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Safari can consume the URL after the sheet closes or a new tab opens.
    // Retain it briefly, then release its backing image memory.
    Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(_url));
  }
}
