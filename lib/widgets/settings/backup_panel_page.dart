import 'dart:io';

import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/widgets/rounded_switch_list_tile.dart';
import 'package:flauncher/widgets/settings/focusable_settings_tile.dart';
import 'package:flauncher/widgets/settings/settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

class BackupPanelPage extends StatefulWidget {
  static const String routeName = "backup_panel";

  const BackupPanelPage({super.key});

  @override
  State<BackupPanelPage> createState() => _BackupPanelPageState();
}

class _BackupPanelPageState extends State<BackupPanelPage> {
  List<File> _backups = const [];
  String? _folder;
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    final backupService = context.read<BackupService>();
    final folder = (await backupService.backupDirectory()).path;
    final backups = await backupService.listBackups();
    if (mounted) {
      setState(() {
        _folder = folder;
        _backups = backups;
      });
    }
  }

  Future<void> _exportNow() async {
    final localizations = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final file = await context.read<BackupService>().exportToFile();
      _status = localizations.backupExported(path.basename(file.path));
    } catch (e) {
      _status = localizations.backupExportFailed(e.toString());
    }
    await _loadBackups();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _restore(File file) async {
    final localizations = AppLocalizations.of(context)!;
    final backupService = context.read<BackupService>();
    final fileName = path.basename(file.path);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.backupRestoreConfirmTitle),
        content: Text(localizations.backupRestoreConfirmMessage(fileName)),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(localizations.backupCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(localizations.backupRestoreButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await backupService.importFromFile(file);
      _status = localizations.backupRestored(result.categories, result.placedApps);
      if (result.missingApps.isNotEmpty) {
        _status = "$_status\n${localizations.backupMissingApps(result.missingApps.length)}";
      }
    } catch (e) {
      _status = localizations.backupRestoreFailed(e.toString());
    }
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final backupService = context.watch<BackupService>();
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    final captionStyle = Theme.of(context).textTheme.bodySmall;

    return Column(
      children: [
        SettingsPageHeader(title: localizations.backupAndRestore),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              RoundedSwitchListTile(
                autofocus: true,
                value: backupService.autoExportEnabled,
                onChanged: (value) async {
                  await backupService.setAutoExportEnabled(value);
                  await _loadBackups();
                },
                title: Text(localizations.backupAutoExport, style: textStyle),
                subtitle: Text(localizations.backupAutoExportDescription, style: captionStyle),
                secondary: const Icon(Icons.backup),
              ),
              FocusableSettingsTile(
                leading: const Icon(Icons.save_alt),
                title: Text(localizations.backupExportNow, style: textStyle),
                onPressed: _busy ? null : _exportNow,
              ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_status!, style: captionStyle),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(localizations.backupRestore, style: Theme.of(context).textTheme.titleSmall),
              ),
              if (_backups.isEmpty)
                Text(localizations.backupNoBackups, style: captionStyle)
              else
                for (final file in _backups)
                  FocusableSettingsTile(
                    leading: const Icon(Icons.restore),
                    title: Text(path.basename(file.path), style: textStyle),
                    onPressed: _busy ? null : () => _restore(file),
                  ),
              if (_folder != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(localizations.backupFolder(_folder!), style: captionStyle),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
