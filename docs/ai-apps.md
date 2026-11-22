# AI apps (MCP)

Qima's desktop apps (macOS, Windows, Linux) can let AI apps that support the
Model Context Protocol read the person's books: Claude Desktop, Claude Code,
VS Code, Cursor, LM Studio and others. It is off by default and read-only.
A second switch lets them hand over transactions for the person to review;
they still never change the books.

## How it works

1. Settings › AI apps › **Let AI apps read Qima** (desktop only, never synced).
2. While it is on, Qima writes `qima-ai-snapshot.json`, a copy of the books
   (`AiSnapshot`, `lib/models/ai_snapshot.dart`), a couple of seconds after
   anything changes. Turning it off deletes the file.
3. The AI app starts the `qima-mcp` helper (shipped inside Qima) with
   `--snapshot <path>`. The helper speaks MCP over stdio
   (`lib/mcp/mcp_server.dart`) and reads only that file, again on every call.
4. Settings shows the exact `mcpServers` entry to paste, with both paths.

The helper never opens Qima's own files, so it does not depend on their
format, and the sandboxed Mac App Store build stays sandboxed.

## What is shared

Accounts, entries, planned payments, budgets, exchange rates and holdings
values. Left out at write time: account, card and IBAN digits
(`statementRefs`), account notes, raw bank-message merchant text, imported
file hashes, learned category rules and message senders.

Whatever an AI app reads goes to that app's model provider; the settings text
says so.

## Tools (`lib/mcp/qima_tools.dart`)

| Tool | Answers |
|---|---|
| `get_net_worth` | Net worth by group, optionally on an earlier day |
| `list_accounts` | Balances; categories and archived accounts on request |
| `list_transactions` | Filter by dates, account or category, text, kind; newest first |
| `get_spending` | One month by category, with budget and left to spend |
| `list_planned_payments` | Bills and income with the next due date |
| `list_people` | Who owes whom |
| `list_holdings` | Holdings value and cost at the last prices |

Every figure comes from the app's own models (`Book`, `NetWorthSummary`,
`MonthAnalysis`, `Person`), so answers match the screens. Each result
carries `saved_by_qima_at`, because the copy only updates while Qima is open.

## Adding transactions

Settings › AI apps › **Let AI apps add transactions** (shown once reading is
on, off by default, never synced) allows one more tool:

| Tool | Does |
|---|---|
| `add_transactions` | Hands up to 200 transactions of one account (date, signed amount, description, optional currency and title) to Qima |

The helper never writes to the books. It writes the list as a CSV into
`qima-ai-inbox`, the folder beside the snapshot (`AiInbox`,
`lib/mcp/ai_inbox.dart`), in the import inbox's own layout. Qima reads that
folder with its other inbox folders, so the list shows in the import review
like a shared statement: the person chooses the account, unticks what they
don't want and confirms. The same list sent twice is flagged as already
imported, as any file is.

- While the switch is on the app keeps a `.accepting` file in the folder;
  without it the helper refuses and tells the AI app which setting to turn
  on. Turning the switch (or reading) off removes it and keeps what already
  waits for review.
- The app watches the folder while the switch is on, so a list shows without
  waiting for Qima to come back to the front. If Qima is closed, the list
  waits until it opens.
- Amounts are written with the currency's own decimals; one with more is
  refused rather than rounded.

## Where things live

| | Snapshot | Helper |
|---|---|---|
| macOS (App Store) | App Group container `ZS3A435WC2.com.devlabtechnologies.qima` | `Qima.app/Contents/Helpers/QimaMCP.app/Contents/MacOS/qima-mcp`, sandboxed, same group |
| macOS (other builds) | Qima's Application Support folder | Same path, not sandboxed (macOS asks once to read another app's data) |
| Windows | `%APPDATA%\DevLab Technologies\Qima` | `qima-mcp.exe` beside `qima.exe` |
| Linux | `~/.local/share/com.devlabtechnologies.qima` | `qima-mcp` in the bundle |

## Building

The helper is its own small Dart package, `tool/qima_mcp`, which reaches the
app's pure-Dart models by path, so it needs neither Flutter nor the app's
plugins (`dart compile exe` refuses packages with build hooks, which the
app's plugins have).

- macOS: the Runner build phase "Embed qima-mcp" runs
  `tool/qima_mcp/embed_macos.sh`. It wraps the helper in a small bundle,
  because a sandboxed process needs a bundle id, and signs it with
  `allow-unsigned-executable-memory`, which Dart's AOT runtime needs under the
  hardened runtime.
- Windows and Linux: `tool/qima_mcp/qima_mcp.cmake`, included from each
  `CMakeLists.txt`, builds it and installs it beside the app, so the
  installer, zip and tarball carry it.

Keep `lib/models` and `lib/mcp` free of Flutter imports; the helper build
fails otherwise.

Run it by hand:

    cd tool/qima_mcp && dart run bin/qima_mcp.dart --snapshot <path>
