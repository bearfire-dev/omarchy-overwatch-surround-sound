#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly REQUIRE_SHELLCHECK="${REQUIRE_SHELLCHECK:-0}"

scripts=(
	"$ROOT_DIR/install.sh"
	"$ROOT_DIR/uninstall.sh"
	"$ROOT_DIR/bin/overwatch-audio-session"
	"$ROOT_DIR/bin/overwatch-audio-observe"
	"$ROOT_DIR/tests/check.sh"
)

for script in "${scripts[@]}"; do
	bash -n "$script"
done

if command -v shellcheck >/dev/null; then
	shellcheck --external-sources "${scripts[@]}"
elif [[ "$REQUIRE_SHELLCHECK" == "1" ]]; then
	printf 'shellcheck is required.\n' >&2
	exit 1
else
	printf 'shellcheck is not installed. The CI workflow will run it.\n'
fi

for preset in "$ROOT_DIR"/presets/*.json; do
	jq -e '
		.output["equalizer#0"] as $equalizer
		| .output.plugins_order == ["equalizer#0"]
		and ($equalizer["num-bands"] > 0)
		and (($equalizer.left | length) == $equalizer["num-bands"])
		and (($equalizer.right | length) == $equalizer["num-bands"])
	' "$preset" >/dev/null
done

temporary_units="$(mktemp -d)"
trap 'rm -rf -- "$temporary_units"' EXIT

for unit in "$ROOT_DIR"/systemd/*.service; do
	sed \
		-e 's|/usr/bin/easyeffects|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-session|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-observe|/bin/true|g' \
		"$unit" > "$temporary_units/${unit##*/}"
done

printf '[Unit]\nDescription=Test PipeWire service\n[Service]\nExecStart=/bin/true\n' > "$temporary_units/pipewire.service"
printf '[Unit]\nDescription=Test PipeWire Pulse service\n[Service]\nExecStart=/bin/true\n' > "$temporary_units/pipewire-pulse.service"

SYSTEMD_UNIT_PATH="$temporary_units:/usr/lib/systemd/user:/lib/systemd/user" \
	systemd-analyze --user verify \
	"$temporary_units/easyeffects.service" \
	"$temporary_units/overwatch-audio-session.service"

grep -Fq 'https://github.com/basecamp/omarchy' "$ROOT_DIR/README.md"
grep -Fq 'MIT License' "$ROOT_DIR/LICENSE"
if grep -R --line-number --fixed-strings '/home/bear' \
	"$ROOT_DIR/bin" "$ROOT_DIR/config" "$ROOT_DIR/systemd" "$ROOT_DIR/install.sh" "$ROOT_DIR/uninstall.sh"; then
	printf 'A user-specific path is present.\n' >&2
	exit 1
fi

printf 'All checks passed.\n'
