import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/icloud_kv_store.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';

/// [SwitchableCloudKVStore] routes to [IcloudKVStore] or
/// [LocalOnlyCloudKVStore] without ever changing identity (spec Phase 7:
/// "iOS: MethodChannel ... + SwitchableCloudKVStore forwarding to iCloud or
/// LocalOnly so turning sync on/off doesn't rebuild stores"). These tests
/// mock the underlying `qima/cloud_kv` channels the same way
/// `icloud_kv_store_test.dart` does, standing in for `CloudKVPlugin.swift`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('qima/cloud_kv');
  const eventChannel = EventChannel('qima/cloud_kv/changes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Shared in-memory "cloud" the mocked method channel reads/writes, so
  // reads reflect prior writes exactly like the real NSUbiquitousKeyValueStore
  // would.
  late Map<String, String> cloudValues;

  setUp(() {
    cloudValues = {};
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'getString':
          final key = (call.arguments as Map)['key'] as String;
          return cloudValues[key];
        case 'setString':
          final args = call.arguments as Map;
          cloudValues[args['key'] as String] = args['value'] as String;
          return null;
        case 'synchronize':
          return true;
        case 'accountStatus':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test('starts disabled: reads/writes never touch the platform channel', () async {
    final store = SwitchableCloudKVStore();
    expect(store.enabled, isFalse);

    await store.setString('k', 'v');
    expect(cloudValues, isEmpty); // Went to LocalOnlyCloudKVStore, not the channel.
    expect(await store.getString('k'), isNull);

    await store.dispose();
  });

  test('enabling routes reads/writes to the real iCloud channel', () async {
    final store = SwitchableCloudKVStore();
    store.setEnabled(true);
    expect(store.enabled, isTrue);

    await store.setString('watchcards.records', '[]');
    expect(cloudValues['watchcards.records'], '[]');
    expect(await store.getString('watchcards.records'), '[]');

    await store.dispose();
  });

  test('disabling after enabling leaves previously-written cloud data untouched', () async {
    final store = SwitchableCloudKVStore();
    store.setEnabled(true);
    await store.setString('watchcards.records', '["a"]');
    store.setEnabled(false);

    // Reading now goes to LocalOnlyCloudKVStore (always null), but the
    // cloud's own copy is untouched — nothing was deleted by disabling.
    expect(await store.getString('watchcards.records'), isNull);
    expect(cloudValues['watchcards.records'], '["a"]');

    await store.dispose();
  });

  test('external-change events only forward while enabled', () async {
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events.success({
            'keys': ['watchcards.records'],
            'reason': 'serverChange',
          });
        },
      ),
    );

    final store = SwitchableCloudKVStore();
    final received = <CloudKVChangeEvent>[];
    final subscription = store.didChangeExternally.listen(received.add);

    store.setEnabled(true);
    await pumpEventQueue();
    expect(received, hasLength(1));
    expect(received.single.keys, ['watchcards.records']);

    await subscription.cancel();
    await store.dispose();
  });

  test('accountStatus reflects the real iCloud account regardless of enabled', () async {
    final store = SwitchableCloudKVStore();
    // accountStatus is used to decide WHETHER to enable, so it must answer
    // even while still disabled.
    expect(await store.accountStatus(), isTrue);
    await store.dispose();
  });

  group('size guard', () {
    // A value of about [bytes] bytes; the key adds its own bytes on top.
    String ascii(int bytes) => 'x' * ((bytes ~/ 2) - 1);

    test('tracks totals across writes, overwrites and external removal', () async {
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);
      expect(store.trackedBytes, 0);

      expect(await store.trySetString('a', 'xxxx'), isTrue); // (1 + 4) * 2
      expect(store.trackedBytes, 10);
      await store.setString('b', 'xx');
      expect(store.trackedBytes, 16);
      await store.setString('a', 'x'); // shrink
      expect(store.trackedBytes, 10);
      await store.setString('a', 'xxxxxx'); // grow
      expect(store.trackedBytes, 20);

      cloudValues.remove('b');
      expect(await store.getString('b'), isNull);
      expect(store.trackedBytes, 14);

      cloudValues['c'] = 'xxx';
      expect(await store.getString('c'), 'xxx');
      expect(store.trackedBytes, 14 + 8);

      await store.dispose();
    });

    test('counts the larger of UTF-8 and UTF-16', () async {
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);
      await store.setString('k', '\u4e2d'); // UTF-8: 3, UTF-16: 2 -> 3; key 2
      expect(store.trackedBytes, 5);
      await store.dispose();
    });

    test('skips a write past the limit, keeps the stored value, fires once per skip', () async {
      final store = SwitchableCloudKVStore();
      final events = <CloudKVChangeEvent>[];
      final sub = store.didChangeExternally.listen(events.add);
      store.setEnabled(true);

      await store.setString('big', ascii(800000));
      expect(await store.trySetString('big2', ascii(100000)), isFalse);
      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.single.reason, CloudKVChangeReason.quotaViolationChange);
      expect(events.single.keys, ['big2']);
      expect(cloudValues.containsKey('big2'), isFalse);
      expect(store.trackedBytes, 800004); // 'big' (6) + 399999 chars (UTF-16)

      // Growing an existing key past the limit is skipped and keeps the old value.
      final before = cloudValues['big'];
      expect(await store.trySetString('big', ascii(950000)), isFalse);
      await pumpEventQueue();
      expect(events, hasLength(2));
      expect(cloudValues['big'], before);

      // setString skips too, without throwing.
      await store.setString('big2', ascii(100000));
      await pumpEventQueue();
      expect(events, hasLength(3));

      await sub.cancel();
      await store.dispose();
    });

    test('a later write that fits succeeds and emits nothing', () async {
      final store = SwitchableCloudKVStore();
      final events = <CloudKVChangeEvent>[];
      final sub = store.didChangeExternally.listen(events.add);
      store.setEnabled(true);

      await store.setString('big', ascii(800000));
      expect(await store.trySetString('more', ascii(200000)), isFalse);
      await pumpEventQueue();
      expect(events, hasLength(1));

      expect(await store.trySetString('small', 'ok'), isTrue);
      expect(cloudValues['small'], 'ok');
      // Shrinking frees room for the write that was refused before.
      await store.setString('big', ascii(500000));
      expect(await store.trySetString('more', ascii(200000)), isTrue);
      expect(cloudValues.containsKey('more'), isTrue);
      await pumpEventQueue();
      expect(events, hasLength(1));

      await sub.cancel();
      await store.dispose();
    });

    test('a failed platform write leaves the tracked total unchanged', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method == 'setString') throw PlatformException(code: 'boom');
        return null;
      });
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);
      await expectLater(store.setString('a', 'xx'), throwsA(isA<PlatformException>()));
      expect(store.trackedBytes, 0);
      await store.dispose();
    });

    test('disabled store neither tracks nor emits, and never skips', () async {
      final store = SwitchableCloudKVStore();
      final events = <CloudKVChangeEvent>[];
      final sub = store.didChangeExternally.listen(events.add);

      expect(await store.trySetString('big', ascii(990000)), isTrue);
      await store.setString('big2', ascii(990000));
      await pumpEventQueue();
      expect(store.trackedBytes, 0);
      expect(events, isEmpty);
      expect(cloudValues, isEmpty);

      await sub.cancel();
      await store.dispose();
    });

    test('tracking resets when disabled and re-enabled, so an emptied cloud is not still counted', () async {
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);
      await store.setString('big', ascii(899000));
      expect(store.trackedBytes, greaterThan(898000));

      // The cloud is emptied underneath (account switch) while sync is off.
      store.setEnabled(false);
      expect(store.trackedBytes, 0);
      cloudValues.clear();
      store.setEnabled(true);
      expect(store.trackedBytes, 0);
      expect(await store.trySetString('new', ascii(100)), isTrue);
      expect(cloudValues.containsKey('new'), isTrue);

      await store.dispose();
    });

    test('an accountChange event resets tracking and skipped keys before it is forwarded', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (arguments, events) => sink = events),
      );
      final store = SwitchableCloudKVStore();
      final totals = <int>[];
      final sub = store.didChangeExternally.listen((e) => totals.add(store.trackedBytes));
      store.setEnabled(true);
      await store.setString('big', ascii(899000));
      await store.trySetString('more', ascii(10000)); // skipped
      expect(store.overLimit, isTrue);

      cloudValues.clear();
      sink.success({'keys': <String>[], 'reason': 'accountChange'});
      await pumpEventQueue();
      expect(totals.last, 0);
      expect(store.trackedBytes, 0);
      expect(store.overLimit, isFalse);

      await sub.cancel();
      await store.dispose();
    });

    test('a failed write rolls back only itself when another write to the key landed', () async {
      final gates = <Completer<void>>[];
      final fail = <bool>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        if (call.method != 'setString') return null;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        if (fail[gates.indexOf(gate)]) throw PlatformException(code: 'boom');
        final args = call.arguments as Map;
        cloudValues[args['key'] as String] = args['value'] as String;
        return null;
      });
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);

      fail.addAll([true, false]);
      final first = store.trySetString('k', ascii(10000));
      final second = store.trySetString('k', ascii(20000));
      await pumpEventQueue();
      expect(gates, hasLength(2));
      gates[1].complete(); // second lands first
      await second;
      final landedSize = store.trackedBytes;
      gates[0].complete(); // first fails afterwards
      await expectLater(first, throwsA(isA<PlatformException>()));
      expect(store.trackedBytes, landedSize);
      expect(cloudValues['k']!.length, 9999);
      expect(store.trackedBytes, 20000);

      await store.dispose();
    });

    test('a skipped key is reported through overLimit until a write of it lands', () async {
      final store = SwitchableCloudKVStore();
      store.setEnabled(true);
      expect(store.overLimit, isFalse);

      await store.setString('big', ascii(899000));
      expect(await store.trySetString('big', ascii(899990 + 5000)), isFalse);
      expect(store.overLimit, isTrue);
      expect(store.skippedKeys, {'big'});
      // Other keys landing does not clear it.
      expect(await store.trySetString('tiny', 'x'), isTrue);
      expect(store.overLimit, isTrue);
      // A write of the same key that fits lands and clears it.
      expect(await store.trySetString('big', ascii(500000)), isTrue);
      expect(store.overLimit, isFalse);
      expect(store.skippedKeys, isEmpty);

      await store.dispose();
    });
  });
}
