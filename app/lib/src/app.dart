import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/library/library_screen.dart';
import 'features/setlists/setlists_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/viewer/score_viewer_screen.dart';
import 'providers/accessibility_providers.dart';
import 'theme/fermata_theme.dart';

class FermataApp extends ConsumerWidget {
  const FermataApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(textScaleProvider);
    return MaterialApp(
      title: 'Fermata',
      debugShowCheckedModeBanner: false,
      theme: FermataTheme.light(),
      darkTheme: FermataTheme.dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: const AppShell(),
    );
  }
}

/// Root navigation.
///
/// Deliberately a plain [Navigator] with pushed routes rather than a routing
/// package: the app has a library, a viewer, and later a setlists and settings
/// tab, which is not enough surface to justify the dependency yet.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          LibraryScreen(onOpenScore: _openScore),
          SetlistsScreen(onOpenScore: _openScore),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music_rounded),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music_rounded),
            label: 'Setlists',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  void _openScore(Score score) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScoreViewerScreen(scoreId: score.id, title: score.title),
      ),
    );
  }
}
