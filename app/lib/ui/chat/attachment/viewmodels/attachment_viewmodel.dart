import 'dart:async';
import 'dart:convert';

import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Drives image attachment for the composer: the picked-image preview and
/// whether the session's agent accepts images (its ACP prompt capabilities).
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker) : super(const AttachmentEmpty());

  final IImagePickerService _picker;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed) for the host page.
  Stream<AttachHint> get hints => _hints.stream;

  bool get hasImage => state is AttachmentAttached;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(_picker.pickFromCamera);
  Future<void> pickFromGallery() => _pick(_picker.pickFromGallery);

  Future<void> _pick(Future<PickedImage?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final img = await pick();
      if (img == null) {
        emit(AttachmentEmpty(visionSupported: vision)); // cancelled
        return;
      }
      emit(AttachmentAttached(image: img, visionSupported: vision));
    } on ImagePermissionDeniedException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Attach an image sent before, to send it again.
  void restore(MessageImage image) {
    emit(
      AttachmentAttached(
        image: PickedImage(bytes: base64Decode(image.data), mime: image.mime),
        visionSupported: state.visionSupported,
      ),
    );
  }

  /// Discard the attached image (the "X" on the preview, #4).
  void removeImage() {
    if (state is! AttachmentAttached) return;
    emit(AttachmentEmpty(visionSupported: state.visionSupported));
  }

  /// Hand the attached image to the send path as a base64 [MessageImage] and
  /// reset to empty. Returns null when nothing is attached.
  MessageImage? takeImageForSend() {
    final s = state;
    if (s is! AttachmentAttached) return null;
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return MessageImage(data: base64Encode(s.image.bytes), mime: s.image.mime);
  }

  /// Whether the agent accepts images; null while unknown (don't gate).
  void setVision(bool? vision) => _setVision(vision);

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking() => AttachmentPicking(visionSupported: vision),
      AttachmentAttached(:final image) => AttachmentAttached(
        image: image,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _hints.close();
    super.dispose();
  }
}
