import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/pairing/states/pairing_state.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/pairing/widgets/paste_qr_sheet.dart';
import 'package:app/ui/pairing/widgets/tailnet_pair_sheet.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

/// Onboarding step 3 — embeds the existing pairing flow. Watches the
/// already-registered `PairingViewModel` (Provider) and notifies the
/// onboarding flow when pairing succeeds.
class PairStep extends StatefulWidget {
  final VoidCallback onPaired;
  final VoidCallback onBack;
  final VoidCallback onSkip;
  const PairStep({
    super.key,
    required this.onPaired,
    required this.onBack,
    required this.onSkip,
  });

  @override
  State<PairStep> createState() => _PairStepState();
}

class _PairStepState extends State<PairStep> {
  final _scanner = MobileScannerController();
  bool _scannerActive = true;
  PairingState? _lastObserved;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture, PairingViewModel vm) {
    if (!_scannerActive) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      _submitRaw(raw, vm);
      break;
    }
  }

  /// Shared path between camera scan and manual paste. Disarms the
  /// scanner so the camera doesn't double-fire if both happen to
  /// resolve the QR at the same time.
  void _submitRaw(String raw, PairingViewModel vm) {
    if (!_scannerActive) return;
    _scannerActive = false;
    // ignore: unawaited_futures
    _scanner.stop();
    vm.onQrScanned(raw);
  }

  Future<void> _openPasteSheet(PairingViewModel vm) async {
    await showPasteQrSheet(context, onSubmit: (raw) => _submitRaw(raw, vm));
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<PairingViewModel>();
    final state = vm.state;

    // Detect transition into PairingPaired and notify parent. Done once.
    if (state is PairingPaired && _lastObserved is! PairingPaired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPaired();
      });
    }
    _lastObserved = state;

    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: BayaSurface(
        radius: 28,
        elevated: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              BayaReveal(
                offset: 6,
                child: Text(
                  context.l10n.connectToDevice,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 28,
                    color: colors.text,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.7,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.pairStepInstructions,
                style: context.typo.sansBody.copyWith(
                  fontSize: 13,
                  color: colors.muted,
                ),
              ),
              const SizedBox(height: 6),
              BayaSurface(
                role: BayaSurfaceRole.content,
                radius: 13,
                elevated: false,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  'baya pair',
                  style: context.typo.mono.copyWith(
                    fontSize: 13.5,
                    color: colors.accent,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.scanQrThatAppears,
                style: context.typo.sansBody.copyWith(
                  fontSize: 13,
                  color: colors.muted,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: _buildScannerBody(state, vm),
                ),
              ),
              const SizedBox(height: 12),
              // Camera-less fallbacks: Tailscale name or pasted code.
              if (state is PairingScanning || state is PairingIdle)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const Key('onboarding-pair-tailscale'),
                        onPressed: () => showTailnetPairSheet(
                          context,
                          onSubmit: (raw) => _submitRaw(raw, vm),
                        ),
                        icon: const Icon(LucideIcons.network, size: 16),
                        label: Text(context.l10n.useTailscale),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => _openPasteSheet(vm),
                        icon: const Icon(LucideIcons.clipboardPaste, size: 16),
                        label: Text(context.l10n.pasteCode),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: widget.onBack,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.muted,
                      side: BorderSide(color: colors.border),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    child: Text(context.l10n.back),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: widget.onSkip,
                    style: TextButton.styleFrom(
                      foregroundColor: colors.accent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: Text(
                      context.l10n.scanLater,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScannerBody(PairingState state, PairingViewModel vm) {
    if (state is PairingScanning) {
      return Stack(
        children: [
          MobileScanner(
            controller: _scanner,
            onDetect: (capture) => _onDetect(capture, vm),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: context.colors.accent, width: 2),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ],
      );
    }
    if (state is PairingConnecting) {
      return const _StatusOverlay(
        icon: LucideIcons.refreshCw,
        message: 'Pairing…',
      );
    }
    if (state is PairingError) {
      return _StatusOverlay(
        icon: LucideIcons.circleAlert,
        message: state.message,
        actionLabel: state.canRetry ? context.l10n.tryAgain : null,
        onAction: state.canRetry
            ? () {
                _scannerActive = true;
                _scanner.start();
                vm.retry();
              }
            : null,
      );
    }
    if (state is PairingPaired) {
      return const _StatusOverlay(
        icon: LucideIcons.circleCheck,
        message: 'Paired!',
      );
    }
    return const SizedBox.shrink();
  }
}

class _StatusOverlay extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _StatusOverlay({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.overlay,
      radius: 24,
      elevated: false,
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: colors.accent, size: 40),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 14,
                    color: colors.text,
                    height: 1.45,
                  ),
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                BayaButton(onPressed: onAction, label: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
