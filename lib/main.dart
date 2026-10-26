import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _appChannel = MethodChannel('share_save/app');

/// shared_preferences key for the persisted SAF tree URI (public for tests).
const persistedTreeUriKey = 'save_tree_uri';

/// Formats a local [DateTime] as the deterministic, collision-free base name
/// used for saved shares: `yyyy-MM-dd-HH-mm-ss`.
String fileStamp(DateTime local) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${two(local.month)}-${two(local.day)}-${two(local.hour)}-'
      '${two(local.minute)}-${two(local.second)}';
}

/// One incoming share, as forwarded by MainActivity (`getPendingShare` /
/// `onShareIntent`). Exactly one of [text] / [streams] carries data.
class SharedStreamItem {
  const SharedStreamItem({required this.uri, required this.mime});

  factory SharedStreamItem.fromMap(Object? raw) {
    final map = Map<String, Object?>.from(raw! as Map<Object?, Object?>);
    return SharedStreamItem(
      uri: map['uri'] as String? ?? '',
      mime: map['mime'] as String? ?? '*/*',
    );
  }

  final String uri;
  final String mime;
}

class ShareRequest {
  const ShareRequest({
    required this.text,
    required this.streams,
    this.title,
    this.subject,
    this.action,
    this.mimeType,
    this.senderPackage,
  });

  factory ShareRequest.fromMap(Object? raw) {
    final map = Map<String, Object?>.from(raw! as Map<Object?, Object?>);
    return ShareRequest(
      text: map['text'] as String?,
      title: map['title'] as String?,
      subject: map['subject'] as String?,
      action: map['action'] as String?,
      mimeType: map['mime'] as String?,
      senderPackage: map['sender'] as String?,
      streams: ((map['streams'] as List<Object?>?) ?? const [])
          .where((item) => item != null)
          .map(SharedStreamItem.fromMap)
          .toList(),
    );
  }

  final String? text;

  /// Optional context carried by the intent: EXTRA_TITLE / EXTRA_SUBJECT,
  /// the action name, the MIME type and the sending app (via referrer).
  final String? title;
  final String? subject;
  final String? action;
  final String? mimeType;
  final String? senderPackage;

  final List<SharedStreamItem> streams;

  bool get isTextShare => streams.isEmpty && text != null && text!.isNotEmpty;
}

void main() {
  runApp(const ShareSaveApp());
}

const _seedColor = Color(0xFF7CB342);

/// Delay before auto-closing after a failed share save (show the error first).
const _closeAfterErrorDelay = Duration(seconds: 3);

class ShareSaveApp extends StatelessWidget {
  const ShareSaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'share-save',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const ShareSaveHomeScreen(),
    );
  }
}

/// The single screen of the app. It shows the chosen save directory (and
/// whether writing into it is allowed) plus the folder picker button.
class ShareSaveHomeScreen extends StatefulWidget {
  const ShareSaveHomeScreen({super.key});

  @override
  State<ShareSaveHomeScreen> createState() => _ShareSaveHomeScreenState();
}

class _ShareSaveHomeScreenState extends State<ShareSaveHomeScreen> {
  /// The persisted SAF tree URI, or null (then the app-external files dir is used).
  String? _persistenceTreeUri;
  String _dirDisplay = '';
  bool _canWrite = false;
  bool _saving = false;
  ShareRequest? _pendingShareRequest;
  String _status = 'Ready. Share text or files from another app to save them here.';

  @override
  void initState() {
    super.initState();
    _appChannel.setMethodCallHandler((call) async {
      if (call.method == 'onShareIntent') {
        return _handleShareRequest(ShareRequest.fromMap(call.arguments));
      }
      throw MissingPluginException('Unknown method ${call.method}');
    });
    _restoreSavedTreeThenWatchForShares();
  }

  /// Startup order: refresh dir + grants, then pick up any share that launched
  /// the app cold (pending intent was buffered in MainActivity).
  Future<void> _restoreSavedTreeThenWatchForShares() async {
    final preferences = await SharedPreferences.getInstance();
    _persistenceTreeUri = preferences.getString(persistedTreeUriKey);
    await _refreshStatus();
    final pending = await _appChannel.invokeMethod<Object?>('getPendingShare');
    if (pending != null) {
      await _handleShareRequest(ShareRequest.fromMap(pending));
    }
  }

  Future<void> _refreshStatus() async {
    final status = Map<String, Object?>.from(
      (await _appChannel.invokeMethod<Object?>('getSaveDirStatus', {
        'treeUri': _persistenceTreeUri,
      }))! as Map<Object?, Object?>,
    );
    final defaultDir = (status['defaultDir'] as String?) ?? '(unknown)';
    final dirDisplay = (status['treePath'] as String?) ?? defaultDir;
    final writable = await _appChannel.invokeMethod<bool>('canWrite', {
      'treeUri': _persistenceTreeUri,
    });
    if (!mounted) return;
    setState(() {
      _dirDisplay = dirDisplay;
      _canWrite = writable ?? false;
    });
  }

