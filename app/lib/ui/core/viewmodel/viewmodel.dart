import 'package:flutter/foundation.dart';

/// Base class for all ViewModels in the app.
///
/// Holds a single immutable [state] of type [T] and notifies listeners only
/// when [emit] is called with a value different from the current one
/// (per `==`). Pair this with sealed classes in `ui/<feature>/states/` to model
/// every screen state explicitly (e.g. `Loading`, `Ready`, `Error`).
///
/// Pages never build a ViewModel directly: add a factory to
/// `AppServices` in `config/dependencies.dart` and bind it on the route with
/// `ViewmodelProvider<T>()`.
abstract class ViewModel<T extends Object> extends ChangeNotifier {
  ViewModel(this._state);

  T _state;
  T get state => _state;

  void emit(T newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }
}
