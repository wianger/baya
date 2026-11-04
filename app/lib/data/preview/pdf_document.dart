import 'package:flutter/services.dart';

/// A PDF on the phone, rendered by Android's own PdfRenderer a page at a
/// time (`dev.wianger.baya/pdf`).
class PdfDocument {
  PdfDocument._(this._id, this.pageSizes);

  static const _channel = MethodChannel('dev.wianger.baya/pdf');

  final int _id;

  /// Each page's size in points.
  final List<Size> pageSizes;

  static Future<PdfDocument> open(String path) async {
    final opened = await _channel.invokeMapMethod<String, Object?>('open', {
      'path': path,
    });
    final sizes = [
      for (final size in (opened!['sizes']! as List).cast<List<Object?>>())
        Size((size[0]! as num).toDouble(), (size[1]! as num).toDouble()),
    ];
    return PdfDocument._(opened['id']! as int, sizes);
  }

  /// Page [page] (from 0) as a PNG [width] pixels wide.
  Future<Uint8List> render(int page, int width) async =>
      (await _channel.invokeMethod<Uint8List>('render', {
        'id': _id,
        'page': page,
        'width': width,
      }))!;

  Future<void> close() => _channel.invokeMethod('close', {'id': _id});
}
