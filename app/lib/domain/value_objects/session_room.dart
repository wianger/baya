/// A Pi conversation can have a daemon and a resumed terminal endpoint.
/// Keep routing ids distinct; only grouping/cache identity is shared.
///
/// The session key is the stable identity. The route suffix is deliberately
/// not length-constrained: older or future clients may encode the cwd/name
/// route differently, and that must not split one persisted conversation.
final _piRoom = RegExp(r'^pi_([A-Za-z0-9_-]{16})_([di])_([A-Za-z0-9_-]+)$');

String conversationRoomId(String roomId) {
  final match = _piRoom.firstMatch(roomId);
  return match == null ? roomId : 'pi_${match.group(1)}';
}

bool isInteractivePiRoom(String roomId) =>
    _piRoom.firstMatch(roomId)?.group(2) == 'i';

String? legacyPiInstanceRoomId(String roomId) =>
    _piRoom.firstMatch(roomId)?.group(3);

/// The broker appends `#2`, `#3`, … when two Pi endpoints request the same
/// display name. That suffix is routing metadata, not part of the
/// conversation title shown to the user.
String displayRoomName(String? name) =>
    name?.replaceFirst(RegExp(r'#\d+$'), '').trim() ?? '';
