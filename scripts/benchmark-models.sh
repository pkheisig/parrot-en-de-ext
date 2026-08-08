#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 AUDIO_FILE [AUDIO_FILE ...]" >&2
    exit 2
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${PARROT_BIN:-}" ]; then
    BINARY=$PARROT_BIN
else
    swift build -c release --package-path "$ROOT_DIR"
    BINARY=$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")/parrot
fi

BENCHMARK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/parrot-model-benchmark.XXXXXX")
cleanup() {
    rm -rf "$BENCHMARK_DIR"
}
trap cleanup EXIT INT TERM

models="
whisper-small|english
whisper-large-v3-turbo|english
whisper-large-v3-turbo-german-q5|german
"
status=0

echo "Parrot model benchmark"
echo "binary: $BINARY"
echo "audio:  $*"
echo

for entry in $models; do
    model=${entry%%|*}
    language=${entry#*|}
    output_file="$BENCHMARK_DIR/$model.out"
    error_file="$BENCHMARK_DIR/$model.err"
    echo "=== $model ==="
    if PARROT_PROFILE_MEMORY=1 "$BINARY" transcribe-file \
        --language "$language" \
        --model-id "$model" \
        --benchmark \
        "$@" >"$output_file" 2>"$error_file"; then
        cat "$error_file"
        cat "$output_file"
    else
        command_status=$?
        status=1
        cat "$error_file"
        echo "model failed with exit status $command_status" >&2
    fi
    echo
done

echo "Logs were temporary; model files were not removed."
exit "$status"
