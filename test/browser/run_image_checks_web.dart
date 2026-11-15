import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:hakbanghero/services/run_image_browser_web.dart';
import 'package:hakbanghero/services/duel_session.dart';

void registerBrowserChecks() {
  final navigator = web.window.navigator;
  JSAny? originalShare, originalCanShare;
  late PreparedRunImage image;
  setUp(() {
    originalShare = navigator.getProperty<JSAny?>('share'.toJS);
    originalCanShare = navigator.getProperty<JSAny?>('canShare'.toJS);
    image = PreparedRunImage(Uint8List.fromList([1, 2, 3]), 'run.png');
  });
  tearDown(() {
    navigator.setProperty('share'.toJS, originalShare);
    navigator.setProperty('canShare'.toJS, originalCanShare);
    image.dispose();
  });

  test(
    'prepared file reaches the share API synchronously within the tap',
    () async {
      var called = false;
      navigator.setProperty(
        'canShare'.toJS,
        ((web.ShareData data) => true).toJS,
      );
      navigator.setProperty(
        'share'.toJS,
        ((web.ShareData data) {
          called = true;
          expect(data.files!.toDart.single.name, 'run.png');
          expect(data.files!.toDart.single.type, 'image/png');
          expect(data.files!.toDart.single.size, 3);
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
      );
      final result = image.share();
      expect(called, true, reason: 'No await may precede navigator.share.');
      expect(await result, contains('handed to the system share sheet'));
    },
  );

  test(
    'unsupported file sharing triggers a real download and retains its URL',
    () async {
      navigator.setProperty(
        'canShare'.toJS,
        ((web.ShareData data) => false).toJS,
      );
      String? url;
      final listener = ((web.Event event) {
        final target = event.target as web.HTMLAnchorElement;
        event.preventDefault();
        expect(target.download, 'run.png');
        url = target.href;
      }).toJS;
      web.document.addEventListener('click', listener);
      try {
        expect(await image.share(), contains('download requested'));
        expect(url, startsWith('blob:'));
      image.dispose();
        final response = await web.window.fetch(url!.toJS).toDart;
        final bytes = await response.arrayBuffer().toDart;
        expect(bytes.toDart.lengthInBytes, 3);
      } finally {
        web.document.removeEventListener('click', listener);
      }
    },
  );

  test('dismissed browser sharing is reported as cancellation', () async {
    navigator.setProperty('canShare'.toJS, ((web.ShareData data) => true).toJS);
    navigator.setProperty(
      'share'.toJS,
      ((web.ShareData data) {
        return JSPromise<JSAny?>(
          ((JSFunction resolve, JSFunction reject) {
            reject.callAsFunction(
              null,
              web.DOMException('Cancelled', 'AbortError'),
            );
          }).toJS,
        );
      }).toJS,
    );
    expect(await image.share(), 'Sharing cancelled.');
  });

  test(
    'refresh reuses this tab session rather than generating a new owner',
    () async {
      const uid = 'browser-stabilization-test';
      web.window.sessionStorage.removeItem('duel_session_$uid');
      try {
        expect(await restoreDuelSession(uid, 'first'), 'first');
        expect(await restoreDuelSession(uid, 'second'), 'first');
      } finally {
        web.window.sessionStorage.removeItem('duel_session_$uid');
      }
    },
  );
}
