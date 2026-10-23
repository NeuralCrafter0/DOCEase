import 'package:flutter/material.dart';

import '../providers/local_database.dart';

/// Confirms the destructive reset offered after `DbFailed(keyMismatch)`.
///
/// Reads [loadUnsynced] (`LocalDatabase.unsyncedCount()`): a known number
/// above zero says how many records would be lost, and unknown shows the
/// strongest warning. The doctor must tick the confirmation before [reset]
/// is called with the exact count they were shown. If the count got worse
/// meanwhile ([ResetNotConfirmedException]), nothing was deleted: the new
/// count is shown and the doctor has to confirm again.
///
/// Pops `true` after a successful reset, `false` on cancel.
class DbResetScreen extends StatefulWidget {
  const DbResetScreen({super.key, required this.loadUnsynced, required this.reset});

  final Future<UnsyncedCount> Function() loadUnsynced;
  final Future<void> Function(UnsyncedCount acknowledged) reset;

  @override
  State<DbResetScreen> createState() => _DbResetScreenState();
}

class _DbResetScreenState extends State<DbResetScreen> {
  UnsyncedCount? _count;
  bool _confirmed = false;
  bool _busy = false;
  bool _countChanged = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    UnsyncedCount count;
    try {
      count = await widget.loadUnsynced();
    } catch (_) {
      count = UnsyncedCount.unknown;
    }
    if (mounted) setState(() => _count = count);
  }

  Future<void> _reset() async {
    final shown = _count;
    if (shown == null || !_confirmed || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.reset(shown);
      if (mounted) Navigator.of(context).pop(true);
    } on ResetNotConfirmedException catch (e) {
      if (!mounted) return;
      setState(() {
        _count = e.current;
        _confirmed = false;
        _countChanged = true;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("The reset didn't finish. Check your connection and try again.")),
      );
    }
  }

  static int _lost(UnsyncedCount c) => c is UnsyncedKnown ? c.count : 0;

  static String _records(int n) => n == 1 ? '1 record' : '$n records';

  Widget _warning(BuildContext context, UnsyncedCount count) {
    final scheme = Theme.of(context).colorScheme;
    final String title;
    final String text;
    final bool severe;
    if (count is UnsyncedUnknown) {
      severe = true;
      title = "DOCEase can't tell what would be lost";
      text = 'Some or all of the records on this phone may not be saved in the cloud. '
          "If you reset, anything that isn't in the cloud is gone for good and can't be recovered. "
          "Only reset if you're sure every record is in the cloud.";
    } else if (_lost(count) > 0) {
      severe = true;
      final n = _lost(count);
      title = '${_records(n)} will be lost';
      text = "${_records(n)} on this phone ${n == 1 ? "hasn't" : "haven't"} been saved to the cloud yet. "
          "Resetting deletes ${n == 1 ? 'it' : 'them'} for good. ${n == 1 ? 'It' : 'They'} can't be recovered.";
    } else {
      severe = false;
      title = 'Nothing unsaved on this phone';
      text = 'Every change on this phone is already saved in the cloud. Resetting replaces '
          "this phone's unreadable copy with your records from the cloud.";
    }
    final bg = severe ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final fg = severe ? scheme.onErrorContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(severe ? Icons.warning_amber_rounded : Icons.cloud_done_outlined, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 6),
                Text(text, style: TextStyle(color: fg)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _confirmLabel(UnsyncedCount count) {
    if (count is UnsyncedUnknown) {
      return "I understand that any records that aren't in the cloud will be permanently deleted.";
    }
    final n = _lost(count);
    if (n > 0) return 'I understand that ${_records(n)} will be permanently deleted.';
    return "I understand that this phone's copy will be deleted and downloaded again.";
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text("Reset this phone's copy")),
        body: SafeArea(
          child: count == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text(
                      "The records on this phone can't be unlocked. A reset deletes this phone's copy, "
                      'starts a new encrypted one, and downloads your records again from the cloud.',
                    ),
                    const SizedBox(height: 16),
                    if (_countChanged) ...[
                      Text(
                        'The number of unsaved records changed. Nothing was deleted. Read the warning again before you reset.',
                        style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _warning(context, count),
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: _confirmed,
                      onChanged: _busy ? null : (v) => setState(() => _confirmed = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text(_confirmLabel(count)),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _confirmed && !_busy ? _reset : null,
                      style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
                      child: _busy
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onError),
                            )
                          : const Text('Reset and download again'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
