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
	"$ROOT_DIR/bin/overwatch-audio-maintenance"
	"$ROOT_DIR/bin/overwatch-audio-effects-config"
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

for unit in "$ROOT_DIR"/systemd/*.service "$ROOT_DIR"/systemd/*.timer; do
	sed \
		-e 's|/usr/bin/easyeffects|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-session|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-observe|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-maintenance|/bin/true|g' \
		-e 's|%h/.local/bin/overwatch-audio-effects-config|/bin/true|g' \
		"$unit" > "$temporary_units/${unit##*/}"
done

printf '[Unit]\nDescription=Test PipeWire service\n[Service]\nExecStart=/bin/true\n' > "$temporary_units/pipewire.service"
printf '[Unit]\nDescription=Test PipeWire Pulse service\n[Service]\nExecStart=/bin/true\n' > "$temporary_units/pipewire-pulse.service"

SYSTEMD_UNIT_PATH="$temporary_units:/usr/lib/systemd/user:/lib/systemd/user" \
	systemd-analyze --user verify \
	"$temporary_units/easyeffects.service" \
	"$temporary_units/overwatch-audio-session.service" \
	"$temporary_units/overwatch-audio-maintenance.service" \
	"$temporary_units/overwatch-audio-maintenance.timer"

grep -Fq 'Environment=DISABLE_RTKIT=1' "$ROOT_DIR/systemd/easyeffects.service"
grep -Fq 'StartLimitIntervalSec=5min' "$ROOT_DIR/systemd/easyeffects.service"
grep -Fq 'StartLimitBurst=5' "$ROOT_DIR/systemd/easyeffects.service"
grep -Fq 'Restart=on-failure' "$ROOT_DIR/systemd/easyeffects.service"
grep -Fq 'DISABLE_RTKIT=1 easyeffects' "$ROOT_DIR/bin/overwatch-audio-session"
grep -Fq $'\t\trtkit' "$ROOT_DIR/install.sh"
grep -Fq 'audio_in_use && exit 0' "$ROOT_DIR/bin/overwatch-audio-maintenance"
grep -Fq 'game_stopped || exit 0' "$ROOT_DIR/bin/overwatch-audio-maintenance"
grep -Fq 'ExecStartPre=%h/.local/bin/overwatch-audio-effects-config' "$ROOT_DIR/systemd/easyeffects.service"
grep -Fq 'processAllOutputs' "$ROOT_DIR/bin/overwatch-audio-effects-config"
grep -Fq 'processAllInputs' "$ROOT_DIR/bin/overwatch-audio-effects-config"
grep -Fq 'effects_output_linked' "$ROOT_DIR/bin/overwatch-audio-session"
grep -Fq 'unpin_effects_sink_targets' "$ROOT_DIR/install.sh"
grep -Fq "playerctl --all-players status" "$ROOT_DIR/bin/overwatch-audio-maintenance"
grep -Fq $'\t\tplayerctl' "$ROOT_DIR/install.sh"
grep -Fq 'AUDIO_GRAPH_MAX_AGE_SECONDS="86400"' "$ROOT_DIR/config/session.conf"
grep -Fq 'OnUnitActiveSec=1h' "$ROOT_DIR/systemd/overwatch-audio-maintenance.timer"
grep -Fq 'overwatch-audio-maintenance.timer overwatch-audio-session.service easyeffects.service' \
	"$ROOT_DIR/bin/overwatch-audio-session"
grep -Fq 'systemctl --user stop overwatch-audio-maintenance.service' "$ROOT_DIR/uninstall.sh"

grep -Fq 'https://github.com/basecamp/omarchy' "$ROOT_DIR/README.md"
grep -Fq 'MIT License' "$ROOT_DIR/LICENSE"
if grep -R --line-number --fixed-strings '/home/bear' \
	"$ROOT_DIR/bin" "$ROOT_DIR/config" "$ROOT_DIR/systemd" "$ROOT_DIR/install.sh" "$ROOT_DIR/uninstall.sh"; then
	printf 'A user-specific path is present.\n' >&2
	exit 1
fi

printf 'All checks passed.\n'
