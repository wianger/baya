import 'package:app/domain/value_objects/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logical workspace ids are unique and contain no path data', () {
    final ids = List.generate(100, (_) => newLogicalWorkspaceId()).toSet();

    expect(ids, hasLength(100));
    expect(ids.every((id) => !id.contains('/') && !id.contains('\\')), isTrue);
  });

  test('workspace keys round-trip a canonical device id and logical id', () {
    const device = 'device-key';
    final key = workspaceKey(device, 'release-train');

    expect(isWorkspaceKey(key), isTrue);
    expect(workspaceDevice(key), device);
    expect(workspaceId(key), 'release-train');
    expect(isWorkspaceKeyForDevice(key, device), isTrue);
    expect(isWorkspaceKeyForDevice(key, 'another-device'), isFalse);
    expect(isInboxWorkspace(inboxWorkspaceKey(device)), isTrue);
  });
}
