import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'updater.dart';

class UpdateMenu extends StatefulWidget {
  const UpdateMenu({super.key, required this.service});

  final UpdateService service;

  @override
  State<UpdateMenu> createState() => _UpdateMenuState();
}

class _UpdateMenuState extends State<UpdateMenu> with WidgetsBindingObserver {
  static const _installer = MethodChannel('dev.borges.uhp_android/updater');
  bool _busy = false;
  bool _checking = false;
  bool _installing = false;
  bool _resumeRequested = false;
  String? _pendingApk;
  UpdateDownload? _download;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _download?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingApk != null) {
      if (_installing) {
        _resumeRequested = true;
      } else {
        unawaited(_installPending(requestPermission: false));
      }
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _check() async {
    if (_busy || _pendingApk != null) return;
    setState(() {
      _busy = true;
      _checking = true;
    });
    try {
      final release = await widget.service.check();
      if (!mounted) return;
      setState(() => _checking = false);
      if (compareVersions(appVersion, release.tag) >= 0) {
        _message('Up to date ($appVersion)');
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'Update ${release.tag}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: SingleChildScrollView(
                child: Text(
                  release.notes.isEmpty
                      ? 'No release notes provided.'
                      : release.notes,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Dismiss'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Download & install'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final file = await _downloadApk(release);
      if (file == null || !mounted) return;
      _pendingApk = file.path;
      await _installPending(requestPermission: true);
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _checking = false;
        });
      }
    }
  }

  Future<File?> _downloadApk(ReleaseInfo release) async {
    var received = 0;
    int? total;
    var cancelling = false;
    var finished = false;
    Object? failure;
    final file = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          if (_download == null && !finished) {
            final download = widget.service.startDownload(
              release,
              onProgress: (bytes, length) {
                if (finished || !dialogContext.mounted) return;
                updateDialog(() {
                  received = bytes;
                  total = length;
                });
              },
            );
            _download = download;
            unawaited(() async {
              File? completed;
              try {
                completed = await download.result;
              } on UpdateCancelled {
                // Cancellation completes only after the partial file is removed.
              } catch (error) {
                failure = error;
              } finally {
                finished = true;
                _download = null;
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(completed);
                }
              }
            }());
          }
          final length = total;
          final progress = length != null && length > 0
              ? (received / length).clamp(0.0, 1.0)
              : null;
          final receivedMb = (received / (1024 * 1024)).toStringAsFixed(1);
          final totalMb = length == null
              ? null
              : (length / (1024 * 1024)).toStringAsFixed(1);
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text(
                cancelling
                    ? 'Cancelling download'
                    : 'Downloading ${release.tag}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 16),
                  Text(
                    totalMb == null
                        ? '$receivedMb MB received'
                        : '$receivedMb / $totalMb MB',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: cancelling
                      ? null
                      : () {
                          updateDialog(() => cancelling = true);
                          _download?.cancel();
                        },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (failure != null) throw failure!;
    return file;
  }

  Future<void> _installPending({required bool requestPermission}) async {
    final path = _pendingApk;
    if (path == null || _installing) return;
    _installing = true;
    try {
      final result = await _installer.invokeMethod<String>('installApk', {
        'path': path,
        'requestPermission': requestPermission,
      });
      if (!mounted) return;
      if (result == 'launched') {
        _pendingApk = null;
        _message('Installer opened. Confirm the update in Android.');
      } else if (result == 'permissionRequired') {
        if (!requestPermission) {
          _pendingApk = null;
          _message(
            'Installation not allowed. Enable "Allow from this source" and try again.',
          );
        }
      } else {
        _pendingApk = null;
        _message('Android installer returned an unexpected result.');
      }
    } on PlatformException catch (error) {
      _pendingApk = null;
      _message(error.message ?? 'Could not open the Android installer.');
    } on MissingPluginException {
      _pendingApk = null;
      _message('APK installation is available on Android only.');
    } catch (error) {
      _pendingApk = null;
      _message('Could not start APK installation: $error');
    } finally {
      _installing = false;
      if (mounted) {
        setState(() {});
        if (_resumeRequested && _pendingApk != null) {
          _resumeRequested = false;
          unawaited(_installPending(requestPermission: false));
        } else {
          _resumeRequested = false;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: 'Checking for updates',
          ),
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'More options',
      enabled: !_busy && _pendingApk == null && !_installing,
      onSelected: (_) => unawaited(_check()),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'update', child: Text('Check for updates')),
      ],
    );
  }
}
