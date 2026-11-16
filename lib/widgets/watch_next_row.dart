/*
 * FLauncher
 * Copyright (C) 2021 Étienne Fesser
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:flauncher/models/watch_next_item.dart';
import 'package:flauncher/actions.dart';
import 'package:flauncher/providers/apps_service.dart';
import 'package:flauncher/providers/settings_service.dart';
import 'package:flauncher/providers/watch_next_service.dart';
import 'package:flauncher/widgets/app_card.dart';
import 'package:flauncher/widgets/app_card_contour_painter.dart';
import 'package:flauncher/widgets/watch_next_hero.dart';
import 'package:flauncher/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

void _playFocusSound(BuildContext context) {
  final settingsService = context.read<SettingsService>();
  if (settingsService.appKeyClickEnabled) {
    Feedback.forTap(context);
  } else {
    context.findRenderObject()?.sendSemanticsEvent(const TapSemanticEvent());
  }
}

const double _kWatchNextItemWidth = 360;
const double _kWatchNextItemHeight = 200;
const double _kWatchNextItemSpacing = 24;
const double _kWatchNextRowVerticalSlack = 8;

// The compact row, used with the scene clock: slim glass cards with a thumbnail.
const double _kCompactItemWidth = 236;
const double _kCompactItemHeight = 60;
const double _kCompactItemSpacing = 12;
const double _kCompactRowVerticalPadding = 8;
const double _kCompactTitleHeight = 26;

/// The height of the compact recommendations section: title, row and the gap under it.
const double kCompactWatchNextSectionHeight = _kCompactTitleHeight +
    _kCompactItemHeight +
    2 * _kCompactRowVerticalPadding +
    _kWatchNextRowVerticalSlack / 2 +
    12;
const double _kWatchNextHorizontalPadding =
    kLauncherSectionHorizontalPadding + kAppCardHorizontalPadding;

class WatchNextRow extends StatelessWidget {
  final bool isFirstSection;
  final bool isAboveDock;
  final VoidCallback? onItemFocused;

  const WatchNextRow({
    super.key,
    this.isFirstSection = false,
    this.isAboveDock = false,
    this.onItemFocused,
  });

  @override
  Widget build(BuildContext context) {
    final showWatchNext = context.select<SettingsService, bool>((s) => s.showWatchNextSection);

    if (!showWatchNext) {
      return const SizedBox.shrink();
    }

    return Selector<WatchNextService, ({bool hasPermission, List<WatchNextItem> items})>(
      selector: (_, service) => (
        hasPermission: service.hasPermission,
        items: service.items,
      ),
      builder: (context, data, child) {
        final localizations = AppLocalizations.of(context)!;
        final watchNextService = context.read<WatchNextService>();

        if (!data.hasPermission) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WatchNextSectionTitle(title: localizations.watchNextSectionTitle),
              _WatchNextPermissionBanner(
                onGrant: () => watchNextService.requestPermission(),
                onRecheck: () => watchNextService.refreshPermissionAndItems(),
              ),
              const SizedBox(height: 12),
            ],
          );
        }

        if (data.items.isEmpty) {
          return const SizedBox.shrink();
        }

        final isBigPicture = context.select<SettingsService, bool>((s) => s.watchNextBigPictureMode);
        final compact = !isBigPicture && context.select<SettingsService, bool>((s) => s.sceneClockEnabled);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isBigPicture)
              WatchNextHero(
                items: data.items,
                isFirstSection: isFirstSection,
                handleUpNavigationToSettings: isAboveDock,
                onItemFocused: onItemFocused,
              )
            else ...[
              if (compact) _CompactSectionTitle(title: localizations.watchNextSectionTitle),
              _WatchNextCleanRow(
                items: data.items,
                isFirstSection: isFirstSection,
                handleUpNavigationToSettings: isAboveDock,
                onItemFocused: onItemFocused,
                compact: compact,
              ),
            ],
            SizedBox(height: isBigPicture ? 16 : 12),
          ],
        );
      },
    );
  }
}

class _WatchNextSectionTitle extends StatelessWidget {
  final String title;

  const _WatchNextSectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 40, bottom: 8, top: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge!.copyWith(
          shadows: const [
            Shadow(
              color: Colors.black54,
              offset: Offset(1, 1),
              blurRadius: 8,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactSectionTitle extends StatelessWidget {
  final String title;

  const _CompactSectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kCompactTitleHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: _kWatchNextHorizontalPadding, top: 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: Colors.white.withValues(alpha: 0.9),
            fontWeight: FontWeight.w500,
            shadows: const [Shadow(color: Colors.black54, offset: Offset(0, 1), blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}

class _WatchNextPermissionBanner extends StatelessWidget {
  final VoidCallback onGrant;
  final VoidCallback onRecheck;

  const _WatchNextPermissionBanner({
    required this.onGrant,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Icon(Icons.tv, size: 36),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localizations.watchNextPermissionTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      localizations.watchNextPermissionBody,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: onGrant,
                    icon: const Icon(Icons.lock_open),
                    label: Text(localizations.watchNextGrantPermission),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onRecheck,
                    icon: const Icon(Icons.refresh),
                    label: Text(localizations.watchNextCheckPermission),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchNextCleanRow extends StatefulWidget {
  final List<WatchNextItem> items;
  final bool isFirstSection;
  final bool handleUpNavigationToSettings;
  final VoidCallback? onItemFocused;
  final bool compact;

  const _WatchNextCleanRow({
    required this.items,
    this.isFirstSection = false,
    this.handleUpNavigationToSettings = false,
    this.onItemFocused,
    this.compact = false,
  });

  @override
  State<_WatchNextCleanRow> createState() => _WatchNextCleanRowState();
}

class _WatchNextCleanRowState extends State<_WatchNextCleanRow> {
  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _focusNodes = [];
  double? _lastScrollTarget;

  @override
  void initState() {
    super.initState();
    _createFocusNodes();
  }

  @override
  void didUpdateWidget(covariant _WatchNextCleanRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _disposeFocusNodes();
      _createFocusNodes();
    }
  }

  void _createFocusNodes() {
    _focusNodes.clear();
    for (int i = 0; i < widget.items.length; i++) {
      _focusNodes.add(FocusNode());
    }
  }

  void _disposeFocusNodes() {
    for (var node in _focusNodes) {
      node.dispose();
    }
    _focusNodes.clear();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _disposeFocusNodes();
    super.dispose();
  }

  KeyEventResult _handleNavigationKey(int index, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowRight && index < widget.items.length - 1) {
      _focusNodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && index > 0) {
      _focusNodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  double get _itemWidth => widget.compact ? _kCompactItemWidth : _kWatchNextItemWidth;
  double get _itemSpacing => widget.compact ? _kCompactItemSpacing : _kWatchNextItemSpacing;

  void _onFocusChanged(int index, bool focused) {
    if (widget.compact) {
      // The scene clock takes its colours from the focused recommendation.
      final service = context.read<WatchNextService>();
      final item = widget.items[index];
      if (focused) {
        service.setFocusedItem(item);
      } else if (service.focusedItem?.id == item.id) {
        service.setFocusedItem(null);
      }
    }
    if (focused) {
      widget.onItemFocused?.call();
      _scrollToIndex(index);
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final viewportWidth = position.viewportDimension;
    final slotWidth = _itemWidth + _itemSpacing;

    final cardStart = _kWatchNextHorizontalPadding + index * slotWidth;
    final cardCenter = cardStart + _itemWidth / 2;
    final targetOffset = (cardCenter - viewportWidth / 2).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    const minDelta = 8.0;
    if ((position.pixels - targetOffset).abs() < minDelta) {
      return;
    }
    if (_lastScrollTarget != null && (_lastScrollTarget! - targetOffset).abs() < minDelta) {
      return;
    }

    _lastScrollTarget = targetOffset;
    position.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    return SizedBox(
      height: compact
          ? _kCompactItemHeight + 2 * _kCompactRowVerticalPadding + _kWatchNextRowVerticalSlack / 2
          : _kWatchNextItemHeight + 24 + _kWatchNextRowVerticalSlack,
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: _kWatchNextHorizontalPadding,
          vertical: compact ? _kCompactRowVerticalPadding : 12,
        ),
        itemExtent: _itemWidth + _itemSpacing,
        addSemanticIndexes: false,
        addRepaintBoundaries: true,
        itemCount: widget.items.length,
        itemBuilder: (context, index) {
          final item = widget.items[index];
          return _WatchNextCard(
            item: item,
            focusNode: _focusNodes[index],
            autofocus: widget.isFirstSection && index == 0,
            onFocusChanged: (focused) => _onFocusChanged(index, focused),
            onNavigationKey: (key) => _handleNavigationKey(index, key),
            handleUpNavigationToSettings: widget.handleUpNavigationToSettings,
            compact: compact,
          );
        },
      ),
    );
  }
}

class _WatchNextCard extends StatefulWidget {
  final WatchNextItem item;
  final FocusNode focusNode;
  final bool autofocus;
  final ValueChanged<bool> onFocusChanged;
  final KeyEventResult Function(LogicalKeyboardKey key) onNavigationKey;
  final bool handleUpNavigationToSettings;
  final bool compact;

  const _WatchNextCard({
    required this.item,
    required this.focusNode,
    this.autofocus = false,
    required this.onFocusChanged,
    required this.onNavigationKey,
    this.handleUpNavigationToSettings = false,
    this.compact = false,
  });

  @override
  State<_WatchNextCard> createState() => _WatchNextCardState();
}

class _WatchNextCardState extends State<_WatchNextCard> {
  bool _isHovered = false;
  bool _clicked = false;
  static const double _focusedScale = 1.06;
  static const double _focusedLift = -4.0;

  @override
  void initState() {
    super.initState();
    final uri = context.read<WatchNextService>().getPosterUriForItem(widget.item);
    context.read<WatchNextService>().ensurePosterLoaded(uri);
  }

  @override
  void didUpdateWidget(covariant _WatchNextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _isHovered = widget.focusNode.hasFocus;
    }
    final oldUri = context.read<WatchNextService>().getPosterUriForItem(oldWidget.item);
    final newUri = context.read<WatchNextService>().getPosterUriForItem(widget.item);
    if (oldUri != newUri) {
      context.read<WatchNextService>().ensurePosterLoaded(newUri);
    }
  }

  void _handleTap() {
    _triggerLaunchWithFeedback();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowRight:
          return widget.onNavigationKey(event.logicalKey);
        case LogicalKeyboardKey.arrowUp:
          if (widget.handleUpNavigationToSettings) {
            Actions.invoke(context, const MoveFocusToSettingsIntent());
            return KeyEventResult.handled;
          }
          break;
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
          _triggerLaunchWithFeedback();
          return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _triggerLaunchWithFeedback() {
    if (_clicked) return;
    setState(() => _clicked = true);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      context.read<WatchNextService>().launchItem(widget.item);
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _clicked = false);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final (posterData, posterLoadFailed) = context.select<WatchNextService, (Uint8List?, bool)>(
      (service) {
        final uri = service.getPosterUriForItem(widget.item);
        return (
          service.getCachedPoster(uri),
          service.hasPosterLoadFailed(uri),
        );
      },
    );
    final targetScale = _clicked ? 0.97 : (_isHovered ? _focusedScale : 1.0);
    final targetLift = _isHovered && !_clicked ? _focusedLift : 0.0;
    final (bool showFocusBorders, double borderThickness) = context.select<SettingsService, (bool, double)>(
      (s) => (s.showFocusBorders, s.focusBorderThickness),
    );


    return Padding(
      padding: EdgeInsets.only(right: widget.compact ? _kCompactItemSpacing : _kWatchNextItemSpacing),
      child: RepaintBoundary(
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (focused) {
            if (_isHovered == focused) return;
            setState(() => _isHovered = focused);
            if (focused) {
              _playFocusSound(context);
            }
            widget.onFocusChanged(focused);
          },
          child: GestureDetector(
            onTap: _handleTap,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: targetLift),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              builder: (context, lift, child) {
                return Transform.translate(offset: Offset(0, lift), child: child);
              },
              child: AnimatedScale(
                scale: targetScale,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: widget.compact ? _buildCompactCard(posterData) : Card(
                  margin: EdgeInsets.zero,
                  elevation: _isHovered ? 6 : 2,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SizedBox(
                    width: _kWatchNextItemWidth,
                    height: _kWatchNextItemHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildPoster(posterData, posterLoadFailed),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _buildCardLabels(showDescription: _isHovered),
                        ),
                        if (_isHovered) _buildProgressIndicator(),
                        if (_isHovered && showFocusBorders)
                          IgnorePointer(
                            child: CustomPaint(
                              foregroundPainter: AppCardContourPainter(
                                radius: 8,
                                strokeWidth: borderThickness,
                                accentColor: Theme.of(context).colorScheme.primary,
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        if (!_isHovered) const IgnorePointer(child: ColoredBox(color: Color(0x1A000000))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A slim glass card: thumbnail, app name, title and progress.
  Widget _buildCompactCard(Uint8List? posterData) {
    final appName = context.select<AppsService, String?>(
      (service) => service.getApplication(widget.item.packageName)?.name,
    );
    final progress = widget.item.progressPercent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: _kCompactItemWidth,
      height: _kCompactItemHeight,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: _isHovered ? const Color(0x47FFFFFF) : const Color(0x8C12161C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _isHovered ? const Color(0xD9FFFFFF) : const Color(0x2EFFFFFF),
          width: _isHovered ? 1.5 : 1,
        ),
        boxShadow: const [BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 88,
              height: _kCompactItemHeight - 10,
              child: posterData != null
                  ? Image.memory(
                      posterData,
                      fit: BoxFit.cover,
                      cacheWidth: 176,
                      filterQuality: FilterQuality.low,
                    )
                  : ColoredBox(
                      color: Colors.grey.shade800,
                      child: const Icon(Icons.play_circle_outline, size: 20, color: Colors.white70),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (appName != null)
                  Text(
                    appName.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 8,
                      letterSpacing: 0.6,
                    ),
                  ),
                Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (progress != null && progress > 0) ...[
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress / 100.0,
                      minHeight: 2.5,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPoster(Uint8List? posterData, bool posterLoadFailed) {
    if (posterData != null) {
      return Image.memory(
        posterData,
        fit: BoxFit.cover,
        width: _kWatchNextItemWidth,
        height: _kWatchNextItemHeight,
        cacheWidth: _kWatchNextItemWidth.toInt(),
        cacheHeight: _kWatchNextItemHeight.toInt(),
        filterQuality: FilterQuality.low,
      );
    }

    return Container(
      color: Colors.grey.shade800,
      child: widget.item.posterUri != null && !posterLoadFailed
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _buildFallbackWidget(),
    );
  }

  Widget _buildFallbackWidget() {
    final localizations = AppLocalizations.of(context)!;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.play_circle_outline,
          size: 40,
          color: Colors.white70,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              Text(
                widget.item.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                localizations.watchNextSectionTitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCardLabels({required bool showDescription}) {
    final localizations = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.0),
            Colors.black.withOpacity(_isHovered ? 0.7 : 0.55),
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            localizations.watchNextSectionTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 10,
            ),
          ),
          if (showDescription && widget.item.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.item.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    if (widget.item.progressPercent == null || widget.item.progressPercent == 0) {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(
        value: widget.item.progressPercent! / 100.0,
        backgroundColor: Colors.white24,
        valueColor: AlwaysStoppedAnimation<Color>(
          Theme.of(context).colorScheme.primary,
        ),
        minHeight: 3,
      ),
    );
  }
}
