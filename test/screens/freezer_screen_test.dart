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
          // Mirrors the native rule: device owner hides, the app guard blocks,
          // and with neither the freeze is refused rather than recorded.
          if (capabilities['deviceOwnerActive'] as bool? ?? false) {
            return {'applied': true, 'method': 'device_owner'};
          }
          if (capabilities['accessibilityEnabled'] as bool? ?? false) {
            return {'applied': true, 'method': 'accessibility'};
          }
          return {'applied': false, 'method': 'none'};
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
    bool notificationAccessEnabled = false,
    int hiddenCount = 0,
  }) =>
      {
        'deviceOwnerActive': deviceOwnerActive,
        'profileOwnerActive': profileOwnerActive,
        'deviceAdminActive': deviceAdminActive,
        'accessibilityEnabled': accessibilityEnabled,
        'notificationAccessEnabled': notificationAccessEnabled,
        'hiddenCount': hiddenCount,
        'sdkInt': 34,
      };
}

/// Pumps the freezer on a tall viewport so the list is fully built.
///
/// Pass [controller] to drive the screen with a prepared (for example unlocked)
/// controller instead of a bare one.
Future<ChestController> pumpFreezer(
  WidgetTester tester, {
  required FakeAppLockChannel channel,
  ChestController? controller,
}) async {
  channel.install();
  addTearDown(channel.remove);

  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final active = controller ?? ChestController();
  if (controller == null) addTearDown(active.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<ChestController>.value(
      value: active,
      child: MaterialApp(theme: ChestTheme.dark(), home: const FreezerScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return active;
}

void main() {
  group('freezer enforcement panel', () {
    testWidgets('offers the on-device app guard when nothing is set up', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(accessibilityEnabled: false),
        ),
      );

      expect(find.text('App guard is off'), findsOneWidget);
      expect(find.text('Turn on app guard'), findsOneWidget);
      // The setup path is on the phone, spelled out as steps.
      expect(find.textContaining('Accessibility'), findsOneWidget);
      expect(find.textContaining('no computer needed'), findsOneWidget);
      // No shell command anywhere: this tier needs no computer.
      expect(find.textContaining('adb shell dpm'), findsNothing);
    });

    testWidgets('reports the app guard as active without device owner', (tester) async {
      // The phone-only tier. No provisioning of any kind has happened.
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('App guard active'), findsOneWidget);
      expect(find.textContaining('cannot be opened'), findsOneWidget);
      // Device owner is offered as an upgrade, never as a requirement.
      expect(find.textContaining('device owner'), findsOneWidget);
      expect(find.text('Turn on app guard'), findsNothing);
    });

    testWidgets('reports launcher hiding when device owner is granted', (tester) async {
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
      expect(find.textContaining('removed from your launcher'), findsOneWidget);
      // The guard is still offered even with device owner: it is the layer that
      // blocks the app on open and feeds the notification suppression.
      expect(find.text('Turn on app guard'), findsOneWidget);
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
            accessibilityEnabled: true,
          ),
        ),
      );

      expect(find.text('Launcher hiding active'), findsNothing);
      expect(find.text('App guard active'), findsOneWidget);
    });

    testWidgets('a profile owner does not claim launcher hiding', (tester) async {
      // Regression guard: a profile owner governs a work profile and cannot hide
      // the personal apps in the user's main launcher. Counting it as "can hide"
      // would promise a hide on exactly the apps it cannot perform it on.
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(
            profileOwnerActive: true,
            accessibilityEnabled: true,
          ),
        ),
      );

      expect(find.text('Launcher hiding active'), findsNothing);
      expect(find.textContaining('work profile'), findsOneWidget);
    });

    testWidgets('offers notification access once the guard is on', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('Hide notifications'), findsOneWidget);
    });

    testWidgets('hides the notification prompt once granted', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(
            notificationAccessEnabled: true,
          ),
        ),
      );

      expect(find.text('Hide notifications'), findsNothing);
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
      expect(find.textContaining('hidden from your launcher'), findsOneWidget);
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

    testWidgets('freezes via the app guard when not device owner', (tester) async {
      // The phone-only path: no provisioning, but the freeze is real because the
      // app guard blocks the app on open.
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(channel.freezeCalls, ['com.example.photos']);
      // The snack bar and the panel both describe the guard, so the phrase
      // legitimately appears twice.
      expect(find.textContaining('cannot be opened'), findsWidgets);
      // Photos was unfrozen, so the count goes from 1 to 2.
      expect(find.text('2 frozen'), findsOneWidget);
    });

    testWidgets('refuses to record a freeze with no enforcement at all',
        (tester) async {
      // With neither device owner nor the app guard, nothing can enforce a
      // freeze, so the switch must stay off rather than claiming one.
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(accessibilityEnabled: false),
      );
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be frozen'), findsOneWidget);
      expect(find.text('1 frozen'), findsOneWidget);
    });

    testWidgets('releasing a frozen app asks for confirmation first', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      // Chat is the frozen entry, second in the list.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      // The gate opens, and nothing has been released yet.
      expect(find.textContaining('Confirm to release Chat'), findsOneWidget);
      expect(channel.unfreezeCalls, isEmpty);
    });

    testWidgets('cancelling the gate releases nothing', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(channel.unfreezeCalls, isEmpty);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('1 frozen'), findsOneWidget);
    });

    testWidgets('a hidden app is badged and stays listed', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
        ),
      );

      // Chat is hidden, and must remain visible in the list so it can be
      // released — that is the whole reason labels are cached natively.
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('HIDDEN'), findsOneWidget);
    });

    testWidgets('release all is offered only when something is frozen',
        (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());
      expect(find.text('Release all'), findsOneWidget);

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
      expect(find.text('Release all'), findsNothing);
    });

    testWidgets('release all is gated too', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.text('Release all'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Confirm to release every app'), findsOneWidget);
      expect(channel.unhideAllCalls, 0);
    });

    testWidgets('the app-info button opens system settings', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byTooltip('App info').first);
      await tester.pumpAndSettle();

      expect(channel.openedSettings, ['com.example.photos']);
    });

    testWidgets('re-checking capabilities picks up new provisioning', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(accessibilityEnabled: false),
      );
      await pumpFreezer(tester, channel: channel);

      expect(find.text('App guard is off'), findsOneWidget);

      // The user has now turned on the app guard in Android Settings.
      channel.capabilities = FakeAppLockChannel.capabilitiesFor(
        accessibilityEnabled: true,
      );
      await tester.tap(find.text('Re-check'));
      await tester.pumpAndSettle();

      expect(find.text('App guard active'), findsOneWidget);
    });
  });
}
