import 'dart:io';

import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flauncher/providers/backup_service.dart';
import 'package:flauncher/providers/layout_share_service.dart';
import 'package:flauncher/providers/remote_sync_service.dart';
import 'package:flauncher/widgets/rounded_switch_list_tile.dart';
import 'package:flauncher/widgets/settings/focusable_settings_tile.dart';
import 'package:flauncher/widgets/settings/settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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

  List<Widget> _remoteSyncTiles(BuildContext context, AppLocalizations localizations) {
    final remoteSyncService = context.watch<RemoteSyncService>();
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    final captionStyle = Theme.of(context).textTheme.bodySmall;
    final lastCheck = remoteSyncService.lastCheck;

    String? status;
    if (remoteSyncService.syncing) {
      status = localizations.remoteSyncInProgress;
    } else if (remoteSyncService.lastError != null) {
      status = localizations.remoteSyncFailed(remoteSyncService.lastError!);
    } else if (lastCheck != null) {
      status = localizations.remoteSyncLastCheck(DateFormat.yMd().add_Hm().format(lastCheck));
      final result = remoteSyncService.lastResult;
      if (result != null) {
        status = "$status\n${localizations.backupRestored(result.categories, result.placedApps)}";
      }
    }

    return [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(localizations.remoteSyncTitle, style: Theme.of(context).textTheme.titleSmall),
      ),
      FocusableSettingsTile(
        showChevron: true,
        leading: const Icon(Icons.connected_tv),
        title: Text(localizations.layoutFollowTv, style: textStyle),
        subtitle: remoteSyncService.followedName == null
            ? null
            : Text(localizations.layoutFollowing(remoteSyncService.followedName!), style: captionStyle),
        onPressed: () => _pickTvToFollow(context, localizations, remoteSyncService),
      ),
      FocusableSettingsTile(
        leading: const Icon(Icons.link),
        title: Text(localizations.remoteSyncAddress, style: textStyle),
        subtitle: Text(
          remoteSyncService.url.isEmpty ? localizations.remoteSyncAddressNotSet : remoteSyncService.url,
          style: captionStyle,
        ),
        onPressed: () => _editRemoteUrl(context, localizations, remoteSyncService),
      ),
      if (remoteSyncService.url.isNotEmpty) ...[
        RoundedSwitchListTile(
          value: remoteSyncService.enabled,
          onChanged: (value) => remoteSyncService.setEnabled(value),
          title: Text(localizations.remoteSyncAutomatic, style: textStyle),
          subtitle: Text(localizations.remoteSyncAutomaticDescription, style: captionStyle),
          secondary: const Icon(Icons.sync),
        ),
        FocusableSettingsTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: Text(localizations.remoteSyncNow, style: textStyle),
          onPressed: remoteSyncService.syncing ? null : () => remoteSyncService.syncNow(force: true),
        ),
      ],
      if (status != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(status, style: captionStyle),
        ),
    ];
  }

  List<Widget> _shareTiles(BuildContext context, AppLocalizations localizations) {
    final layoutShareService = context.watch<LayoutShareService>();
    final captionStyle = Theme.of(context).textTheme.bodySmall;

    final String subtitle;
    if (layoutShareService.error != null) {
      subtitle = localizations.layoutShareFailed(layoutShareService.error!);
    } else if (layoutShareService.running && layoutShareService.name != null) {
      subtitle = localizations.layoutShareActive(layoutShareService.name!);
    } else {
      subtitle = localizations.layoutShareDescription;
    }

    return [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(localizations.layoutShareTitle, style: Theme.of(context).textTheme.titleSmall),
      ),
      RoundedSwitchListTile(
        value: layoutShareService.enabled,
        onChanged: (value) => layoutShareService.setEnabled(value),
        title: Text(localizations.layoutShareSwitch, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(subtitle, style: captionStyle),
        secondary: const Icon(Icons.cast_connected),
      ),
      RoundedSwitchListTile(
        value: layoutShareService.controlEnabled,
        onChanged: (value) => layoutShareService.setControlEnabled(value),
        title: Text(localizations.controlSwitch, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(localizations.controlDescription, style: captionStyle),
        secondary: const Icon(Icons.settings_remote),
      ),
      if (layoutShareService.controlEnabled) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(localizations.controlPairedApps, style: captionStyle),
        ),
        if (layoutShareService.clients.isEmpty)
          Text(localizations.controlNoPairedApps, style: captionStyle)
        else
          for (final client in layoutShareService.clients)
            FocusableSettingsTile(
              leading: const Icon(Icons.link_off),
              title: Text(client.name, style: Theme.of(context).textTheme.bodyMedium),
              subtitle: Text(DateFormat.yMd().format(client.created.toLocal()), style: captionStyle),
              onPressed: () => _removeClient(context, localizations, layoutShareService, client),
            ),
      ],
    ];
  }

  Future<void> _removeClient(BuildContext context, AppLocalizations localizations,
      LayoutShareService layoutShareService, PairedClient client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.controlRemoveTitle(client.name)),
        content: Text(localizations.controlRemoveMessage),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(localizations.backupCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(localizations.controlRemoveButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await layoutShareService.removeClient(client.token);
    }
  }

  Future<void> _pickTvToFollow(
      BuildContext context, AppLocalizations localizations, RemoteSyncService remoteSyncService) async {
    final scan = const LayoutDiscovery().scan();
    final source = await showDialog<SharedLayoutSource>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(localizations.layoutFollowTv),
        contentPadding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<List<SharedLayoutSource>>(
            future: scan,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Row(
                  children: [
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 16),
                    Text(localizations.layoutFollowSearching),
                  ],
                );
              }
              final sources = snapshot.data ?? const <SharedLayoutSource>[];
              if (sources.isEmpty) {
                return Text(localizations.layoutFollowNoneFound);
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < sources.length; i++)
                    FocusableSettingsTile(
                      autofocus: i == 0,
                      leading: const Icon(Icons.tv),
                      title: Text(sources[i].name),
                      subtitle: Text(sources[i].host),
                      onPressed: () => Navigator.of(context).pop(sources[i]),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (source != null) {
      await remoteSyncService.follow(source.name, source.backupUrl, id: source.id);
    }
  }

  Future<void> _editRemoteUrl(
      BuildContext context, AppLocalizations localizations, RemoteSyncService remoteSyncService) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        insetPadding: const EdgeInsets.only(bottom: 120),
        contentPadding: const EdgeInsets.all(24),
        title: Text(localizations.remoteSyncAddress),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(localizations.remoteSyncAddressHelp),
          ),
          TextFormField(
            autofocus: true,
            initialValue: remoteSyncService.url,
            keyboardType: TextInputType.url,
            onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
    );
    if (value == null) {
      return;
    }
    try {
      await remoteSyncService.setUrl(value);
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _status = localizations.remoteSyncFailed(e.message));
      }
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
              ..._shareTiles(context, localizations),
              ..._remoteSyncTiles(context, localizations),
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
