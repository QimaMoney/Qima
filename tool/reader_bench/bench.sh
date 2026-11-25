#!/usr/bin/env bash
# Scores how well the app reads a folder of bank files.
#
#   tool/reader_bench/bench.sh --files <folder> [--propose] [--compare] [--threshold <points>]
#                              [--detail <file under the folder>] [--lang <en|ar|fr|es>]
#
# The folder's top-level folders are the banks. PDFs and pictures are read
# from recordings made by tool/reader_bench/stage.sh; CSV, Excel and text
# messages are read directly. Every file is read twice: by the rules alone,
# and by the rules with the on-device model's recorded answers.
#
#   --propose   write <folder>/.bench/expected/<file>.json for every file
#               that has none, from the rules' reading, with "verified":
#               false. Correct the rows, set "verified": true, and the file
#               counts toward accuracy. Existing files are never touched.
#   --compare   show what moved since the run before and exit 1 when a
#               total got worse by more than the threshold (default 1
#               percentage point).
#   --detail    write a row by row diff of one file to <folder>/.bench/detail/
#               and print only where it is.
#
# Prints counts and percentages only. Everything derived from the files
# (recordings, expected rows, report.json, history.jsonl, details) stays
# under <folder>/.bench/, outside the repository.
set -euo pipefail

files="" propose="" compare="" detail="" threshold="" lang=""
while [ $# -gt 0 ]; do
  case "$1" in
    --files) files="${2:?--files needs a folder}"; shift 2 ;;
    --propose) propose=1; shift ;;
    --compare) compare=1; shift ;;
    --detail) detail="${2:?--detail needs a file}"; shift 2 ;;
    --threshold) threshold="${2:?--threshold needs a number}"; shift 2 ;;
    --lang) lang="${2:?--lang needs a language}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done
[ -n "$files" ] || { echo "Usage: tool/reader_bench/bench.sh --files <folder> [--propose] [--compare] [--detail <file>]" >&2; exit 64; }
[ -d "$files" ] || { echo "No such folder: $files" >&2; exit 64; }
files="$(cd "$files" && pwd)"
# A path given with the folder in front means the same file.
detail="${detail#"$files/"}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$files/.bench"
mkdir -p "$out"
rm -f "$out/.exit"

cd "$root"
QIMA_BENCH_FILES="$files" QIMA_BENCH_PROPOSE="$propose" QIMA_BENCH_COMPARE="$compare" QIMA_BENCH_DETAIL="$detail" \
  QIMA_BENCH_THRESHOLD="$threshold" QIMA_BENCH_LANG="${lang:-en}" \
  flutter test tool/reader_bench/bench.dart >"$out/run.log" 2>&1 || true

if [ ! -f "$out/.exit" ]; then
  # The log may quote a document, so it is pointed at, not printed.
  echo "The bench did not finish; see $out/run.log" >&2
  exit 2
fi
cat "$out/summary.txt"
code="$(cat "$out/.exit")"
rm -f "$out/.exit"
exit "$code"
