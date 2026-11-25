#!/usr/bin/env bash
# Records a folder of bank files for the reader bench, on this Mac.
#
#   tool/reader_bench/stage.sh <folder> [--refresh] [--lang <en|ar|fr|es>]
#
# Text recognition and the on-device model only run inside the app, and the
# sandboxed app can only read inside its own container. So this copies the
# files into the container's temporary folder, runs
# integration_test/reader_bench_record_test.dart there (the debug app, with
# its usual bundle ID; the app's own data is not touched), copies the
# recordings back to <folder>/.bench/, and removes the copies.
#
# macOS guards another app's container: the first time, it asks whether the
# terminal may access data from other apps, and this script waits until
# that is answered. Run it from a terminal you can see.
#
# A file whose recording is newer than the file is skipped; --refresh
# records everything again. Nothing leaves this Mac, and nothing is written
# to the repository.
set -euo pipefail

files="${1:?folder of files}"
shift
refresh="" lang="en"
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) refresh=1; shift ;;
    --lang) lang="${2:?--lang needs a language}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done
[ -d "$files" ] || { echo "No such folder: $files" >&2; exit 64; }
files="$(cd "$files" && pwd)"

root="$(cd "$(dirname "$0")/../.." && pwd)"
bundle="$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER = //p' "$root/macos/Runner/Configs/AppInfo.xcconfig")"
container="$HOME/Library/Containers/$bundle/Data"
[ -d "$container" ] || { echo "Qima has no container yet ($container): run the macOS app once first." >&2; exit 1; }
stage="$container/tmp/qima-reader-bench"

rm -rf "$stage"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/.bench" "$files/.bench"
# Times are kept: a recording is skipped when it is newer than its file.
rsync -a --exclude '.*' "$files/" "$stage/"
for kind in pages model; do
  [ -d "$files/.bench/$kind" ] && rsync -a "$files/.bench/$kind" "$stage/.bench/"
done

cd "$root"
status=0
flutter test integration_test/reader_bench_record_test.dart -d macos \
  --dart-define=QIMA_BENCH_FILES="$stage" --dart-define=QIMA_BENCH_REFRESH="$refresh" --dart-define=QIMA_BENCH_LANG="$lang" || status=$?

# Whatever was recorded before a failure is still worth keeping.
for kind in pages model; do
  [ -d "$stage/.bench/$kind" ] && rsync -a "$stage/.bench/$kind" "$files/.bench/"
done
exit "$status"
