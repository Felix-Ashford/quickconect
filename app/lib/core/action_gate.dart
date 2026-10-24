import 'dart:async';

/// Ignores repeated activation until the entire operation (including dialogs,
/// network requests and navigation) finishes. A failure always releases it.
class ActionGate {
  ActionGate({this.onChanged});

  final void Function()? onChanged;
  bool _busy = false;
  bool get busy => _busy;

  Future<T?> run<T>(FutureOr<T> Function() action) async {
    if (_busy) return null;
    _busy = true;
    onChanged?.call();
    try {
      return await action();
    } finally {
      _busy = false;
      onChanged?.call();
    }
  }
}
