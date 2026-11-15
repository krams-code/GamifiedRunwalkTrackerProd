import 'browser/run_image_checks_stub.dart'
    if (dart.library.js_interop) 'browser/run_image_checks_web.dart';

void main() => registerBrowserChecks();
