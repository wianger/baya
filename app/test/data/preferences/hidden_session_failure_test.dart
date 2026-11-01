import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements FlutterSecureStorage {
  bool fail = true;
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #write) {
      return fail
          ? Future<void>.error(StateError('storage unavailable'))
          : Future<void>.value();
    }
    return super.noSuchMethod(call);
  }
}

void main() {
  test('failed navigation write preserves selection and the next write can recover', () async {
    final store = _Store()..fail = false;
    final prefs = Preferences(store);
    final first = workspaceKey('device', 'one');
    final second = workspaceKey('other', 'two');
    await prefs.setSelectedWorkspace(first);
    final before = prefs.selectedWorkspace;
    store.fail = true;
    await expectLater(prefs.setSelectedDevice('other'), throwsStateError);
    expect(prefs.selectedWorkspace, before);
    store.fail = false;
    await prefs.setSelectedWorkspace(second);
    expect(prefs.selectedWorkspace, second);
    prefs.dispose();
  });
  test('a failed persistence operation cannot falsely hide or restore a conversation', () async {
    final store = _Store(), prefs = Preferences(_Store());
    await expectLater(prefs.hideSession('peer', 'room'), throwsStateError);
    expect(prefs.isSessionHidden('peer', 'room'), isFalse);
    final state = Preferences(store);
    store.fail = false;
    await state.hideSession('peer', 'room');
    store.fail = true;
    await expectLater(state.restoreSession('peer', 'room'), throwsStateError);
    expect(state.isSessionHidden('peer', 'room'), isTrue);
    prefs.dispose();
    state.dispose();
  });
}
