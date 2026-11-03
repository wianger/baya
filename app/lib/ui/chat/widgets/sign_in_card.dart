import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The agent needs a sign-in before it can work (ACP `authenticate`). Lists
/// its sign-in methods; those that need someone at the computer say what to
/// run there.
class SignInCard extends StatefulWidget {
  const SignInCard({super.key, required this.session});

  final SessionController session;

  @override
  State<SignInCard> createState() => _SignInCardState();
}

class _SignInCardState extends State<SignInCard> {
  late Future<(List<AuthMethod>, bool)> _methods = widget.session.authMethods();
  String? _busy;
  String? _error;

  Future<void> _signIn(AuthMethod method) async {
    setState(() {
      _busy = method.id;
      _error = null;
    });
    try {
      await widget.session.authenticate(method.id);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final agent = widget.session.agentName.isEmpty
        ? context.l10n.yourAgent
        : widget.session.agentName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: BayaSurface(
          key: const Key('sign-in-card'),
          role: BayaSurfaceRole.overlay,
          radius: 22,
          emphasized: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: FutureBuilder(
            future: _methods,
            builder: (context, snapshot) {
              final methods = snapshot.data?.$1 ?? const <AuthMethod>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        LucideIcons.keyRound,
                        size: 17,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.l10n.signInTo(agent),
                          style: context.typo.sansBody.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (snapshot.connectionState != ConnectionState.done)
                    const LinearProgressIndicator(minHeight: 2)
                  else if (snapshot.hasError)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${snapshot.error}',
                            style: context.typo.sansBody.copyWith(
                              color: colors.error,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(
                            () => _methods = widget.session.authMethods(),
                          ),
                          child: Text(context.l10n.retry),
                        ),
                      ],
                    )
                  else if (methods.isEmpty)
                    Text(
                      context.l10n.signInOnComputer,
                      style: context.typo.sansBody.copyWith(
                        color: colors.muted2,
                      ),
                    )
                  else
                    for (final method in methods)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: method.needsComputer
                            ? _OnComputer(method: method)
                            : OutlinedButton(
                                key: ValueKey('sign-in-${method.id}'),
                                onPressed: _busy == null
                                    ? () => _signIn(method)
                                    : null,
                                child: _busy == method.id
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.6,
                                        ),
                                      )
                                    : Text(method.name),
                              ),
                      ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: context.typo.sansBody.copyWith(
                        color: colors.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OnComputer extends StatelessWidget {
  const _OnComputer({required this.method});
  final AuthMethod method;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          method.name,
          style: context.typo.sansBody.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text(
          context.l10n.runOnComputer,
          style: context.typo.sansBody.copyWith(
            fontSize: 13,
            color: colors.muted,
          ),
        ),
        if (method.terminalArgs!.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            method.terminalArgs!.join(' '),
            style: context.typo.mono,
          ),
        ],
      ],
    );
  }
}
