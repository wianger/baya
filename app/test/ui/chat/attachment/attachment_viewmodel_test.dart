// AttachmentViewModel: pick / remove / take + vision gating.

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/images/image_picker_service.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? next = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );
  bool denyCamera = false;
  bool fail = false;

  @override
  Future<PickedImage?> pickFromCamera() async {
    if (denyCamera) throw const ImagePermissionDeniedException();
    if (fail) throw Exception('boom');
    return next;
  }

  @override
  Future<PickedImage?> pickFromGallery() async {
    if (fail) throw Exception('boom');
    return next;
  }
}

void main() {
  test('pickFromGallery attaches an image; removeImage clears it', () async {
    final vm = AttachmentViewModel(_FakePicker());
    await vm.pickFromGallery();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasImage, isTrue);

    vm.removeImage();
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.hasImage, isFalse);
    vm.dispose();
  });

  test('takeImageForSend returns base64 MessageImage and resets', () async {
    final picker = _FakePicker()
      ..next = PickedImage(
        bytes: Uint8List.fromList([10, 20, 30]),
        mime: 'image/jpeg',
      );
    final vm = AttachmentViewModel(picker);
    await vm.pickFromGallery();

    final msg = vm.takeImageForSend();
    expect(msg, isNotNull);
    expect(msg!.mime, 'image/jpeg');
    expect(base64Decode(msg.data), [10, 20, 30]);
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeImageForSend(), isNull); // nothing left
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(picker);
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFromCamera();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.cameraPermissionDenied]);
    await sub.cancel();
    vm.dispose();
  });

  test('vision follows the agent: unknown, no, yes', () async {
    final vm = AttachmentViewModel(_FakePicker());
    expect(vm.state.visionSupported, isNull);
    expect(vm.state.attachBlockedByVision, isFalse);

    vm.setVision(false);
    expect(vm.state.attachBlockedByVision, isTrue);

    vm.setVision(true);
    expect(vm.state.visionSupported, isTrue);
    expect(vm.state.attachBlockedByVision, isFalse);
    vm.dispose();
  });
}
