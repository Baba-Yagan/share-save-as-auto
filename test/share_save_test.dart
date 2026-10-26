import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_save/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appChannel = MethodChannel('share_save/app');
const _codec = StandardMethodCodec();

const String _defaultDir =
    '/storage/emulated/0/Android/data/com.example.share_save/files';

/// Pretends to be the platform side of `share_save/app`.
typedef _CallSwitch = Future<Object?> Function(MethodCall call);

Future<Object?> dispatchToApp(MethodCall call) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _appChannel.name,
          _codec.encodeMethodCall(call),
          (ByteData? reply) {},
        );

void _stubAppChannel(_CallSwitch switcher) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_appChannel, switcher);
}

void stubIdleStatus({
  bool canWrite = true,
  void Function(String method)? onCall,
}) {
  _stubAppChannel((call) {
    onCall?.call(call.method);
    return switch (call.method) {
      'getSaveDirStatus' => Future.value(<String, Object?>{
          'defaultDir': _defaultDir,
          'treePath': _stubTreePathFor(call.arguments),
        }),
      'canWrite' => Future.value(canWrite),
      'getPendingShare' => Future.value(null),
      _ => Future.value(null),
    };
  });
}

Object? _stubTreePathFor(Object? arguments) {
  final map = Map<String, Object?>.from(arguments! as Map<Object?, Object?>);
  return (map['treeUri'] as String?) == null ? null : 'Documents/share-save';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('fileStamp', () {
    test('formats yyyy-MM-dd-HH-mm-ss with zero padding', () {
      expect(
        fileStamp(DateTime(2026, 10, 26, 7, 3, 5)),
        '2026-10-26-07-03-05',
      );
      expect(
        fileStamp(DateTime(2026, 1, 2, 3, 4, 9)),
        '2026-01-02-03-04-09',
      );
    });
  });

  group('ShareRequest', () {
    test('parses a text share payload', () {
      final request = ShareRequest.fromMap(<String, Object?>{
        'type': 'text',
        'text': 'Hello there',
      });
      expect(request.isTextShare, isTrue);
      expect(request.text, 'Hello there');
      expect(request.streams, isEmpty);
    });

    test('parses a stream share payload with several items', () {
      final request = ShareRequest.fromMap(<String, Object?>{
        'type': 'stream',
        'streams': [
          {'uri': 'content://a/1', 'mime': 'image/png'},
          {'uri': 'content://a/2', 'mime': '*/*'},
        ],
      });
      expect(request.isTextShare, isFalse);
      expect(request.streams, hasLength(2));
      expect(request.streams[0].mime, 'image/png');
      expect(request.streams[1].uri, 'content://a/2');
    });

    test('drops null stream entries and tolerates an empty payload', () {
      final request = ShareRequest.fromMap(<String, Object?>{
        'type': 'stream',
        'streams': <Object?>[null],
      });
      expect(request.streams, isEmpty);
      expect(request.isTextShare, isFalse);
    });

    test('carries title, subject, action, mime and sender metadata', () {
      final request = ShareRequest.fromMap(<String, Object?>{
        'type': 'text',
        'text': 'Hello',
        'title': 'T',
        'subject': 'S',
        'action': 'android.intent.action.SEND',
        'mime': 'text/plain',
        'sender': 'com.example.sender',
      });
      expect(request.isTextShare, isTrue);
      expect(request.title, 'T');
      expect(request.subject, 'S');
      expect(request.action, 'android.intent.action.SEND');
      expect(request.mimeType, 'text/plain');
      expect(request.senderPackage, 'com.example.sender');
    });
  });

  group('ShareSaveHomeScreen', () {
    /// Flush the async startup chain: prefs load, dir status, grant check.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets('shows the default save directory and stays open when '
        'started from the launcher', (tester) async {
      var closeCalls = 0;
      stubIdleStatus(canWrite: true, onCall: (method) {
        if (method == 'closeActivity') closeCalls++;
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      expect(find.text('Save directory'), findsOneWidget);
      expect(find.text(_defaultDir), findsOneWidget);
      expect(find.text('Write permission: granted'), findsOneWidget);
      // Launcher start: no share, so nothing may finish the activity.
      expect(closeCalls, 0);
    });

    testWidgets(
        'reports a not-granted permission label when the tree is revoked',
        (tester) async {
      _stubAppChannel((call) => switch (call.method) {
            'getSaveDirStatus' => Future.value(<String, Object?>{
                'defaultDir': _defaultDir,
                'treePath': 'Documents/share-save',
              }),
            'canWrite' => Future.value(false),
            'getPendingShare' => Future.value(null),
            _ => Future.value(null),
          });
      SharedPreferences.setMockInitialValues({
        persistedTreeUriKey: 'content://doc/tree/primary%3ADocuments%2Fshare-save',
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      expect(find.text('Documents/share-save'), findsOneWidget);
      expect(find.text('Write permission: not granted'), findsOneWidget);
    });

    testWidgets('saves a text share as a JSON document, then closes',
        (tester) async {
      var closeCalls = 0;
      var saveTextCalls = 0;
      String? savedJson;
      String? savedBaseName;
      String? savedMime;
      String? savedExt;
      const savedName = '2026-10-26-07-03-09.json';
      _stubAppChannel((call) {
        if (call.method == 'closeActivity') {
          closeCalls++;
          return Future.value(null);
        }
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(true);
          case 'getPendingShare':
            return Future.value(<String, Object?>{
              'type': 'text',
              'text': 'Hello there',
              'title': 'A shared note',
              'subject': 'subject from the mail app',
              'action': 'android.intent.action.SEND',
              'mime': 'text/plain',
              'sender': 'com.android.chrome',
            });
          case 'saveText':
            saveTextCalls++;
            savedJson = call.arguments['text'] as String?;
            savedBaseName = call.arguments['baseName'] as String?;
            savedMime = call.arguments['mime'] as String?;
            savedExt = call.arguments['ext'] as String?;
            return Future.value(savedName);
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      expect(saveTextCalls, 1);
      expect(savedMime, 'application/json');
      expect(savedExt, '.json');
      expect(
        savedBaseName,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$')),
      );
      final decoded = jsonDecode(savedJson!) as Map<String, Object?>;
      expect(decoded['text'], 'Hello there');
      expect(decoded['title'], 'A shared note');
      expect(decoded['subject'], 'subject from the mail app');
      expect(decoded['action'], 'android.intent.action.SEND');
      expect(decoded['mimeType'], 'text/plain');
      expect(decoded['sender'], 'com.android.chrome');
      expect(decoded['savedAt'], savedBaseName);
      // Status line reports the saved file...
      expect(find.text('Saved $savedName').hitTestable(), findsWidgets);
      // ...and the activity closes right after the save.
      expect(closeCalls, 1);
    });

    testWidgets('a minimal text share (PROCESS_TEXT) omits missing fields',
        (tester) async {
      String? savedJson;
      _stubAppChannel((call) {
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(true);
          case 'getPendingShare':
            return Future.value(<String, Object?>{
              'type': 'text',
              'text': 'selected words',
              'action': 'android.intent.action.PROCESS_TEXT',
              'mime': 'text/plain',
            });
          case 'saveText':
            savedJson = call.arguments['text'] as String?;
            return Future.value(
              '${call.arguments['baseName']}.json',
            );
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      final decoded = jsonDecode(savedJson!) as Map<String, Object?>;
      expect(decoded['text'], 'selected words');
      expect(decoded.containsKey('title'), isFalse);
      expect(decoded.containsKey('subject'), isFalse);
      expect(decoded.containsKey('sender'), isFalse);
      expect(decoded['action'], 'android.intent.action.PROCESS_TEXT');
      expect(decoded['mimeType'], 'text/plain');
      expect(decoded['savedAt'], isNotNull);
    });

    testWidgets('the screen follows the system light/dark setting',
        (tester) async {
      stubIdleStatus();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(
        () => tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light,
      );
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      final scaffoldFinder = find.byType(Scaffold);
      expect(
        Theme.of(tester.element(scaffoldFinder)).brightness,
        Brightness.light,
      );
      // Same seed for both schemes: only the brightness differs from dark.
      expect(
        Theme.of(tester.element(scaffoldFinder)).colorScheme,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF7CB342),
          brightness: Brightness.light,
        ),
      );

      // Flip the system setting: ThemeMode.system must resolve the dark
      // variant of the same seed (rebuild lets the framework re-read the
      // platform brightness; pumpAndSettle absorbs the AnimatedTheme run).
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(const ShareSaveApp());
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(
        Theme.of(tester.element(scaffoldFinder)).brightness,
        Brightness.dark,
      );
      expect(
        Theme.of(tester.element(scaffoldFinder)).colorScheme,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF7CB342),
          brightness: Brightness.dark,
        ),
      );

      // The single screen stays readable in light mode (colorScheme roles only).
      expect(find.text('Save directory'), findsOneWidget);
      expect(find.text('Write permission: granted'), findsOneWidget);
    });

    testWidgets('shows a clear error when the directory grant is revoked, '
        'and still closes after a short delay', (tester) async {
      var closeCalls = 0;
      final events = <String>[];
      _stubAppChannel((call) {
        if (call.method == 'closeActivity') {
          closeCalls++;
          events.add(call.method);
          return Future.value(null);
        }
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(false);
          case 'getPendingShare':
            return Future.value(<String, Object?>{
              'type': 'text',
              'text': 'Never written',
            });
          case 'saveText':
            fail('must not attempt a save without a granted directory');
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      expect(
        find.text(
          'No write permission for $_defaultDir. '
          'Tap "Choose save folder…" and pick the directory again.',
        ).hitTestable(),
        findsWidgets,
      );
      // The error is shown first: no premature close while it is visible.
      expect(closeCalls, 0);

      // Advance past the error-display delay: the activity closes.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 20));
      expect(closeCalls, 1);
      expect(events, ['closeActivity']); // and still no save attempt
    });

    testWidgets('shows a save failure briefly, then closes after the delay',
        (tester) async {
      var closeCalls = 0;
      _stubAppChannel((call) {
        if (call.method == 'closeActivity') {
          closeCalls++;
          return Future.value(null);
        }
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(true);
          case 'getPendingShare':
            return Future.value(<String, Object?>{
              'type': 'text',
              'text': 'Doomed note',
            });
          case 'saveText':
            return Future<Object?>.error(
              PlatformException(code: 'saveFailed', message: 'disk full'),
            );
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      // The error is readable while the screen is still up.
      expect(find.text('Save failed: disk full').hitTestable(), findsWidgets);
      expect(closeCalls, 0, reason: 'the error must be shown before closing');

      // Advance past the error-display delay: the activity still closes.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 20));
      expect(closeCalls, 1);
    });

    testWidgets('a share without saveable content closes after the delay',
        (tester) async {
      var closeCalls = 0;
      _stubAppChannel((call) {
        if (call.method == 'closeActivity') {
          closeCalls++;
          return Future.value(null);
        }
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(true);
          case 'getPendingShare':
            return Future.value(<String, Object?>{
              'type': 'text',
              'text': '', // empty text: nothing saveable
            });
          case 'saveText':
            fail('must not attempt a save without saveable content');
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      await settle(tester);

      expect(
        find.text('Nothing saveable in this share.').hitTestable(),
        findsWidgets,
      );
      expect(closeCalls, 0);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(closeCalls, 1);
    });
  });

  group('share-forwarding plumbing', () {
    testWidgets('a warm-start share (onShareIntent) is saved, then closes',
        (tester) async {
      final savedNames = <String>[];
      final events = <String>[];
      String? savedBaseName;
      _stubAppChannel((call) {
        if (call.method == 'closeActivity') {
          events.add(call.method);
          return Future.value(null);
        }
        if (call.method == 'saveStream') {
          events.add(call.method);
          final args = call.arguments as Map<Object?, Object?>;
          final index = args['baseIndex'] as int;
          savedBaseName = args['baseName'] as String?;
          savedNames.add(
            '${args['baseName']}${index == 0 ? '' : '-${index + 1}'}.png',
          );
          return Future.value(savedNames.last);
        }
        switch (call.method) {
          case 'getSaveDirStatus':
            return Future.value(<String, Object?>{
              'defaultDir': _defaultDir,
              'treePath': null,
            });
          case 'canWrite':
            return Future.value(true);
          case 'getPendingShare':
            return Future.value(null);
          default:
            return Future.value(null);
        }
      });
      await tester.pumpWidget(const ShareSaveApp());
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      await dispatchToApp(const MethodCall('onShareIntent', <String, Object?>{
        'type': 'stream',
        'streams': [
          <String, Object?>{'uri': 'content://share/one', 'mime': 'image/png'},
          <String, Object?>{'uri': 'content://share/two', 'mime': 'image/png'},
        ],
      }));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(savedBaseName,
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$')));
      expect(savedNames, hasLength(2));
      expect(savedNames[0], '$savedBaseName.png');
      expect(savedNames[1], '$savedBaseName-2.png');
      expect(
        find.text('Saved ${savedNames[0]}, ${savedNames[1]}').hitTestable(),
        findsWidgets,
      );
      // Warm start (singleTask / onNewIntent): save first, then close.
      expect(events, ['saveStream', 'saveStream', 'closeActivity']);
    });
  });
}
