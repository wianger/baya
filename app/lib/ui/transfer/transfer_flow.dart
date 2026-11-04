import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// `12 B`, `3.4 KB`, `56.7 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// [source] without its first [count] bytes, for an upload carrying on.
Stream<List<int>> skipBytes(Stream<List<int>> source, int count) async* {
  var left = count;
  await for (final chunk in source) {
    if (left >= chunk.length) {
      left -= chunk.length;
      continue;
    }
    yield left == 0 ? chunk : chunk.sublist(left);
    left = 0;
  }
}

/// Picks files on the phone and sends them to the computer, into [dir] or
/// the session's inbox. Returns what arrived; empty when nothing was picked,
/// it was cancelled, or it failed (after saying so).
Future<List<UploadedFile>> uploadFromPhone(
  BuildContext context,
  FileTransfer transfer, {
  String? dir,
}) async {
  final picked = await FilePicker.pickFiles();
  if (picked.isEmpty || !context.mounted) return const [];
  final files = <PhoneFile>[];
  for (final file in picked) {
    final size = file.lengthSync() ?? await file.length() ?? 0;
    if (size > FileTransfer.maxBytes) {
      if (context.mounted) {
        await showBayaNotice(
          context,
          title: context.l10n.transferFailed,
          message: context.l10n.fileTooLarge(file.name),
        );
      }
      return const [];
    }
    files.add(
      PhoneFile(
        name: file.name,
        size: size,
        read: (start) => skipBytes(file.readAsByteStream(), start),
      ),
    );
  }
  if (!context.mounted) return const [];
  final total = files.fold<int>(0, (sum, file) => sum + file.size);
  final sent = await runTransfer<List<UploadedFile>>(
    context,
    title: context.l10n.sendingToComputer,
    task: (progress, label, control) async {
      final done = <UploadedFile>[];
      var before = 0;
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        label(
          files.length == 1
              ? file.name
              : '${file.name}  ·  ${appL10n.fileNofM(i + 1, files.length)}',
        );
        done.add(
          await transfer.upload(
            file,
            dir: dir,
            control: control,
            onProgress: (bytes, _) => progress(before + bytes, total),
          ),
        );
        before += file.size;
      }
      return done;
    },
  );
  return sent ?? const [];
}

/// Fetches the computer's file at [path], then offers to save or share it.
Future<void> saveToPhone(
  BuildContext context,
  FileTransfer transfer, {
  required String path,
  required String name,
}) async {
  final folder = Directory(
    '${(await getTemporaryDirectory()).path}/transfers/'
    '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}',
  );
  if (!context.mounted) return;
  final file = await runTransfer<File>(
    context,
    title: context.l10n.receivingFromComputer,
    task: (progress, label, control) async {
      label(name);
      await folder.create(recursive: true);
      final target = File('${folder.path}/$name');
      final sink = target.openWrite();
      try {
        await transfer.download(
          path,
          sink,
          control: control,
          onProgress: progress,
        );
      } finally {
        await sink.close();
      }
      return target;
    },
  );
  if (file == null) {
    unawaited(_remove(folder));
    return;
  }
  if (!context.mounted) return;
  final size = await file.length();
  if (!context.mounted) return;
  await showBayaSheet<void>(
    context,
    title: name,
    subtitle: formatBytes(size),
    builder: (sheetContext) => BayaGroup(
      children: [
        BayaRow(
          key: const Key('transfer-save'),
          icon: LucideIcons.download,
          label: context.l10n.saveToPhone,
          onTap: () async {
            final saved = await FilePicker.saveFile(
              fileName: name,
              bytes: await file.readAsBytes(),
            );
            if (saved == null || !sheetContext.mounted) return;
            Navigator.of(sheetContext).pop();
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(SnackBar(content: Text(context.l10n.savedToPhone)));
          },
        ),
        BayaRow(
          key: const Key('transfer-share'),
          icon: LucideIcons.share2,
          label: context.l10n.shareFile,
          onTap: () async {
            await SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)]),
            );
          },
        ),
      ],
    ),
  );
  // The share target may still be reading it; the cache is cleared later.
  unawaited(_sweep(folder.parent, keep: folder));
}

Future<void> _remove(Directory folder) async {
  try {
    if (await folder.exists()) await folder.delete(recursive: true);
  } catch (_) {}
}

/// Drops earlier downloads; they were saved or shared already.
Future<void> _sweep(Directory transfers, {required Directory keep}) async {
  try {
    await for (final entry in transfers.list()) {
      if (entry.path != keep.path) await entry.delete(recursive: true);
    }
  } catch (_) {}
}

typedef TransferTask<T> = Future<T> Function(
  TransferProgress progress,
  void Function(String) label,
  TransferControl control,
);

/// Runs [task] under a progress dialog the person can cancel. Null when
/// cancelled or failed (a failure is shown).
Future<T?> runTransfer<T>(
  BuildContext context, {
  required String title,
  required TransferTask<T> task,
}) async {
  final control = TransferControl();
  final status = ValueNotifier<(String, int, int)>(('', 0, 0));
  final work = task(
    (done, total) => status.value = (status.value.$1, done, total),
    (label) => status.value = (label, status.value.$2, status.value.$3),
    control,
  );
  // Settles either way, so the dialog can close on it.
  final settled = work.then<Object?>((_) => null, onError: (Object e) => e);
  await showBayaDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TransferDialog(
      title: title,
      status: status,
      settled: settled,
      onCancel: control.cancel,
    ),
  );
  // A cancel returns at once; the task stops at its next piece.
  if (control.cancelled) return null;
  final failure = await settled;
  if (failure == null) return work;
  if (failure is! TransferCancelled && context.mounted) {
    await showBayaNotice(
      context,
      title: context.l10n.transferFailed,
      message: failure is TransferTooLarge
          ? context.l10n.fileTooLarge(status.value.$1)
          : '$failure',
    );
  }
  return null;
}

class _TransferDialog extends StatefulWidget {
  const _TransferDialog({
    required this.title,
    required this.status,
    required this.settled,
    required this.onCancel,
  });

  final String title;
  final ValueListenable<(String, int, int)> status;
  final Future<Object?> settled;
  final VoidCallback onCancel;

  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.settled.whenComplete(_close);
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: BayaDialog(
        key: const Key('transfer-progress'),
        title: Text(widget.title),
        content: ValueListenableBuilder(
          valueListenable: widget.status,
          builder: (context, value, _) {
            final (label, done, total) = value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.sansBody,
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: total > 0 ? done / total : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  total > 0
                      ? '${formatBytes(done)} / ${formatBytes(total)}'
                      : '',
                  style: context.typo.monoSmall.copyWith(
                    color: context.colors.muted,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            key: const Key('transfer-cancel'),
            onPressed: () {
              widget.onCancel();
              _close();
            },
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
  }
}
