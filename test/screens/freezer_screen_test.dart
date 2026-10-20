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
      : capabilities = capabilities ?? _softOnly;

  /// The capabilities map the fake device reports.
  Map<String, Object?> capabilities;

  static const Map<String, Object?> _softOnly = {
    'deviceAdminActive': false,
    'accessibilityEnabled': true,
    'canHideApps': true,
    'sdkInt': 34,
  };

  /// The apps the fake device reports.
  List<Map<String, Object?>> apps = const [
    {
      'packageName': 'com.example.photos',
      'label': 'Photos',
      'isSystem': false,
      'frozen': false,
    },
    {
      'packageName': 'com.example.chat',
      'label': 'Chat',
      'isSystem': false,
      'frozen': true,
    },
    {
      'packageName': 'android.system.settings',
      'label': 'Settings',
      'isSystem': true,
      'frozen': false,
    },
  ];

  /// Package names that were frozen or unfrozen, in call order.
  final List<String> freezeCalls = [];
  final List<String> unfreezeCalls = [];
  final List<String> openedSettings = [];
  final List<bool> secureFlags = [];

  /// How many times the native side was asked for capabilities.
  int capabilityCalls = 0;

  /// How many times the device-admin dialog was requested.
  int adminRequests = 0;

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
          final pkg = (call.arguments as Map)['packageName'] as String;
          freezeCalls.add(pkg);
          return {'applied': true, 'method': 'device_admin'};
        case 'unfreeze':
          final pkg = (call.arguments as Map)['packageName'] as String;
          unfreezeCalls.add(pkg);
          return {'applied': true, 'method': 'device_admin'};
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
    bool deviceAdminActive = false,
    bool accessibilityEnabled = true,
  }) =>
      {
        'deviceAdminActive': deviceAdminActive,
        'accessibilityEnabled': accessibilityEnabled,
        'canHideApps': true,
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
    testWidgets('states that soft freeze is the weaker tier', (tester) async {
      await pumpFreezer(tester, channel: FakeAppLockChannel());

      expect(find.text('Soft freeze only'), findsOneWidget);
      expect(find.textContaining('only send you home'), findsOneWidget);
      expect(find.text('Grant device admin'), findsOneWidget);
      expect(find.text('Enable app guard'), findsNothing);
    });

    testWidgets('reports hard freeze once device admin is granted', (tester) async {
      await pumpFreezer(
        tester,
        channel: FakeAppLockChannel(
          capabilities: FakeAppLockChannel.capabilitiesFor(
            deviceAdminActive: true,
            accessibilityEnabled: false,
          ),
        ),
      );

      expect(find.text('Hard freeze active'), findsOneWidget);
      expect(find.text('Grant device admin'), findsNothing);
      expect(find.text('Enable app guard'), findsOneWidget);
      expect(find.textContaining('disabled by Android itself'), findsOneWidget);
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
    testWidgets('toggling an unfrozen app calls freeze', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceAdminActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      // Photos is the only unfrozen entry, so it owns the first switch.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(channel.freezeCalls, ['com.example.photos']);
      expect(find.textContaining('frozen and disabled'), findsOneWidget);
    });

    testWidgets('toggling a frozen app calls unfreeze', (tester) async {
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceAdminActive: true),
      );
      await pumpFreezer(tester, channel: channel);

      // Chat is the frozen entry, second in the list.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(channel.unfreezeCalls, ['com.example.chat']);
      expect(find.text('Chat released.'), findsOneWidget);
    });

    testWidgets('the app-info button opens system settings', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      await tester.tap(find.byTooltip('App info').first);
      await tester.pumpAndSettle();

      expect(channel.openedSettings, ['com.example.photos']);
    });

    testWidgets('granting device admin re-reads the capabilities', (tester) async {
      final channel = FakeAppLockChannel();
      await pumpFreezer(tester, channel: channel);

      expect(find.text('Soft freeze only'), findsOneWidget);

      // The native side reports admin as active from now on.
      channel.capabilities = FakeAppLockChannel.capabilitiesFor(
        deviceAdminActive: true,
        accessibilityEnabled: true,
      );
      await tester.tap(find.text('Grant device admin'));
      await tester.pumpAndSettle();

      expect(find.text('Hard freeze active'), findsOneWidget);
    });
  });
}
