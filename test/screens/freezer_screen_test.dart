import 'package:chest/screens/freezer_screen.dart';
import 'package:chest/state/chest_controller.dart';
import 'package:chest/theme/chest_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Answers the app-lock channel the way the Android layer would.
///
/// The real [AppLockBridge], [ChestController] and [FreezerScreen] all run; only
/// the platform boundary is replaced. The channel replies are raw maps, exactly
/// as Kotlin sends them, so the Dart parsing is exercised too.
class FakeAppLockChannel {
  FakeAppLockChannel({Map<String, Object?>? capabilities})
      : capabilities = capabilities ?? _notProvisioned;

  /// The capabilities map the fake device reports.
  Map<String, Object?> capabilities;

  /// A device that has not been provisioned as device owner.
  static const Map<String, Object?> _notProvisioned = {
    'deviceOwnerActive': false,
    'profileOwnerActive': false,
    'deviceAdminActive': false,
    'accessibilityEnabled': true,
    'hiddenCount': 0,
    'sdkInt': 34,
  };

  /// The apps the fake device reports.
  List<Map<String, Object?>> apps = [
    {
      'packageName': 'com.example.photos',
      'label': 'Photos',
      'isSystem': false,
      'frozen': false,
      'hidden': false,
    },
    {
      'packageName': 'com.example.chat',
      'label': 'Chat',
      'isSystem': false,
      'frozen': true,
      'hidden': true,
    },
    {
      'packageName': 'android.system.settings',
      'label': 'Settings',
      'isSystem': true,
      'frozen': false,
      'hidden': false,
    },
  ];

  /// Package names that were frozen or unfrozen, in call order.
  final List<String> freezeCalls = [];
  final List<String> unfreezeCalls = [];

  /// Labels passed alongside each freeze, so the caching path is covered.
  final List<String> freezeLabels = [];
  final List<String> openedSettings = [];
  final List<bool> secureFlags = [];

  /// How many times the native side was asked for capabilities.
  int capabilityCalls = 0;

  /// How many times the device-admin dialog was requested.
  int adminRequests = 0;

  /// How many times the restore-all escape hatch was invoked.
  int unhideAllCalls = 0;

  static const MethodChannel _channel = MethodChannel('com.chest.chest/app_lock');

  /// The security channel, which the controller probes on refresh.
  ///
  /// An unmocked channel in flutter_test never completes its reply, so the
  /// probe must be answered or any code path that awaits it would stall.
  static const MethodChannel _securityChannel =
      MethodChannel('com.chest.chest/security');

  /// Installs the handler for the duration of a test.
  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_securityChannel, (call) async {
      if (call.method == 'hardwareSecurity') {
        return {
          'keystoreAvailable': true,
          'strongBoxAvailable': false,
          'insideSecureHardware': true,
        };
      }
      return null;
    });
    messenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'listApps':
          return apps;
        case 'capabilities':
          capabilityCalls++;
          return capabilities;
        case 'freeze':
          final args = call.arguments as Map;
          freezeCalls.add(args['packageName'] as String);
          freezeLabels.add(args['label'] as String);
          // Mirrors the native rule: only a device owner can actually hide.
          return (capabilities['deviceOwnerActive'] as bool? ?? false)
              ? {'applied': true, 'method': 'device_owner'}
              : {'applied': false, 'method': 'soft'};
        case 'unfreeze':
          final pkg = (call.arguments as Map)['packageName'] as String;
          unfreezeCalls.add(pkg);
          return {'applied': true, 'method': 'device_owner'};
        case 'unhideAll':
          unhideAllCalls++;
          return {'applied': true, 'restored': 2, 'failed': 0, 'method': 'device_owner'};
        case 'openAppDetailsSettings':
          openedSettings.add((call.arguments as Map)['packageName'] as String);
          return null;
        case 'setSecureFlag':
          secureFlags.add((call.arguments as Map)['enabled'] as bool);
          return true;
        case 'requestDeviceAdmin':
          adminRequests++;
          return null;
        case 'openAccessibilitySettings':
          return null;
        default:
          return null;
      }
    });
  }

  /// Removes the handlers.
  void remove() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(_securityChannel, null);
  }

  /// A capabilities map for a device with the given tiers active.
  static Map<String, Object?> capabilitiesFor({
    bool deviceOwnerActive = false,
    bool profileOwnerActive = false,
    bool deviceAdminActive = false,
    bool accessibilityEnabled = true,
    int hiddenCount = 0,
  }) =>
      {
        'deviceOwnerActive': deviceOwnerActive,
        'profileOwnerActive': profileOwnerActive,
        'deviceAdminActive': deviceAdminActive,
        'accessibilityEnabled': accessibilityEnabled,
        'hiddenCount': hiddenCount,
        'sdkInt': 34,
      };
}

