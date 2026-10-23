import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/local_database.dart';
import '../screens/db_reset_screen.dart';
import 'db_open_state_view.dart';

/// Shows [child] only once [uid]'s local database is `DbReady(uid)`.
/// Until then it shows [DbOpenStateView] (loading, migration progress, or the
/// failure for each [DbOpenError]). A key mismatch is the only failure that
/// leads to [DbResetScreen].
///
/// Build it only behind the unlock screen. The database is opened when the
/// gate first appears, so it never opens before the doctor has unlocked.
///
/// With [manageLifecycle] (the default) the gate opens the database itself
/// after its first frame and closes it when it is removed (sign-out or a
/// different doctor). Pass false when something else, such as a session
/// controller, owns opening and closing; the gate then only shows state, and
/// Try again still calls `openFor`.
///
/// The database comes from [db], or a `Provider<LocalDatabase>` above.
class DbGate extends StatefulWidget {
  const DbGate({
    super.key,
    required this.uid,
    required this.child,
    this.db,
    this.resync,
    this.manageLifecycle = true,
  });

  final String uid;
  final Widget child;
  final LocalDatabase? db;

  /// Passed to `resetAndResync` (for example a Firestore pull).
  final Future<void> Function()? resync;

  final bool manageLifecycle;

  @override
  State<DbGate> createState() => _DbGateState();
}

class _DbGateState extends State<DbGate> {
  late LocalDatabase _db;
  late DbOpenState _state;
  StreamSubscription<DbOpenState>? _sub;
  bool _opening = false;
  bool _disposed = false;

  /// Whether a state for this doctor has been seen; only then does a later
  /// DbClosed mean "closed underneath us" (not the initial replay).
  bool _hadOwnState = false;

  @override
  void initState() {
    super.initState();
    _db = widget.db ?? context.read<LocalDatabase>();
    _state = _forThisDoctor(_db.state);
    _sub = _db.states.listen(_onState);
    if (widget.manageLifecycle && !_isActiveForUid(_db.state)) {
      // After this frame: a gate being replaced (doctor switch) closes its
      // database during this frame's teardown, before this open starts.
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  /// States for another doctor are shown as loading until ours arrive.
  DbOpenState _forThisDoctor(DbOpenState s) => s.uid == widget.uid ? s : DbOpening(widget.uid);

  bool _isActiveForUid(DbOpenState s) =>
      s.uid == widget.uid && (s is DbReady || s is DbOpening || s is DbMigrating || s is DbFailed);

  void _onState(DbOpenState s) {
    if (_disposed) return;
    if (s.uid != widget.uid && s is! DbClosed) return;
    final closedUnderneath = s is DbClosed && _hadOwnState;
    if (s.uid == widget.uid) _hadOwnState = true;
    setState(() => _state = _forThisDoctor(s));
    if (closedUnderneath && widget.manageLifecycle) {
      // Closed by something else while this doctor is still signed in.
      _hadOwnState = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  Future<void> _open() async {
    if (_disposed || _opening) return;
    _opening = true;
    try {
      await _db.openFor(widget.uid);
    } on DbOpenException {
      // The failure arrives as DbFailed on the state stream.
    } catch (_) {
      // Not a classified open error (for example a rejected uid). Show the
      // safe retry view; never a reset.
      if (!_disposed) setState(() => _state = DbFailed(widget.uid, DbOpenError.migrationFailed));
    } finally {
      _opening = false;
    }
    // The stream is the source of truth; this only covers a missed event.
    final now = _db.state;
    if (!_disposed && now.uid == widget.uid && now.runtimeType != _state.runtimeType) {
      setState(() => _state = now);
    }
  }

  Future<void> _openReset() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DbResetScreen(
          loadUnsynced: _db.unsyncedCount,
          reset: (ack) => _db.resetAndResync(acknowledgedUnsynced: ack, resync: widget.resync),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    if (widget.manageLifecycle && _db.state.uid == widget.uid) unawaited(_db.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s is DbReady && s.uid == widget.uid) return widget.child;
    return DbOpenStateView(state: s, onRetry: _open, onReset: _openReset);
  }
}
