import 'package:app/domain/contracts/contracts.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:auto_injector/auto_injector.dart';

/// Thin facade over [AutoInjector]. The typed `add*` methods name the layer
/// each registration belongs to and chain `dispose()` where it applies.
///
/// Use `addInstance` for values that already exist and `addOther` for types
/// outside the domain contracts (e.g. `Dio`).
class CustomInjector {
  final _injector = AutoInjector();

  /// Resolves a registration. Every `get` of a `ViewModel` is a new instance.
  T get<T extends Object>() => _injector.get<T>();

  /// Registers an already-built value.
  void addInstance<T>(T instance) {
    _injector.addInstance<T>(instance);
  }

  /// Lazy singleton for types that are neither `Service` nor `Repository`.
  void addOther<T>(Function constructor) {
    _injector.addLazySingleton<T>(constructor);
  }

  /// Lazy singleton [Service], disposed with the injector.
  void addService<T extends Service>(Function constructor) {
    _injector.addLazySingleton<T>(
      constructor,
      config: BindConfig(onDispose: (value) => value.dispose()),
    );
  }

  /// Lazy singleton [Repository], disposed with the injector.
  void addRepository<T extends Repository>(Function constructor) {
    _injector.addLazySingleton<T>(
      constructor,
      config: BindConfig(onDispose: (value) => value.dispose()),
    );
  }

  /// Factory [ViewModel]: state never leaks between screens.
  void addViewModel<T extends ViewModel>(Function constructor) {
    _injector.add(constructor);
  }

  /// Disposes every registration and resets the injector.
  void dispose() => _injector.dispose();

  /// Seals the registry; call at the end of `setupDependencies()`.
  void commit() => _injector.commit();
}
