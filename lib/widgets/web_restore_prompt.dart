import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Asks on screen whether a settings file uploaded through the web page may be restored.
class WebRestorePrompt extends StatefulWidget {
  final Widget child;

  const WebRestorePrompt({super.key, required this.child});

  @override
  State<WebRestorePrompt> createState() => _WebRestorePromptState();
}

class _WebRestorePromptState extends State<WebRestorePrompt> {
  late final LayoutShareService _layoutShareService;
  WebRestoreRequest? _shown;
  BuildContext? _dialogContext;

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
    final request = _layoutShareService.webRestoreRequest;
    if (request == _shown || !mounted) {
      return;
    }
    // The request ended without an answer from here (timeout, or the feature was turned off).
    final dialogContext = _dialogContext;
    _dialogContext = null;
    if (_shown != null && dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    _shown = request;
    if (request != null) {
      _show(request);
    }
  }

  Future<void> _show(WebRestoreRequest request) async {
    final localizations = AppLocalizations.of(context)!;
    final approved = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        _dialogContext = dialogContext;
        return AlertDialog(
          title: Text(localizations.webRestoreTitle),
          content: Text(localizations.webRestoreMessage(request.source, request.sections)),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(localizations.backupCancelButton),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(localizations.backupRestoreButton),
            ),
          ],
        );
      },
    );
    if (_shown == request) {
      _shown = null;
      _dialogContext = null;
      _layoutShareService.answerWebRestore(approved == true);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
