import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/session_controller.dart';

/// Closes every route above the root, including sheets and dialogs, as soon
/// as the session's owner changes or the session ends (security S2, backend
/// gap G1). The root then shows Login or the status view by itself.
///
/// It sits in `MaterialApp.builder`, above the navigator, and needs the
/// app's [navigatorKey]. Without a [SessionController] above it (some widget
/// tests) it does nothing.
class SessionRouteReset extends StatefulWidget {
  const SessionRouteReset({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<SessionRouteReset> createState() => _SessionRouteResetState();
}

class _SessionRouteResetState extends State<SessionRouteReset> {
  SessionController? _session;
  String? _owner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    SessionController? next;
    try {
      next = Provider.of<SessionController>(context, listen: false);
    } on ProviderNotFoundException {
      next = null;
    }
    if (!identical(next, _session)) {
      _session?.removeListener(_onSession);
      _session = next;
      _owner = next?.ownerId;
      next?.addListener(_onSession);
    }
  }

  void _onSession() {
    final owner = _session?.ownerId;
    if (owner == _owner) return;
    _owner = owner;
    // Pop right away so no frame shows the old owner's screens. If the
    // change arrives mid-build, do it straight after that frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _popAll());
    } else {
      _popAll();
    }
  }

  void _popAll() {
    widget.navigatorKey.currentState?.popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    _session?.removeListener(_onSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
