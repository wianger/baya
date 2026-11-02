import 'package:app/data/voice/read_aloud_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.wianger.baya/read_aloud');
  final controller = ReadAloudController.instance;

  tearDown(() async {
    await controller.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('speak and stop use the in-app Android TTS channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'speak';
        });
    final owner = Object();

    await controller.speak(
      owner: owner,
      text: 'Hello from Baya',
      language: 'en-US',
    );

    expect(controller.isSpeakingFor(owner), isTrue);
    expect(calls.single.method, 'speak');
    expect(calls.single.arguments, {
      'text': 'Hello from Baya',
      'language': 'en-US',
    });

    await controller.stopFor(owner);

    expect(controller.isSpeakingFor(owner), isFalse);
    expect(calls.map((call) => call.method), ['speak', 'stop']);
  });

  test(
    'switching messages stops the previous utterance before speaking',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'speak';
          });
      final first = Object();
      final second = Object();

      await controller.speak(owner: first, text: 'First', language: 'en-US');
      await controller.speak(owner: second, text: 'Second', language: 'en-US');

      expect(controller.isSpeakingFor(first), isFalse);
      expect(controller.isSpeakingFor(second), isTrue);
      expect(calls.map((call) => call.method), ['speak', 'stop', 'speak']);
    },
  );
}
