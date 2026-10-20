import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/create_vault_screen.dart';
import 'screens/freezer_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/unlock_screen.dart';
import 'screens/vault_screen.dart';
import 'state/chest_controller.dart';
import 'theme/chest_theme.dart';

/// Root widget.
class ChestApp extends StatelessWidget {
  const ChestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chest',
      debugShowCheckedModeBanner: false,
      theme: ChestTheme.dark(),
      home: const _ChestShell(),
    );
  }
}

/// Routes between the vault, the freezer and settings, and enforces the
/// auto-lock on lifecycle changes.
class _ChestShell extends StatefulWidget {
  const _ChestShell();

  @override
  State<_ChestShell> createState() => _ChestShellState();
}

class _ChestShellState extends State<_ChestShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChestController>().initialise();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = context.read<ChestController>();
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Backgrounding is treated as a lock trigger. A vault that stays
        // unlocked while the app is off screen is the most likely way for its
        // contents to be seen by whoever picks the phone up next.
        controller.lock();
      case AppLifecycleState.resumed:
        controller.noteActivity();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();

    final Widget screen;
    switch (controller.route) {
      case ChestRoute.onboarding:
        screen = const CreateVaultScreen();
      case ChestRoute.unlock:
        screen = const UnlockScreen();
      case ChestRoute.vault:
        screen = const VaultScreen();
      case ChestRoute.freezer:
        screen = const FreezerScreen();
      case ChestRoute.settings:
        screen = const SettingsScreen();
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => controller.noteActivity(),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        child: KeyedSubtree(
          key: ValueKey(controller.route),
          child: _ScreenScaffold(route: controller.route, child: screen),
        ),
      ),
    );
  }
}

/// Adds the bottom navigation for the two primary destinations.
class _ScreenScaffold extends StatelessWidget {
  const _ScreenScaffold({required this.route, required this.child});

  final ChestRoute route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<ChestController>();

    final showBar = route == ChestRoute.vault || route == ChestRoute.freezer;
    if (!showBar) return child;

    final index = route == ChestRoute.freezer ? 1 : 0;

    return Scaffold(
      body: child,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: ChestTheme.hairline)),
        ),
        child: NavigationBar(
          height: 62,
          backgroundColor: ChestTheme.obsidian,
          indicatorColor: ChestTheme.gold.withValues(alpha: 0.14),
          selectedIndex: index,
          onDestinationSelected: (value) => controller.goTo(
            value == 1 ? ChestRoute.freezer : ChestRoute.vault,
          ),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined, color: ChestTheme.muted),
              selectedIcon: Icon(Icons.inventory_2, color: ChestTheme.gold),
              label: 'Chest',
            ),
            NavigationDestination(
              icon: Icon(Icons.ac_unit, color: ChestTheme.muted),
              selectedIcon: Icon(Icons.ac_unit, color: ChestTheme.gold),
              label: 'Freezer',
            ),
          ],
        ),
      ),
    );
  }
}
