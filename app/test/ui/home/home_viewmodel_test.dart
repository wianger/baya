import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

Future<Preferences> _prefs() async {
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = Preferences();
  await prefs.load();
  return prefs;
}

void main() {
  group('HomeViewModel', () {
    test('no paired computer → HomeNoPeer', () async {
      final storage = MemoryStorage();
      final hosts = testHosts(storage, FakeHost());
      final vm = HomeViewModel(hosts, storage, await _prefs());
      await hosts.start();
      await settle();
      expect(vm.state, isA<HomeNoPeer>());
      vm.dispose();
      hosts.dispose();
    });

    test('lists every computer\'s sessions, live', () async {
      final a = testPeer(seed: 1, name: 'Desktop');
      final b = testPeer(seed: 2, name: 'Laptop');
      final storage = MemoryStorage([a, b]);
      final hosts = testHostsFor(storage, {
        a.remoteEpk: FakeHost(
          sessions: [testSession(id: 'a1', title: 'API')],
        ),
        b.remoteEpk: FakeHost(
          sessions: [testSession(id: 'b1', title: 'App')],
        ),
      });
      final vm = HomeViewModel(hosts, storage, await _prefs());
      await hosts.start();
      await settle();

      final state = vm.state as HomeList;
      expect(state.peers, hasLength(2));
      expect(vm.allItems.map((i) => i.displayName), ['API', 'App']);
      expect(vm.isRoomLive(a.remoteEpk, 'a1'), isTrue);
      vm.dispose();
      hosts.dispose();
    });

    test('the working dot follows the computer for any session', () async {
      final peer = testPeer();
      final host = FakeHost(sessions: [testSession(id: 'r1')]);
      final storage = MemoryStorage([peer]);
      final hosts = testHosts(storage, host);
      final vm = HomeViewModel(hosts, storage, await _prefs());
      await hosts.start();
      await settle();
      expect(vm.isRoomWorking(peer.remoteEpk, 'r1'), isFalse);

      host.push('_baya/session_changed', {
        'session': testSession(id: 'r1', working: true).toJson(),
      });
      await settle();
      expect(vm.isRoomWorking(peer.remoteEpk, 'r1'), isTrue);

      host.push('_baya/session_changed', {
        'session': testSession(id: 'r1').toJson(),
      });
      await settle();
      expect(vm.isRoomWorking(peer.remoteEpk, 'r1'), isFalse);
      vm.dispose();
      hosts.dispose();
    });

    test('deleting a session deletes it on the computer', () async {
      final peer = testPeer();
      final host = FakeHost(
        sessions: [
          testSession(id: 'r1'),
          testSession(id: 'r2'),
        ],
      );
      final storage = MemoryStorage([peer]);
      final hosts = testHosts(storage, host);
      final vm = HomeViewModel(hosts, storage, await _prefs());
      await hosts.start();
      await settle();

      await vm.deleteSession(
        vm.allItems.firstWhere((i) => i.sessionId == 'r1'),
      );
      await settle();
      expect(host.calls.last.params, {'sessionId': 'r1'});
      expect(vm.allItems.map((i) => i.sessionId), ['r2']);
      vm.dispose();
      hosts.dispose();
    });

    test('forgetting a computer drops it and its cached sessions', () async {
      final a = testPeer(seed: 1, name: 'A');
      final b = testPeer(seed: 2, name: 'B');
      final storage = MemoryStorage([a, b]);
      storage.sessions[a.remoteEpk] = [testSession()];
      final hosts = testHosts(storage, FakeHost());
      final prefs = await _prefs();
      final vm = HomeViewModel(hosts, storage, prefs);
      await hosts.start();
      await settle();
      await vm.selectDevice(a.remoteEpk);

      await vm.deleteDevice(a.remoteEpk);
      await settle();
      expect(storage.peers, [b]);
      expect(storage.sessions[a.remoteEpk], isNull);
      expect(prefs.selectedDeviceEpk, isNull);
      expect((vm.state as HomeList).peers, [b]);
      vm.dispose();
      hosts.dispose();
    });
  });

  group('HomeViewModel — presence filter', () {
    test(
      'online and offline split by whether the computer is connected',
      () async {
        final up = testPeer(seed: 1, name: 'Up');
        final down = testPeer(seed: 2, name: 'Down');
        final storage = MemoryStorage([up, down]);
        storage.sessions[down.remoteEpk] = [testSession(id: 'cached')];
        final hosts = testHostsFor(storage, {
          up.remoteEpk: FakeHost(sessions: [testSession(id: 'live')]),
        });
        final vm = HomeViewModel(hosts, storage, await _prefs());
        await hosts.start();
        await settle();

        expect(vm.counts, (all: 2, online: 1, offline: 1));
        expect(vm.visibleItems.map((i) => i.sessionId), ['live']);
        vm.setFilter(HomeFilter.offline);
        expect(vm.visibleItems.map((i) => i.sessionId), ['cached']);
        vm.setFilter(HomeFilter.all);
        expect(vm.visibleItems, hasLength(2));
        vm.dispose();
        hosts.dispose();
      },
    );

    test('counts and visibleItems are empty outside a list', () {
      final storage = MemoryStorage();
      final hosts = testHosts(storage, FakeHost());
      final vm = HomeViewModel(hosts, storage, Preferences());
      expect(vm.counts, (all: 0, online: 0, offline: 0));
      expect(vm.visibleItems, isEmpty);
      vm.dispose();
      hosts.dispose();
    });
  });
}