  Future<void> _pickDirectory() async {
    try {
      final picked = await _appChannel.invokeMethod<String>('pickTree');
      if (picked == null) {
        return; // sheet cancelled; keep previous directory
      }
      _persistenceTreeUri = picked;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(persistedTreeUriKey, picked);
      if (!mounted) return;
      await _refreshStatus();
      if (!mounted) return;
      setState(() {
        _status = 'Save directory set: $_dirDisplay';
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = _messageFor(error);
      });
    }
    if (!mounted) return;
    // Save a share that arrived before a directory was chosen.
    final pending = _pendingShareRequest;
    _pendingShareRequest = null;
    if (pending != null) {
      await _handleShareRequest(pending);
    }
    _showSnackBar(_status);
  }

  /// Saves one incoming share (text or streams) into the current directory.
  /// Text shares are written as a JSON document capturing everything the
  /// intent carries. When the activity was launched by a share intent, the
  /// app auto-closes afterwards (immediately on success; on failure the error
  /// is shown briefly and the close happens after a short delay —
  /// see [_closeAfterErrorDelay]). It stays open when started from the
  /// launcher, i.e. this method is never called in that case.
  Future<void> _handleShareRequest(ShareRequest request) async {
    await _refreshStatus();
    if (!_canWrite) {
      // Remember the share so it can be saved once the user picks a folder
      // (if the app is still open by then).
      _pendingShareRequest = request;
      _fail(
        'No write permission for $_dirDisplay. '
        'Tap "Choose save folder…" and pick the directory again.',
      );
      await _closeActivity(afterDelay: true);
      return;
    }
    if (!request.isTextShare && request.streams.isEmpty) {
      setState(() => _status = 'Nothing saveable in this share.');
      await _closeActivity(afterDelay: true);
      return;
    }
    setState(() => _saving = true);
    final stamp = fileStamp(DateTime.now());
    final saved = <String>[];
    try {
      if (request.isTextShare) {
        // The .json carries everything the intent provides, in a stable,
        // human-readable order (fields missing from the intent are omitted).
        final payload = <String, Object?>{
          'text': request.text,
          if (request.title != null) 'title': request.title,
          if (request.subject != null) 'subject': request.subject,
          if (request.action != null) 'action': request.action,
          if (request.mimeType != null) 'mimeType': request.mimeType,
          if (request.senderPackage != null) 'sender': request.senderPackage,
          'savedAt': stamp,
        };
        final name = await _appChannel.invokeMethod<String>('saveText', {
          'treeUri': _persistenceTreeUri,
          'baseName': stamp,
          'mime': 'application/json',
          'ext': '.json',
          'text': jsonEncode(payload),
        });
        saved.add(name ?? '$stamp.json');
      } else {
        for (final (index, item) in request.streams.indexed) {
          final name = await _appChannel.invokeMethod<String>('saveStream', {
            'treeUri': _persistenceTreeUri,
            'streamUri': item.uri,
            'mime': item.mime,
            'baseName': stamp,
            'baseIndex': index,
          });
          saved.add(name ?? '$stamp${index == 0 ? '' : '-${index + 1}'}.bin');
        }
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      _fail(_messageFor(error));
      await _closeActivity(afterDelay: true);
      return;
    } finally {
      _saving = false;
    }
    if (!mounted) return;
    setState(() => _status = 'Saved ${saved.join(', ')}');
    await _closeActivity(); // share launched: hand control straight back
  }

  /// Finishes the hosting activity so the user lands back in the sharing app
  /// without pressing back. Never called for launcher starts.
  Future<void> _closeActivity({bool afterDelay = false}) async {
    if (afterDelay) {
      await Future<void>.delayed(_closeAfterErrorDelay);
      if (!mounted) return;
    }
    try {
      await _appChannel.invokeMethod<Object?>('closeActivity');
    } on Exception catch (_) {
      // PlatformException, MissingPluginException, engine-detaching: closing
      // is best-effort; keep whatever status is on screen and stay open.
    }
  }

  String _messageFor(PlatformException error) {
    switch (error.code) {
      case 'noWritePermission':
        return 'No write permission for $_dirDisplay. '
            'Tap "Choose save folder…" and pick the directory again.';
      case 'pickerUnavailable':
        return 'The system folder picker is not available: '
            '${error.message ?? error.code}';
      default:
        return 'Save failed: ${error.message ?? error.code}';
    }
  }

  void _fail(String message) {
    _refreshStatus(); // re-check the grant so the UI reflects revocation
    setState(() => _status = message);
    _showSnackBar(message, error: true);
  }

  void _showSnackBar(String message, {bool error = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: error
              ? TextStyle(color: colorScheme.onErrorContainer)
              : null,
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? colorScheme.errorContainer : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('share-save')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Save directory', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Text(_dirDisplay),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          _canWrite ? Icons.check_circle_outline : Icons.error_outline,
                          color: _canWrite
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Write permission: ${_canWrite ? 'granted' : 'not granted'}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _pickDirectory,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose save folder…'),
            ),
            const Spacer(),
            if (_saving) const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 8),
            Text('Status', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
