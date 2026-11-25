import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/legacy_absorber.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

/// Two devices of this build on the key-value path and one old key that a
/// device of an earlier build keeps writing, in a random interleaving: saves,
/// deletions, new orders and restores on either device, loads and absorbs in
/// between, clocks that are off either way, and old-key records that reuse a
/// stamp with other text.
///
/// Every change must be kept by the device that made it (a save shows what
/// was saved, a restore that replaces leaves exactly what it brought). When
/// both devices have loaded and absorbed, they hold the same records, the
/// cloud key is not written again, and every old-key record that is strictly
/// later than what is held has been taken.
///
/// `STORE_FUZZ_COUNT` is the number of seeds, `STORE_FUZZ_NOSKEW` keeps every
/// clock right, `STORE_FUZZ_NOLOAD` leaves out the loads before a change.
class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  int writes = 0;
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async {
    writes++;
    values[key] = value;
  }
  @override
  Future<void> synchronize() async {}
  @override
  Future<bool> accountStatus() async => true;
  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

BookAccount acct(String id, String name) => BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.cash, currency: 'USD');
String show(Iterable<Record> rs) {
  final s = rs.toList()..sort((a, b) => a.item.id.compareTo(b.item.id));
  return jsonEncode([for (final r in s) r.toJson()]);
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_store_fuzz');
  });
  tearDown(() async {
    await BookDatabase.closeAll();
    await dir.delete(recursive: true);
  });

  final ids = ['a', 'b', 'c', 'd'];
  final names = ['N1', 'N2', 'N3', 'N4', 'N5'];

  final environment = Platform.environment;
  String? setting(String name) => environment['STORE_FUZZ_$name'] ?? environment['REV_$name'];

  test('two devices and an old key, whatever the order of what happens, keep every change and end with one book', () async {
    final failures = <String>[];
    final count = int.parse(setting('COUNT') ?? '40');
    for (var seed = 0; seed < count; seed++) {
      final random = Random(seed);
      final cloud = _Cloud();
      final dirs = [Directory('${dir.path}/$seed-0')..createSync(), Directory('${dir.path}/$seed-1')..createSync()];
      final books = <BookStore>[];
      final absorbers = <LegacyAbsorber>[];
      for (final d in dirs) {
        LocalFileStore.overrideDirectoryForTesting(d);
        final b = BookStore(cloud: cloud);
        books.add(b);
        absorbers.add(LegacyAbsorber.forBook(b, cloud));
        await b.accounts.load();
      }
      // the old device's own state (plain list at the old key)
      final old = <String, Record<BookAccount>>{};
      final log = <String>[];
      void fail(String why) => failures.add('seed $seed: $why\n  ${log.join('\n  ')}');
      var bad = false;
      for (var step = 0; step < 40 && !bad; step++) {
        final who = random.nextInt(2);
        LocalFileStore.overrideDirectoryForTesting(dirs[who]);
        final store = books[who].accounts;
        final roll = random.nextInt(100);
        final id = ids[random.nextInt(ids.length)];
        final name = names[random.nextInt(names.length)];
        if (roll < 50 && setting('NOLOAD') == null) await store.load();
        if (roll < 25) {
          log.add('d$who upsert $id $name');
          await store.upsert(acct(id, name));
          final r = (await store.exportRecords()).where((r) => r.item.id == id).single;
          // The edit may only lose to a cloud record this device had not taken in.
          if (r.deleted || r.item.name != name) {
            fail('upsert not kept: ${jsonEncode(r.toJson())}');
            bad = true;
          }
        } else if (roll < 35) {
          log.add('d$who delete $id');
          final had = (await store.exportRecords()).any((r) => r.item.id == id);
          await store.delete(id);
          final r = (await store.exportRecords()).where((r) => r.item.id == id).firstOrNull;
          if (had && (r == null || !r.deleted)) {
            fail('delete not kept');
            bad = true;
          }
        } else if (roll < 42) {
          final order = [...ids]..shuffle(random);
          log.add('d$who setOrder $order');
          final live = await store.setOrder(order);
          final want = [for (final i in order) if (live.any((a) => a.id == i)) i];
          if (live.map((a) => a.id).join() != want.join()) {
            fail('order not kept: ${live.map((a) => a.id).join()} want ${want.join()}');
            bad = true;
          }
        } else if (roll < 50) {
          final replace = random.nextBool();
          final recs = [
            for (final i in ids)
              if (random.nextBool()) Record<BookAccount>(item: acct(i, 'R$name'), order: random.nextInt(3).toDouble(), updatedAt: DateTime.now().toUtc().add(Duration(minutes: setting('NOSKEW') != null ? -random.nextInt(60) - 1 : random.nextInt(120) - 60)), deleted: random.nextInt(5) == 0),
          ];
          log.add('d$who import replace=$replace ${show(recs)}');
          final live = await store.importRecords(recs, replace: replace);
          if (replace) {
            final want = {for (final r in recs) if (!r.deleted) r.item.id: r.item.name};
            final got = {for (final a in live) a.id: a.name};
            if (jsonEncode(want.keys.toList()..sort()) != jsonEncode(got.keys.toList()..sort()) || want.entries.any((e) => got[e.key] != e.value)) {
              fail('replace restore not kept: got $got want $want');
              bad = true;
            }
          }
        } else if (roll < 75) {
          // the old device saves, with a clock that may be off either way, or re-saves the same stamp with other text (tie)
          final skew = setting('NOSKEW') != null ? 0 : [0, 0, 60, -60, 600][random.nextInt(5)];
          final held = old[id];
          final tie = held != null && random.nextInt(4) == 0;
          final stamp = tie ? held.updatedAt : DateTime.now().toUtc().add(Duration(minutes: skew));
          old[id] = Record<BookAccount>(item: acct(id, 'O$name'), order: random.nextInt(3).toDouble(), updatedAt: stamp, deleted: random.nextInt(5) == 0);
          cloud.values[LedgerNames.legacyAccounts] = jsonEncode([for (final r in old.values) r.toJson()]);
          log.add('old save ${jsonEncode(old[id]!.toJson())}');
        } else if (roll < 90) {
          log.add('d$who absorb+load');
          await absorbers[who].absorb();
          await store.load();
        } else {
          log.add('d$who load');
          await store.load();
        }
      }
      if (bad) continue;
      // quiesce
      for (var round = 0; round < 4; round++) {
        for (var who = 0; who < 2; who++) {
          LocalFileStore.overrideDirectoryForTesting(dirs[who]);
          absorbers[who].reset();
          await absorbers[who].absorb();
          await books[who].accounts.load();
        }
      }
      final writes = cloud.writes;
      final states = <String>[];
      for (var round = 0; round < 3; round++) {
        for (var who = 0; who < 2; who++) {
          LocalFileStore.overrideDirectoryForTesting(dirs[who]);
          absorbers[who].reset();
          await absorbers[who].absorb();
          await books[who].accounts.load();
          if (round == 2) states.add(show(await books[who].accounts.exportRecords()));
        }
      }
      if (cloud.writes != writes) fail('cloud key still being rewritten: ${cloud.writes - writes} more writes');
      if (states[0] != states[1]) fail('devices differ\n${states[0]}\n${states[1]}');
      // an old-key record strictly later than what is held must have been taken
      LocalFileStore.overrideDirectoryForTesting(dirs[0]);
      final heldNow = {for (final r in await books[0].accounts.exportRecords()) r.item.id: r};
      for (final o in old.values) {
        final h = heldNow[o.item.id];
        if (h == null || o.updatedAt.isAfter(h.updatedAt)) fail('old key record not taken: ${jsonEncode(o.toJson())} held ${h == null ? null : jsonEncode(h.toJson())}');
      }
      await BookDatabase.closeAll();
    }
    expect(failures, isEmpty, reason: '${failures.length} of $count seeds failed:\n${failures.take(2).join('\n\n')}');
  });
}
