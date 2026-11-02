/// Hosts may append `#2`, `#3`, … to disambiguate equal session names. That
/// suffix is routing metadata, not part of the title shown to the user.
String displayRoomName(String? name) =>
    name?.replaceFirst(RegExp(r'#\d+$'), '').trim() ?? '';
