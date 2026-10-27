import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Shows the pairing code on screen while another app (e.g. Home Assistant) is pairing with this device.
class PairingPrompt extends StatefulWidget {
  final Widget child;

  const PairingPrompt({super.key, required this.child});

  @override
  State<PairingPrompt> createState() => _PairingPromptState();
}

class _PairingPromptState extends State<PairingPrompt> {
  late final LayoutShareService _layoutShareService;
  PairingRequest? _shown;

  @override
  void initState() {
    super.initState();
    _layoutShareService = context.read<LayoutShareService>();
    _layoutShareService.addListener(_onChanged);
  }

  @override
  void dispose() {
    _layoutShareService.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final request = _layoutShareService.pairingRequest;
    if (request == _shown || !mounted) {
      return;
    }
    if (_shown != null) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    _shown = request;
    if (request != null) {
      _show(request);
    }
  }

  Future<void> _show(PairingRequest request) async {
    final localizations = AppLocalizations.of(context)!;
    final timeout = Future.delayed(request.expires.difference(DateTime.now()), () {
      if (mounted && _shown == request) {
        _layoutShareService.cancelPairing();
      }
    });
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text(localizations.pairingTitle(request.client)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(localizations.pairingMessage(request.client)),
            const SizedBox(height: 24),
            Text(
              request.code,
              style: Theme.of(context).textTheme.displayMedium?.copyWith(letterSpacing: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(localizations.backupCancelButton),
          ),
        ],
      ),
    );
    // Closed by the user (Cancel/Back) rather than because the pairing finished or expired.
    if (_shown == request) {
      _shown = null;
      _layoutShareService.cancelPairing();
    }
    timeout.ignore();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
