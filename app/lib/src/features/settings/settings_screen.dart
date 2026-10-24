import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/accessibility_providers.dart';
import '../../providers/backup_providers.dart';
import '../../providers/platform_bridge.dart';
import '../../update/obtainium_app.dart';
import '../../update/update_service.dart';

/// Settings, which currently holds updates and nothing else.
///
/// Pedal mappings, text scaling and backup (DESIGN.md §6.7-8) land here. The
/// screen exists now because update checking has to be somewhere, and a tab
/// whose entire content is "coming soon" is not a place to put it.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: const [
          _Title(),
          _SectionHeader('Updates'),
          _UpdateTile(),
          _ObtainiumTile(),
          _SectionHeader('Coming later'),
          _PendingTile(
            // No pedal glyph exists in Material Symbols' published subset at
            // a round weight; a keyboard is the closest honest picture of what
            // the milestone actually consumes (DESIGN.md §7: HID key events).
            icon: Icons.keyboard_rounded,
            title: 'Page-turn pedal',
            subtitle: 'Bind a Bluetooth pedal to next/previous page.',
          ),
          _TextScaleTile(),
          _BackupTile(),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text('Settings', style: theme.textTheme.headlineMedium),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _BackupTile extends ConsumerWidget {
  const _BackupTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messenger = ScaffoldMessenger.of(context);
    return ListTile(
      leading: const Icon(Icons.archive_rounded),
      title: const Text('Backup and restore'),
      subtitle: const Text('Export the library and annotations to a file.'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final service = await ref.read(backupServiceProvider.future);
        final file = await service.exportAll();
        if (!context.mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text('Backup written to ${file.path}')),
        );
      },
    );
  }
}

class _TextScaleTile extends ConsumerWidget {
  const _TextScaleTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(textScaleProvider);
    return ListTile(
      leading: const Icon(Icons.text_fields_rounded),
      title: const Text('Text size'),
      subtitle: Slider(
        value: scale,
        min: 0.8,
        max: 1.6,
        divisions: 8,
        label: scale.toStringAsFixed(2),
        onChanged: (value) =>
            ref.read(textScaleProvider.notifier).setScale(value),
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: false,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

/// Checks GitHub releases and reports whether the installed build is current.
///
/// The check is manual, not on launch. Obtainium's entire reason to exist is
/// that it runs these checks in the background on a schedule; a second poller
/// inside the app would spend the user's battery to reach the same answer, and
/// would still be wrong whenever the phone is offline at the wrong moment.
class _UpdateTile extends ConsumerWidget {
  const _UpdateTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final check = ref.watch(updateCheckProvider);
    final result = check.value;

    return ListTile(
      leading: const Icon(Icons.system_update_rounded),
      title: const Text('Check for updates'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Installed version: ${_installedLabel(result)}'),
          // `isLoading` rather than an AsyncData branch: a re-check keeps the
          // previous answer on screen, so the tile does not collapse into a
          // spinner and take the text the user is reading with it.
          if (check.isLoading)
            Text(
              'Checking GitHub releases…',
              style: theme.textTheme.bodySmall,
            )
          else
            Text(
              _resultLabel(result),
              style: theme.textTheme.bodySmall?.copyWith(
                color: switch (result) {
                  UpdateAvailable() => theme.colorScheme.primary,
                  UpdateCheckFailed() => theme.colorScheme.error,
                  _ => null,
                },
              ),
            ),
        ],
      ),
      trailing: const Icon(Icons.refresh_rounded),
      onTap: () => ref.invalidate(updateCheckProvider),
    );
  }

  /// `unknown` while the check is still running or has failed: the installed
  /// version comes from the same round trip as the answer, so there is nothing
  /// to show until it lands.
  static String _installedLabel(UpdateCheck? result) {
    return switch (result) {
      UpToDate(:final installed) => installed.versionName,
      UpdateAvailable(:final installed) => installed.versionName,
      _ => 'unknown',
    };
  }

  static String _resultLabel(UpdateCheck? result) {
    return switch (result) {
      UpToDate() => 'Up to date.',
      UpdateAvailable(:final latest) => 'Fermata ${latest.version} is available.',
      UpdateCheckFailed(:final message) => 'Could not check: $message',
      null => 'Not checked yet.',
    };
  }
}

/// The hand-off to Obtainium.
///
/// Present whether or not an update is pending, because the most common first
/// encounter is a user who heard about the app through Obtainium and has
/// nothing installed to update from. See `docs/obtainium.md` for the installer
/// side.
class _ObtainiumTile extends ConsumerWidget {
  const _ObtainiumTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final check = ref.watch(updateCheckProvider);

    return ListTile(
      leading: const Icon(Icons.download_rounded),
      title: const Text('Install and update with Obtainium'),
      subtitle: Text(
        switch (check.value) {
          UpdateAvailable(:final latest) => 'Fermata ${latest.version} is '
              'ready to install. Opens Obtainium to fetch it.',
          _ => 'Adds Fermata to Obtainium, which then keeps it up to date.',
        },
        style: theme.textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.open_in_new_rounded),
      onTap: () => _handOff(context, ref),
    );
  }

  Future<void> _handOff(BuildContext context, WidgetRef ref) async {
    final launcher = ref.read(uriLauncherProvider);
    final messenger = ScaffoldMessenger.of(context);
    final obtainium = await ref.read(obtainiumAppProvider.future);

    final check = ref.read(updateCheckProvider).value;
    // Refresh rather than add once an update is known to be pending: the
    // `app` deep link opens the Add screen, which is the wrong screen for
    // someone who already has Fermata tracked and wants the new build.
    final link = check is UpdateAvailable
        ? obtainium.refreshLink
        : obtainium.addLink;

    final opened = await launcher.open(link);
    if (!context.mounted) return;

    if (opened) return;

    // Nothing on the device handles `obtainium://`. Say so, and offer the two
    // things that do work: the website, and a copyable link for a message to
    // someone who does have it.
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded),
        title: const Text('Obtainium is not installed'),
        content: Text(
          'Install Obtainium, then tap again. Or send this link to a device '
          'that has it:\n\n${obtainium.addLinkText}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Clipboard.setData(ClipboardData(text: obtainium.addLinkText));
              messenger.showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            },
            child: const Text('Copy link'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              launcher.open(Uri.parse(kObtainiumWebsite));
            },
            child: const Text('Get Obtainium'),
          ),
        ],
      ),
    );
  }
}

/// Obtainium's own site, for the "not installed" fallback.
const kObtainiumWebsite = 'https://obtainium.imranr.dev/';