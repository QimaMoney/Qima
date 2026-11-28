@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/mcp/ai_inbox.dart';
import 'package:qima/mcp/mcp_server.dart';
import 'package:qima/mcp/qima_tools.dart';
import 'package:qima/mcp/snapshot_location.dart';
import 'package:qima/services/import/import_inbox_io.dart';

import 'qima_mcp_test.dart' show snapshot;

/// The Mac helper is a Swift program that runs Qima's server as JavaScript
/// (tool/qima_mcp/build_macos.sh). These tests build it and hold its answers
/// against the same server run here, so a difference in how JavaScript counts
/// or reads dates would show.
void main() {
  late Directory dir;
  late String helper;
  late String snapshotPath;
  late String inbox;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('qima_mac_helper');
    final bundle = '${dir.path}/QimaMCP.app';
    final built = Process.runSync('tool/qima_mcp/build_macos.sh', [bundle, '9.8.7+6']);
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    helper = '$bundle/Contents/MacOS/qima-mcp';
    snapshotPath = '${dir.path}/books/${SnapshotLocation.fileName}';
    inbox = AiInbox.folderFor(snapshotPath);
    Directory('${dir.path}/books').createSync();
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    File(snapshotPath).writeAsStringSync(jsonEncode(snapshot().toJson()));
    addTearDown(() {
      for (final e in Directory('${dir.path}/books').listSync()) {
        e.deleteSync(recursive: true);
      }
    });
  });

  String request(int id, String method, [Map<String, dynamic>? params]) =>
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});

  String call(int id, String tool, [Map<String, dynamic> arguments = const {}]) =>
      request(id, 'tools/call', {'name': tool, 'arguments': arguments});

  /// What the helper writes to stdout for [lines], one reply per line.
  Future<List<String>> ask(List<String> lines, {List<String>? arguments}) async {
    final process = await Process.start(helper, arguments ?? ['--snapshot', snapshotPath]);
    final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();
    final err = process.stderr.transform(utf8.decoder).join();
    for (final line in lines) {
      process.stdin.writeln(line);
    }
    await process.stdin.close();
    expect(await process.exitCode, 0, reason: await err);
    expect(await err, isEmpty);
    return out;
  }

  /// A reply with each tool result's text read as the JSON it is. JavaScript
  /// writes a whole amount as 2500 where Dart writes 2500.0; they are the
  /// same figure to whoever reads them.
  Object? figures(Object? reply) => switch (reply) {
        List() => [for (final r in reply) figures(r)],
        {'result': {'content': [{'text': final String text}], 'isError': false}} => {
            ...reply,
            'result': {...reply['result'] as Map<String, dynamic>, 'content': jsonDecode(text)},
          },
        _ => reply,
      };

  test('does not use the system function the Mac App Store turns away', () {
    final symbols = Process.runSync('nm', ['-u', helper]);
    expect(symbols.exitCode, 0, reason: '${symbols.stderr}');
    expect(symbols.stdout, isNot(contains('dyld_find_unwind_sections')));
  });

  test('answers every read as the server itself does', () async {
    final lines = [
      request(1, 'initialize', {'protocolVersion': '2025-03-26'}),
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      request(2, 'ping'),
      request(3, 'tools/list'),
      call(4, 'get_net_worth'),
      call(5, 'get_net_worth', {'as_of': '2026-10-31'}),
      call(6, 'list_accounts', {'include_categories': true, 'include_archived': true}),
      call(7, 'list_transactions', {'from': '2026-10-01', 'to': '2026-11-30', 'limit': 500}),
      call(8, 'list_transactions', {'account': 'rajhi', 'text': 'panda'}),
      call(9, 'list_transactions', {'from': 'yesterday'}),
      call(10, 'get_spending', {'month': '2026-11'}),
      call(11, 'get_spending', {'month': '2026-10'}),
      call(12, 'list_people'),
      call(13, 'list_holdings'),
      call(14, 'no_such_tool'),
      request(15, 'no/such/method'),
      'not json',
      jsonEncode([jsonDecode(request(16, 'ping')), jsonDecode(call(17, 'list_people'))]),
    ];
    final server = McpServer(loadSnapshot: () => SnapshotLocation.read(snapshotPath), version: '9.8.7+6');
    final expected = [for (final line in lines) ?server.handleLine(line)];

    final replies = await ask(lines);
    expect(replies.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      expect(figures(jsonDecode(replies[i])), figures(jsonDecode(expected[i])), reason: 'reply ${i + 1}');
    }
  });

  test('explains a missing copy and one that is not Qima\'s', () async {
    File(snapshotPath).deleteSync();
    var reply = jsonDecode((await ask([call(1, 'get_net_worth')])).single) as Map<String, dynamic>;
    expect(reply['result']['isError'], isTrue);
    expect(reply['result']['content'][0]['text'], SnapshotLocation.notShared.message);

    File(snapshotPath).writeAsStringSync('[]');
    reply = jsonDecode((await ask([call(1, 'get_net_worth')])).single) as Map<String, dynamic>;
    expect(reply['result']['isError'], isTrue);
    expect(reply['result']['content'][0]['text'], contains('could not be read'));
  });

  test('follows the copy while it runs', () async {
    final process = await Process.start(helper, ['--snapshot', snapshotPath]);
    final replies = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    Future<Map<String, dynamic>> netWorth() async {
      final reply = replies.first;
      process.stdin.writeln(call(1, 'get_net_worth'));
      return (jsonDecode(await reply) as Map<String, dynamic>)['result']['structuredContent'] as Map<String, dynamic>;
    }

    expect((await netWorth())['groups']['holdings'], 2500.0);
    File(snapshotPath).writeAsStringSync(jsonEncode(snapshot(holdingsValue: 4000).toJson()));
    expect((await netWorth())['groups']['holdings'], 4000.0);
    await process.stdin.close();
    expect(await process.exitCode, 0);
  });

  group('add_transactions', () {
    const arguments = {
      'title': 'Al Rajhi: November/2026',
      'currency': 'sar',
      'transactions': [
        {'date': '2026-11-03', 'amount': -45.5, 'description': 'Lemon Mart, "Olaya" branch'},
        {'date': '2026-11-05', 'amount': 3000, 'description': 'Salary\nNovember'},
        {'date': '2026-11-09', 'amount': -12.1, 'description': 'متجر الورق'},
        {'date': '2026-11-10', 'amount': 0.07, 'description': 'Interest'},
      ],
    };

    test('writes nothing until the person allows it in Qima', () async {
      final reply = jsonDecode((await ask([call(1, QimaTools.addTransactions, arguments)])).single) as Map<String, dynamic>;
      expect(reply['result']['isError'], isTrue);
      expect(reply['result']['content'][0]['text'], AiInbox.notAccepting.message);
      expect(Directory(inbox).existsSync(), isFalse);
    });

    test('leaves the same file the server itself would, where the import inbox reads it', () async {
      File('$inbox/${AiInbox.marker}').createSync(recursive: true);
      final before = DateTime.now();
      final reply = jsonDecode((await ask([call(1, QimaTools.addTransactions, arguments)])).single) as Map<String, dynamic>;
      expect(reply['result']['isError'], isFalse);
      expect(reply['result']['structuredContent']['handed_to_qima'], 4);

      final folders = FolderInbox(folders: [Directory(inbox)]);
      final file = (await folders.pending()).single;
      expect(file.message, isFalse);
      expect(file.receivedAt.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      final left = utf8.decode(await folders.bytes(file));

      String? name, contents;
      final server = McpServer(
        loadSnapshot: () => SnapshotLocation.read(snapshotPath),
        leaveFile: (n, c) => (name, contents) = (n, c),
        version: 'test',
        clock: () => before,
      );
      server.handleLine(call(1, QimaTools.addTransactions, arguments));
      expect(left, contents);
      expect(file.name, name);

      // Nothing half-written stays behind.
      expect(
        [for (final e in Directory(inbox).listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)],
        unorderedEquals([AiInbox.marker, file.id]),
      );
    });
  });

  test('says its version and refuses arguments it does not know', () async {
    expect(await ask(const [], arguments: ['--version']), ['qima-mcp 9.8.7+6']);
    final process = await Process.run(helper, ['--nope']);
    expect(process.exitCode, 64);
    expect(process.stderr, contains('unknown argument --nope'));
    expect(process.stdout, isEmpty);
  });
}
