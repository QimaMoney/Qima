import 'package:flutter_bloc/flutter_bloc.dart';

/// For a cubit that starts work it does not wait for (`unawaited`, a
/// listener, a timer) and is closed while that work is still awaiting: the
/// late [emit] is dropped instead of throwing "Cannot emit new states after
/// calling close". Only that one case is silenced; an error thrown by the
/// work itself still reaches its caller.
mixin GuardedEmit<State> on Cubit<State> {
  @override
  void emit(State state) {
    if (isClosed) return;
    super.emit(state);
  }
}
