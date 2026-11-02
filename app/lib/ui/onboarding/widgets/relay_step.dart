import 'package:app/data/transport/relay_config.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/onboarding/states/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Empty custom URL is allowed — onboarding treats it as "use default
/// community relay" (saves null in Preferences, falls back to
/// [kDefaultRelayUrl] via [resolveRelayUrl]).

/// Onboarding step 2 — relay choice. Two vertical cards: self-hosted
/// (recommended for the privacy story) vs community (convenience).
/// The custom card carries a URL field with inline validation; leaving
/// it empty falls back to the default community relay.
class RelayStep extends StatelessWidget {
  final OnboardingInProgress state;
  final ValueChanged<RelayChoice> onChoice;
  final ValueChanged<String> onCustomUrl;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const RelayStep({
    super.key,
    required this.state,
    required this.onChoice,
    required this.onCustomUrl,
    required this.onBack,
    required this.onNext,
  });

  bool get _canContinue {
    if (state.relayChoice == RelayChoice.community) return true;
    // Empty custom URL is allowed (treated as default community relay).
    if (state.customRelayUrl.isEmpty) return true;
    return isValidRelayUrl(state.customRelayUrl);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: BayaGlassSurface(
        role: BayaGlassRole.card,
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
                  context.l10n.chooseRelay,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 30,
                    color: colors.text,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                context.l10n.relayExplainer,
                style: context.typo.sansBody.copyWith(
                  fontSize: 13,
                  color: colors.muted,
                ),
              ),
              const SizedBox(height: 24),
              _CustomRelayCard(
                badge: 'recommended',
                description: context.l10n.selfHostedRelay,
                selected: state.relayChoice == RelayChoice.custom,
                customUrl: state.customRelayUrl,
                error: state.customRelayError,
                onTap: () => onChoice(RelayChoice.custom),
                onUrlChanged: onCustomUrl,
              ),
              const SizedBox(height: 12),
              _RelayCard(
                title: context.l10n.communityRelay,
                description: context.l10n.communityRelayHint,
                footer: kDefaultRelayUrl,
                selected: state.relayChoice == RelayChoice.community,
                onTap: () => onChoice(RelayChoice.community),
              ),
              const Spacer(),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: onBack,
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: BayaGlassButton(
                      onPressed: _canContinue ? onNext : null,
                      label: Text(context.l10n.continueLabel),
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
}

class _RelayCard extends StatelessWidget {
  final String title;
  final String description;
  final String? footer;
  final bool selected;
  final VoidCallback onTap;
  const _RelayCard({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(22);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : BayaMotion.standard,
      curve: BayaMotion.enter,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: selected && !MediaQuery.highContrastOf(context)
            ? [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ]
            : null,
      ),
      child: BayaGlassSurface(
        role: BayaGlassRole.card,
        radius: 22,
        elevated: false,
        emphasized: selected,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selected ? LucideIcons.circleCheck : LucideIcons.circle,
                        size: 18,
                        color: selected ? colors.accent : colors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 15,
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text(
                      description,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 12.5,
                        color: colors.muted,
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 28),
                      child: Text(
                        footer!,
                        style: context.typo.monoSmall.copyWith(
                          fontSize: 10.5,
                          color: colors.muted,
                        ),
                      ),
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

class _CustomRelayCard extends StatelessWidget {
  final bool selected;
  final String customUrl;
  final String? error;
  final String? badge;
  final String? description;
  final VoidCallback onTap;
  final ValueChanged<String> onUrlChanged;
  const _CustomRelayCard({
    required this.selected,
    required this.customUrl,
    required this.error,
    required this.onTap,
    required this.onUrlChanged,
    this.badge,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(22);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : BayaMotion.standard,
      curve: BayaMotion.enter,
      decoration: BoxDecoration(borderRadius: radius),
      child: BayaGlassSurface(
        role: BayaGlassRole.card,
        radius: 22,
        elevated: false,
        emphasized: selected,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selected ? LucideIcons.circleCheck : LucideIcons.circle,
                        size: 18,
                        color: selected ? colors.accent : colors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.l10n.useMyOwnServer,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 15,
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: colors.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            badge!,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 10,
                              color: colors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 28),
                      child: Text(
                        description!,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 12.5,
                          color: colors.muted,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                  if (selected) ...[
                    const SizedBox(height: 13),
                    Padding(
                      padding: const EdgeInsets.only(left: 28),
                      child: TextField(
                        key: const ValueKey('custom-relay-url'),
                        controller: TextEditingController(text: customUrl)
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: customUrl.length),
                          ),
                        onChanged: onUrlChanged,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: context.typo.mono.copyWith(
                          fontSize: 12,
                          color: colors.text,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'https://my-relay.com',
                          hintStyle: context.typo.mono.copyWith(
                            color: colors.muted,
                          ),
                          errorText: error,
                          errorStyle: context.typo.sansBody.copyWith(
                            fontSize: 10.5,
                            color: colors.error,
                          ),
                        ),
                      ),
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
