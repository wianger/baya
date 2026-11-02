// Room control frames as the host's direct endpoint sends them.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room_announced carries the full room', () {
    final frame =
        ControlInbound.tryFromJson({
              'type': 'room_announced',
              'peer': 'host',
              'room_id': 'r1',
              'name': 'baya',
              'cwd': '/code/baya',
              'model': 'gpt-5',
              'thinking': 'high',
              'working': true,
              'started_at': 7,
            })!
            as RoomAnnounced;
    expect(frame.peer, 'host');
    expect(
      frame.room,
      const RoomInfo(
        roomId: 'r1',
        name: 'baya',
        cwd: '/code/baya',
        model: 'gpt-5',
        thinking: ThinkingLevel.high,
        working: true,
        startedAt: 7,
      ),
    );
  });

  test('room_meta_updated is the full current state', () {
    final frame =
        ControlInbound.tryFromJson({
              'type': 'room_meta_updated',
              'peer': 'host',
              'room_id': 'r1',
              'meta': {'model': 'gpt-5', 'working': false},
            })!
            as RoomMetaUpdated;
    expect(frame.model, 'gpt-5');
    expect(frame.thinking, isNull);
    expect(frame.working, isFalse);
  });

  test('rooms snapshot and room_ended', () {
    final snapshot =
        ControlInbound.tryFromJson({
              'type': 'rooms',
              'peer': 'host',
              'rooms': [
                {'room_id': 'a', 'started_at': 1, 'working': false},
                {'room_id': 'b', 'started_at': 2, 'working': true},
              ],
            })!
            as RoomsSnapshot;
    expect(snapshot.rooms.map((r) => (r.roomId, r.working)), [
      ('a', false),
      ('b', true),
    ]);
    final ended =
        ControlInbound.tryFromJson({
              'type': 'room_ended',
              'peer': 'host',
              'room_id': 'a',
              'since_ts': 3,
            })!
            as RoomEnded;
    expect(ended.roomId, 'a');
  });

  test('unknown thinking levels are dropped, unknown frames ignored', () {
    final room = RoomInfo.fromJson({
      'room_id': 'r',
      'started_at': 1,
      'thinking': 'turbo',
      'working': false,
    });
    expect(room.thinking, isNull);
    expect(ControlInbound.tryFromJson({'type': 'later'}), isNull);
  });
}
