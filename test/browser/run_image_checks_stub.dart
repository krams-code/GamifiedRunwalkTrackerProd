import 'package:flutter_test/flutter_test.dart';

void registerBrowserChecks() {
  test(
    'browser export checks require --platform chrome',
    () {},
    skip: 'Run test/run_image_browser_test.dart with --platform chrome.',
  );
}
