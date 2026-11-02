import 'dart:async';

import 'package:app/l10n/l10n.dart';

import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/pairing/states/pairing_state.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/pairing/widgets/nickname_sheet.dart';
import 'package:app/ui/pairing/widgets/paste_qr_sheet.dart';
import 'package:app/ui/pairing/widgets/tailnet_pair_sheet.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

// ---------------------------------------------------------------------------
// PairingPage — QR scanner + pair_request in one screen
// ---------------------------------------------------------------------------

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, this.initialCode});

  /// A `baya://pair` link the app was opened with; paired right away.
  final String? initialCode;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _scanner = MobileScannerController();
  bool _scannerActive = true;
  // Guards against [_runPostPairFlow] firing twice — `PairingPaired`
  // is rebroadcast on every `applyNickname` emit, and we only want to
  // open the sheet once per pairing.
  bool _postPairStarted = false;

  @override
  void initState() {
    super.initState();
    final code = widget.initialCode;
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submitRaw(code);
      });
    }
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (!_scannerActive) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    _submitRaw(raw);
  }

  /// Common path for any QR payload — same whether it came from the
  /// camera (`_onDetect`) or the manual paste sheet. Disarms the
  /// scanner so we don't double-fire if the camera also catches it.
  void _submitRaw(String raw) {
    if (!_scannerActive) return;
    setState(() => _scannerActive = false);
    _scanner.stop();
    context.read<PairingViewModel>().onQrScanned(raw);
  }

  Future<void> _openPasteSheet() async {
    await showPasteQrSheet(context, onSubmit: _submitRaw);
  }

  Future<void> _openTailnetSheet() async {
    await showTailnetPairSheet(context, onSubmit: _submitRaw);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PairingViewModel>();
    final state = vm.state;

    if (state is PairingPaired && !_postPairStarted) {
      _postPairStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_runPostPairFlow(state.hostnameHint));
      });
    }

    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: const BayaSurface(
          role: BayaSurfaceRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        scrolledUnderElevation: 0,
        title: Text(context.l10n.pairDevice),
      ),
      body: _buildBody(state, vm),
    );
  }

  /// Opens the post-pair nickname sheet, persists
  /// whatever the user picked, then navigates home. Modal is
  /// dismissible; either Save, Skip or drag-down all produce a usable
  /// label.
  Future<void> _runPostPairFlow(String? hostnameHint) async {
    final vm = context.read<PairingViewModel>();
    final nickname = await showNicknameSheet(
      context,
      defaultName: hostnameHint,
    );
    if (!mounted) return;
    await vm.applyNickname(nickname);
    if (!mounted) return;
    context.go('/home');
  }

  Widget _buildBody(PairingState state, PairingViewModel vm) {
    return switch (state) {
      PairingIdle() ||
      PairingScanning() ||
      PairingConnecting() => _buildScannerBody(state),
      PairingPaired() => BayaBackdrop(
        child: Center(
          child: CircularProgressIndicator(color: context.colors.accent),
        ),
      ),
      PairingError(:final message, :final canRetry) => BayaBackdrop(
        child: _ErrorView(
          message: message,
          canRetry: canRetry,
          onRetry: () {
            vm.retry();
            setState(() => _scannerActive = true);
            _scanner.start();
          },
        ),
      ),
    };
  }

  Widget _buildScannerBody(PairingState state) {
    final colors = context.colors;
    final isConnecting = state is PairingConnecting;
    final sessionName = isConnecting ? state.sessionName : null;

    return Stack(
      children: [
        if (!isConnecting)
          MobileScanner(controller: _scanner, onDetect: _onDetect),
        Center(
          child: isConnecting
              ? BayaSurface(
                  role: BayaSurfaceRole.overlay,
                  radius: 24,
                  elevated: false,
                  child: SizedBox.square(
                    dimension: 268,
                    child: Center(
                      child: CircularProgressIndicator(color: colors.accent),
                    ),
                  ),
                )
              : Container(
                  width: 268,
                  height: 268,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: colors.border),
                  ),
                  child: _CornerBrackets(),
                ),
        ),
        if (!isConnecting) ..._cornerBrackets(),
        Positioned(
          bottom: isConnecting ? 48 : 110,
          left: 0,
          right: 0,
          child: Center(
            child: BayaSurface(
              role: BayaSurfaceRole.content,
              radius: 15,
              elevated: false,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              child: Text(
                isConnecting
                    ? context.l10n.connectingTo(sessionName ?? '')
                    : context.l10n.pointCameraAtQr,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.text, fontSize: 14),
              ),
            ),
          ),
        ),
        if (!isConnecting)
          Positioned(
            bottom: 32,
            left: 32,
            right: 32,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('pair-tailscale'),
                    onPressed: _openTailnetSheet,
                    icon: const Icon(LucideIcons.network, size: 16),
                    label: Text(context.l10n.useTailscale),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('pair-paste'),
                    onPressed: _openPasteSheet,
                    icon: const Icon(LucideIcons.clipboardPaste, size: 16),
                    label: Text(context.l10n.pasteCode),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _cornerBrackets() {
    return [
      Align(alignment: const Alignment(-0.7, -0.4), child: _Bracket(rotate: 0)),
      Align(alignment: const Alignment(0.7, -0.4), child: _Bracket(rotate: 90)),
      Align(alignment: const Alignment(0.7, 0.4), child: _Bracket(rotate: 180)),
      Align(
        alignment: const Alignment(-0.7, 0.4),
        child: _Bracket(rotate: 270),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------

class _CornerBrackets extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Bracket extends StatelessWidget {
  final double rotate;
  const _Bracket({required this.rotate});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: rotate * 3.14159 / 180,
      child: SizedBox(
        width: 32,
        height: 32,
        child: CustomPaint(
          painter: _BracketPainter(color: context.colors.accent),
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  const _BracketPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(18, 0), paint);
    canvas.drawLine(Offset.zero, Offset(0, 18), paint);
  }

  @override
  bool shouldRepaint(_BracketPainter old) => old.color != color;
}

// ---------------------------------------------------------------------------
// Error view
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.message,
    required this.canRetry,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaReveal(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: BayaSurface(
            radius: 28,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: colors.error.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.circleAlert,
                      color: colors.error,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: context.typo.sansBody.copyWith(
                      color: colors.muted2,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  if (canRetry) ...[
                    const SizedBox(height: 22),
                    BayaButton(
                      onPressed: onRetry,
                      label: Text(context.l10n.tryAgain),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
