/*
 * FLauncher
 * Copyright (C) 2024 Oscar Rojas
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:flauncher/providers/quick_actions_service.dart';
import 'package:flauncher/providers/weather_service.dart';
import 'package:flauncher/widgets/rounded_switch_list_tile.dart';
import 'package:flauncher/widgets/settings/focusable_settings_tile.dart';
import 'package:flauncher/widgets/settings/settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flauncher/l10n/app_localizations.dart';

import '../../providers/settings_service.dart';

class StatusBarPanelPage extends StatelessWidget {
  static const String routeName = "status_bar_panel";

  @override
  Widget build(BuildContext context) {
    AppLocalizations localizations = AppLocalizations.of(context)!;
    SettingsService settingsService = Provider.of(context);

    return Column(
        children: [
          SettingsPageHeader(title: localizations.statusBar),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                RoundedSwitchListTile(
                  autofocus: true,
                  value: settingsService.autoHideAppBarEnabled,
                  onChanged: (value) => settingsService.setAutoHideAppBarEnabled(value),
                  title: Text(localizations.autoHideAppBar, style: Theme.of(context).textTheme.bodyMedium),
                  secondary: const Icon(Icons.visibility_off_outlined),
                ),
                RoundedSwitchListTile(
                  value: settingsService.hideStatusBarInGrid,
                  onChanged: (value) => settingsService.setHideStatusBarInGrid(value),
                  title: Text(localizations.hideStatusBarInGrid, style: Theme.of(context).textTheme.bodyMedium),
                  secondary: const Icon(Icons.grid_view_outlined),
                ),
                const SettingsSectionDivider(),
                RoundedSwitchListTile(
                  value: settingsService.showDateInStatusBar,
                  onChanged: (value) => settingsService.setShowDateInStatusBar(value),
                  title: Text(localizations.date),
                  secondary: Icon(Icons.calendar_today_outlined)
                ),
                RoundedSwitchListTile(
                  value: settingsService.showTimeInStatusBar,
                  onChanged: (value) => settingsService.setShowTimeInStatusBar(value),
                  title: Text(localizations.time),
                  secondary: Icon(Icons.watch_later_outlined)
                ),
                RoundedSwitchListTile(
                  value: settingsService.showWifiWidgetInStatusBar,
                  onChanged: (value) => settingsService.setShowWifiWidgetInStatusBar(value),
                  title: Text(localizations.wifiUsage),
                  secondary: Icon(Icons.wifi)
                ),
                RoundedSwitchListTile(
                  value: settingsService.showNetworkIndicatorInStatusBar,
                  onChanged: (value) => settingsService.setShowNetworkIndicatorInStatusBar(value),
                  title: Text(localizations.networkIndicator),
                  secondary: Icon(Icons.signal_wifi_4_bar)
                ),
                ..._weatherTiles(context, localizations),
                ..._quickActionTiles(context, localizations),
              ],
            ),
          ),
        ],
      );
  }

  List<Widget> _weatherTiles(BuildContext context, AppLocalizations localizations) {
    final weatherService = context.watch<WeatherService?>();
    if (weatherService == null) {
      return const [];
    }
    final captionStyle = Theme.of(context).textTheme.bodySmall;
    return [
      const SettingsSectionDivider(),
      RoundedSwitchListTile(
        value: weatherService.enabled,
        onChanged: (value) => weatherService.setEnabled(value),
        title: Text(localizations.weatherTitle),
        secondary: const Icon(Icons.wb_sunny_outlined),
      ),
      FocusableSettingsTile(
        leading: const Icon(Icons.place_outlined),
        title: Text(localizations.weatherLocation, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(weatherService.locationName ?? localizations.weatherLocationNotSet, style: captionStyle),
        onPressed: () => _pickLocation(context, localizations, weatherService),
      ),
      RoundedSwitchListTile(
        value: weatherService.fahrenheit,
        onChanged: (value) => weatherService.setFahrenheit(value),
        title: Text(localizations.weatherFahrenheit),
        secondary: const Icon(Icons.thermostat_outlined),
      ),
    ];
  }

  Future<void> _pickLocation(
      BuildContext context, AppLocalizations localizations, WeatherService weatherService) async {
    final query = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        insetPadding: const EdgeInsets.only(bottom: 120),
        contentPadding: const EdgeInsets.all(24),
        title: Text(localizations.weatherLocation),
        children: [
          TextFormField(
            autofocus: true,
            decoration: InputDecoration(hintText: localizations.weatherSearchHint),
            onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
    );
    if (query == null || query.trim().isEmpty || !context.mounted) {
      return;
    }
    final search = weatherService.search(query, language: Localizations.localeOf(context).languageCode);
    final place = await showDialog<WeatherPlace>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(localizations.weatherLocation),
        contentPadding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<List<WeatherPlace>>(
            future: search,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Text(localizations.weatherSearchFailed(snapshot.error.toString()));
              }
              final places = snapshot.data ?? const <WeatherPlace>[];
              if (places.isEmpty) {
                return Text(localizations.weatherNoPlaces);
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < places.length; i++)
                    FocusableSettingsTile(
                      autofocus: i == 0,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(places[i].label),
                      onPressed: () => Navigator.of(context).pop(places[i]),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (place != null) {
      await weatherService.setLocation(place);
      if (!weatherService.enabled) {
        await weatherService.setEnabled(true);
      }
    }
  }

  List<Widget> _quickActionTiles(BuildContext context, AppLocalizations localizations) {
    final quickActionsService = context.watch<QuickActionsService?>();
    if (quickActionsService == null) {
      return const [];
    }
    final count = quickActionsService.actions.length;
    return [
      const SettingsSectionDivider(),
      FocusableSettingsTile(
        leading: const Icon(Icons.touch_app_outlined),
        title: Text(localizations.quickActionsTitle, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: Text(
          count == 0 ? localizations.quickActionsNone : localizations.quickActionsCount(count),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        onPressed: count == 0 ? null : () => quickActionsService.clear(),
        trailing: count == 0 ? null : Text(localizations.quickActionsRemoveAll),
      ),
    ];
  }
}
