import 'package:flutter_test/flutter_test.dart';

import 'package:share_save/main.dart';

void main() {
  test('fileStamp formats the local timestamp as yyyy-MM-dd-HH-mm-ss', () {
    expect(fileStamp(DateTime(2026, 10, 26, 9, 5, 7)), '2026-10-26-09-05-07');
    expect(fileStamp(DateTime(2026, 1, 2, 0, 0, 0)), '2026-01-02-00-00-00');
    expect(fileStamp(DateTime(2026, 12, 31, 23, 59, 59)), '2026-12-31-23-59-59');
  });

  test('ShareRequest.fromMap parses a text/URL share', () {
    final request = ShareRequest.fromMap(<String, Object?>{
      'type': 'text',
      'text': 'https://example.com/',
    });
    expect(request.isTextShare, isTrue);
    expect(request.text, 'https://example.com/');
    expect(request.streams, isEmpty);
  });

  test('ShareRequest.fromMap treats blank text as nothing saveable', () {
    final request = ShareRequest.fromMap(<String, Object?>{'type': 'text', 'text': ''});
    expect(request.isTextShare, isFalse);
    expect(request.streams, isEmpty);
  });

  test('ShareRequest.fromMap parses multiple file streams', () {
    final request = ShareRequest.fromMap(<String, Object?>{
      'type': 'stream',
      'streams': <Object?>[
        <String, Object?>{'uri': 'content://media/a', 'mime': 'image/png'},
        <String, Object?>{'uri': 'content://media/b', 'mime': 'application/pdf'},
        <String, Object?>{'uri': 'content://media/c'},
      ],
    });
    expect(request.isTextShare, isFalse);
    expect(request.streams, hasLength(3));
    expect(request.streams[0].mime, 'image/png');
    expect(request.streams[1].mime, 'application/pdf');
    expect(request.streams[2].mime, '*/*');
  });

  test('ShareRequest.fromMap parses the text-share intent metadata', () {
    final request = ShareRequest.fromMap(<String, Object?>{
      'type': 'text',
      'text': 'https://example.com/',
      'title': 'Example page',
      'subject': 'fyi',
      'action': 'android.intent.action.SEND',
      'mime': 'text/plain',
      'sender': 'com.android.chrome',
    });
    expect(request.isTextShare, isTrue);
    expect(request.title, 'Example page');
    expect(request.subject, 'fyi');
    expect(request.action, 'android.intent.action.SEND');
    expect(request.mimeType, 'text/plain');
    expect(request.senderPackage, 'com.android.chrome');
  });

  test('ShareRequest.fromMap leaves absent metadata null', () {
    final request = ShareRequest.fromMap(<String, Object?>{
      'type': 'text',
      'text': 'plain words',
    });
    expect(request.title, isNull);
    expect(request.subject, isNull);
    expect(request.action, isNull);
    expect(request.mimeType, isNull);
    expect(request.senderPackage, isNull);
  });
}