/// Pumps the freezer on a tall viewport so the list is fully built.
Future<ChestController> pumpFreezer(
  WidgetTester tester, {
  required FakeAppLockChannel channel,
}) async {
  channel.install();
  addTearDown(channel.remove);

  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final controller = ChestController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<ChestController>.value(
      value: controller,
      child: MaterialApp(theme: ChestTheme.dark(), home: const FreezerScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('freezer enforcement panel', () {
    testWidgets('says device owner is needed when it is not set up', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('Device owner not set up'), findsOneWidget);
      expect(find.textContaining('needs to be the device owner'), findsOneWidget);
      expect(find.text('Grant device admin'), findsOneWidget);
      // The app guard is already running in the default fake.
      expect(find.text('Enable app guard'), findsNothing);
    });

    testWidgets('shows the provisioning command when not provisioned', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(
        find.text(
          'adb shell dpm set-device-owner '
          'com.chest.chest/.applock.ChestDeviceAdminReceiver',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('no accounts'), findsOneWidget);
    });

    testWidgets('reports hiding active once device owner is granted', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(
            deviceOwnerActive: true,
            accessibilityEnabled: false,
          ),
        ),
      );

      expect(find.text('Launcher hiding active'), findsOneWidget);
      expect(find.textContaining('hidden from your launcher'), findsOneWidget);
      expect(find.text('Grant device admin'), findsNothing);
      expect(find.text('Enable app guard'), findsOneWidget);
      // The setup command is no longer needed.
      expect(find.textContaining('adb shell dpm'), findsNothing);
    });

    testWidgets('device admin alone does not claim launcher hiding', (tester) async {
      // Regression guard: legacy device admin cannot call setApplicationHidden
      // on a modern target SDK, so the panel must not imply it can hide.
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(
            deviceAdminActive: true,
            accessibilityEnabled: false,
          ),
        ),
      );

      expect(find.text('Device owner not set up'), findsOneWidget);
      expect(find.text('Launcher hiding active'), findsNothing);
    });
  });

  group('freezer app list', () {
    testWidgets('lists apps with their package names', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('com.example.photos'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('1 frozen'), findsOneWidget);
    });

    testWidgets('marks a system app', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('SYSTEM'), findsOneWidget);
    });

    testWidgets('search narrows by label', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      await tester.enterText(find.byType(TextField).first, 'chat');
      await tester.pump();

      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Photos'), findsNothing);
    });

    testWidgets('search also matches a package name', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      await tester.enterText(find.byType(TextField).first, 'example.photos');
      await tester.pump();

      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Chat'), findsNothing);
    });

    testWidgets('an empty search result explains itself', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      await tester.enterText(find.byType(TextField).first, 'zzz-nothing');
      await tester.pump();

      expect(find.text('No apps to show'), findsOneWidget);
    });
  });

  group('freezer actions', () {
    testWidgets('toggling an unfrozen app hides it and badges it', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      // Photos is the only unfrozen entry, so it owns the first switch.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(channel.freezeCalls, ['com.example.photos']);
      expect(find.textContaining('hidden from the launcher'), findsOneWidget);
    });

    testWidgets('passes the label so it can be cached natively', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      // Once hidden, the app vanishes from package queries, so the native side
      // needs the label to keep listing it.
      expect(channel.freezeLabels, ['Photos']);
    });

    testWidgets('refuses to mark an app frozen without device owner', (tester) async {
      // The native layer reports applied: false, so the switch must stay off
      // rather than claiming a hide the platform did not perform.
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be hidden'), findsOneWidget);
      expect(find.text('1 frozen'), findsOneWidget);
    });

    testWidgets('toggling a frozen app unhides it', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      // Chat is the frozen entry, second in the list.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(channel.unfreezeCalls, ['com.example.chat']);
      expect(find.text('Chat is back in the launcher.'), findsOneWidget);
    });

    testWidgets('a hidden app is badged and stays listed', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
        ),
      );

      // Chat is hidden, and must remain visible in the list so it can be
      // unfrozen — that is the whole reason labels are cached natively.
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('HIDDEN'), findsOneWidget);
    });

    testWidgets('restore all is offered only when something is frozen',
        (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());
      expect(find.text('Restore all'), findsOneWidget);

      final clean = FakeAppLockChannel();
      clean.apps = [
        {
          'packageName': 'com.example.photos',
          'label': 'Photos',
          'isSystem': false,
          'frozen': false,
          'hidden': false,
        },
      ];
      await pumpFreezer(tester, channel: clean);
      expect(find.text('Restore all'), findsNothing);
    });

    testWidgets('restore all calls the escape hatch', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.text('Restore all'));
      await tester.pumpAndSettle();

      expect(channel.unhideAllCalls, 1);
      expect(find.text('2 apps restored to the launcher.'), findsOneWidget);
    });

    testWidgets('the app-info button opens system settings', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byTooltip('App info').first);
      await tester.pumpAndSettle();

      expect(channel.openedSettings, ['com.example.photos']);
    });

    testWidgets('re-checking capabilities picks up new provisioning', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      expect(find.text('Device owner not set up'), findsOneWidget);

      // The user has now run the provisioning command.
      channel.capabilities = FakeAppLockChannel.capabilitiesFor(
        deviceOwnerActive: true,
        accessibilityEnabled: true,
      );
      await tester.tap(find.text('Re-check'));
      await tester.pumpAndSettle();

      expect(find.text('Launcher hiding active'), findsOneWidget);
    });
  });
}
