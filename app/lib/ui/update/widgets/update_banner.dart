import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// In-app update notice (plan 44, step 3). Renders nothing inline; instead it
/// runs the silent check on first mount (= Home startup) and, when a newer
/// build exists, raises the same confirm modal the rest of the app uses.
///
/// The Android-only gate lives in [UpdateBannerViewModel.enabled], so this is a
/// no-op on iOS. Dismissal is persisted per version by the ViewModel.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  UpdateBannerState? _last;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    // `context.read` is safe in initState (no subscription). Best-effort: the
    // check self-silences on failure and is a no-op outside Android.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<UpdateBannerViewModel>().check();
    });
  }

  Future<void> _present(UpdateBannerViewModel vm, UpdateInfo info) async {
    if (_showing) return;
    _showing = true;
    await showBayaNotice(
      context,
      title: 'Update available',
      message:
          'Version ${info.version} (${info.buildNumber}) is ready to download.',
      confirmLabel: 'Download APK',
      secondaryLabel: 'Later',
      dismissible: false,
      onConfirm: vm.download,
      onSecondary: vm.dismiss,
    );
    if (mounted) setState(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateBannerViewModel>();
    final state = vm.state;
    if (state is UpdateBannerVisible && !identical(state, _last)) {
      _last = state;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Only raise the modal when the route that owns this banner is
        // actually on top. If the user is inside /about or /settings they
        // will get the same prompt from those pages; showing it here too
        // would produce two overlapping dialogs.
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route != null && !route.isCurrent) return;
        _present(vm, state.info);
      });
    }
    return const SizedBox.shrink();
  }
}
