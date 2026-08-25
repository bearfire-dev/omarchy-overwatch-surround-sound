#!/bin/bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/overwatch-audio"
readonly BACKUP_PARENT="$STATE_ROOT/install-backups"
INSTALL_ID="$(date +%Y%m%dT%H%M%S)-$$"
readonly INSTALL_ID
readonly BACKUP_ROOT="$BACKUP_PARENT/$INSTALL_ID"
readonly LATEST_BACKUP_FILE="$BACKUP_PARENT/latest"
readonly ORIGINAL_BACKUP_FILE="$BACKUP_PARENT/original"
readonly ORIGINAL_STATE_FILE="$BACKUP_PARENT/original-state"
readonly MINIMUM_EASYEFFECTS_VERSION="8.1.3"

UPDATE=false
REPLACE_CONFIG=false
TRANSACTION_ACTIVE=false
declare -a CHANGED_TARGETS=()

usage() {
	printf 'Usage: %s [--update] [--replace-config]\n' "${0##*/}"
}

fail() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

for argument in "$@"; do
	case "$argument" in
		--update)
			UPDATE=true
			;;
		--replace-config)
			REPLACE_CONFIG=true
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			fail "Unknown option: $argument"
			;;
	esac
done

update_checkout() {
	local -a install_arguments=()

	command -v git >/dev/null || fail "Git is required for --update."
	[[ -d "$ROOT_DIR/.git" ]] || fail "--update requires a Git checkout."
	[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || fail "Commit or discard local changes before an update."
	git -C "$ROOT_DIR" pull --ff-only
	if [[ "$REPLACE_CONFIG" == true ]]; then
		install_arguments+=(--replace-config)
	fi
	exec "$ROOT_DIR/install.sh" "${install_arguments[@]}"
}

if [[ "$UPDATE" == true ]]; then
	update_checkout
fi

verify_platform() {
	command -v systemctl >/dev/null || fail "This installer requires systemd user services."
}

install_prerequisites() {
	local package
	local -a packages=(
		easyeffects
		lsp-plugins-lv2
		jq
		glib2
		pipewire
		pipewire-pulse
		playerctl
		libpulse
		procps-ng
		rtkit
		util-linux
		systemd
	)
	local -a missing=()

	if ! command -v pacman >/dev/null; then
		printf 'No supported package manager was found. Verify these packages yourself: %s\n' "${packages[*]}"
		return 0
	fi

	for package in "${packages[@]}"; do
		if ! pacman -Q "$package" >/dev/null 2>&1; then
			missing+=("$package")
		fi
	done

	if (( ${#missing[@]} > 0 )); then
		printf 'Installing missing packages: %s\n' "${missing[*]}"
		if command -v omarchy >/dev/null; then
			omarchy pkg add "${missing[@]}"
		else
			sudo pacman -S --needed "${missing[@]}"
		fi
	fi
}

verify_commands() {
	local command_name
	local -a commands=(easyeffects flock gdbus jq loginctl pactl pgrep playerctl pw-config pw-dump systemctl systemd-analyze)

	for command_name in "${commands[@]}"; do
		command -v "$command_name" >/dev/null || fail "A required command is missing: $command_name"
	done
}

# The health check reads the bypass state from the EasyEffects command line.
# EasyEffects restored that query in 8.1.3.
verify_easyeffects() {
	local version=""

	if ! command -v easyeffects >/dev/null; then
		if command -v flatpak >/dev/null && flatpak info com.github.wwmm.easyeffects >/dev/null 2>&1; then
			fail "Flatpak EasyEffects is not supported. Install the native easyeffects package."
		fi
		fail "A required command is missing: easyeffects"
	fi

	if command -v pacman >/dev/null && pacman -Q easyeffects >/dev/null 2>&1; then
		version="$(pacman -Q easyeffects | awk '{ print $2 }')"
		if (( $(vercmp "$version" "$MINIMUM_EASYEFFECTS_VERSION") < 0 )); then
			fail "EasyEffects $MINIMUM_EASYEFFECTS_VERSION or newer is required. The installed version is $version."
		fi
		return 0
	fi

	version="$(easyeffects --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
	if [[ -z "$version" ]]; then
		printf 'Warning: the EasyEffects version is unknown. Version %s or newer is required.\n' "$MINIMUM_EASYEFFECTS_VERSION" >&2
		return 0
	fi
	if ! printf '%s\n%s\n' "$MINIMUM_EASYEFFECTS_VERSION" "$version" | sort -C -V; then
		fail "EasyEffects $MINIMUM_EASYEFFECTS_VERSION or newer is required. The installed version is $version."
	fi
}

# The first install records the states that the installer changes, so the
# uninstall can restore them.
record_original_state() {
	local linger_state
	local easyeffects_enabled=no
	local easyeffects_active=no

	if [[ -e "$ORIGINAL_STATE_FILE" ]]; then
		return 0
	fi

	linger_state="$(loginctl show-user "$USER" -p Linger --value)"
	if systemctl --user is-enabled --quiet easyeffects.service 2>/dev/null; then
		easyeffects_enabled=yes
	fi
	if systemctl --user is-active --quiet easyeffects.service; then
		easyeffects_active=yes
	fi

	mkdir -p "$BACKUP_PARENT"
	printf 'linger=%s\neasyeffects_enabled=%s\neasyeffects_active=%s\n' \
		"$linger_state" "$easyeffects_enabled" "$easyeffects_active" > "$ORIGINAL_STATE_FILE"
}

backup_path() {
	local destination="$1"
	local backup="$BACKUP_ROOT/${destination#/}"

	mkdir -p "$(dirname -- "$backup")"
	cp --archive -- "$destination" "$backup"
}

install_target() {
	local source="$1"
	local destination="$2"
	local mode="$3"
	local current_mode=""

	if [[ -e "$destination" ]]; then
		current_mode="$(stat -c %a "$destination")"
	fi
	if [[ -e "$destination" ]] && cmp --silent -- "$source" "$destination" && [[ "0$current_mode" == "$mode" ]]; then
		return
	fi

	mkdir -p "$BACKUP_ROOT"
	if [[ -e "$destination" || -L "$destination" ]]; then
		backup_path "$destination"
	fi
	CHANGED_TARGETS+=("$destination")
	install -D -m "$mode" -- "$source" "$destination"
}

rollback_transaction() {
	local status=$?
	local destination
	local backup
	local index

	trap - ERR
	if [[ "$TRANSACTION_ACTIVE" == true ]]; then
		printf 'The install failed. Restoring the previous files.\n' >&2
		for ((index = ${#CHANGED_TARGETS[@]} - 1; index >= 0; index--)); do
			destination="${CHANGED_TARGETS[$index]}"
			backup="$BACKUP_ROOT/${destination#/}"
			if [[ -e "$backup" || -L "$backup" ]]; then
				mkdir -p "$(dirname -- "$destination")"
				cp --archive -- "$backup" "$destination"
			else
				rm -f -- "$destination"
			fi
		done
		systemctl --user daemon-reload 2>/dev/null || true
	fi
	exit "$status"
}

trap rollback_transaction ERR

verify_platform
install_prerequisites
verify_easyeffects
verify_commands
"$ROOT_DIR/tests/check.sh"
record_original_state

TRANSACTION_ACTIVE=true

install_target "$ROOT_DIR/bin/overwatch-audio-session" "$HOME/.local/bin/overwatch-audio-session" 0755
install_target "$ROOT_DIR/bin/overwatch-audio-observe" "$HOME/.local/bin/overwatch-audio-observe" 0755
install_target "$ROOT_DIR/bin/overwatch-audio-maintenance" "$HOME/.local/bin/overwatch-audio-maintenance" 0755
install_target "$ROOT_DIR/bin/overwatch-audio-effects-config" "$HOME/.local/bin/overwatch-audio-effects-config" 0755
install_target "$ROOT_DIR/config/pipewire/pipewire-pulse.conf.d/overwatch-audio-routing.conf" "$HOME/.config/pipewire/pipewire-pulse.conf.d/overwatch-audio-routing.conf" 0644
install_target "$ROOT_DIR/systemd/easyeffects.service" "$HOME/.config/systemd/user/easyeffects.service" 0644
install_target "$ROOT_DIR/systemd/overwatch-audio-session.service" "$HOME/.config/systemd/user/overwatch-audio-session.service" 0644
install_target "$ROOT_DIR/systemd/overwatch-audio-maintenance.service" "$HOME/.config/systemd/user/overwatch-audio-maintenance.service" 0644
install_target "$ROOT_DIR/systemd/overwatch-audio-maintenance.timer" "$HOME/.config/systemd/user/overwatch-audio-maintenance.timer" 0644
install_target "$ROOT_DIR/presets/PRO X Overwatch Conservative.json" "$HOME/.local/share/easyeffects/output/PRO X Overwatch Conservative.json" 0644
install_target "$ROOT_DIR/presets/PRO X Neutral Reference.json" "$HOME/.local/share/easyeffects/output/PRO X Neutral Reference.json" 0644

if [[ ! -e "$HOME/.config/overwatch-audio/session.conf" || "$REPLACE_CONFIG" == true ]]; then
	install_target "$ROOT_DIR/config/session.conf" "$HOME/.config/overwatch-audio/session.conf" 0644
else
	printf 'Keeping the existing configuration: %s\n' "$HOME/.config/overwatch-audio/session.conf"
fi

systemctl --user daemon-reload
systemctl --user enable easyeffects.service overwatch-audio-session.service overwatch-audio-maintenance.timer >/dev/null
systemctl --user start overwatch-audio-maintenance.timer

if [[ "$(loginctl show-user "$USER" -p Linger --value)" != "yes" ]]; then
	loginctl enable-linger "$USER"
fi

if (( ${#CHANGED_TARGETS[@]} == 0 )); then
	systemctl --user start easyeffects.service overwatch-audio-session.service
	printf 'The installed files are already current.\n'
elif "$HOME/.local/bin/overwatch-audio-session" status | grep '^Game: running$' >/dev/null; then
	if systemctl --user is-active --quiet easyeffects.service overwatch-audio-session.service; then
		if ! systemctl --user is-active --quiet overwatch-audio-apply-update.service; then
			systemd-run --user \
				--unit=overwatch-audio-apply-update \
				--collect \
				--property=Type=exec \
				"$HOME/.local/bin/overwatch-audio-session" apply-update-after-game >/dev/null
		fi
		printf 'Overwatch is open. The service restart is deferred until the game exits.\n'
	else
		systemctl --user start easyeffects.service overwatch-audio-session.service
	fi
else
	systemctl --user restart pipewire-pulse.service
	systemctl --user restart easyeffects.service
	systemctl --user restart overwatch-audio-session.service
fi

systemctl --user is-enabled --quiet easyeffects.service overwatch-audio-session.service overwatch-audio-maintenance.timer
systemctl --user is-active --quiet easyeffects.service overwatch-audio-session.service overwatch-audio-maintenance.timer

# EasyEffects captured every stream before version 0.2.4, and WirePlumber
# saved a permanent easyeffects_sink target for each captured stream. The
# saved targets must go so that normal audio follows the default output.
# This runs after the service restart, because an EasyEffects process with
# stream capture still enabled would create the targets again.
unpin_effects_sink_targets() {
	local game_status
	local state_file="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/stream-properties"

	[[ -f "$state_file" ]] || return 0
	grep -Fq '"target":"easyeffects_sink"' "$state_file" || return 0
	# The full capture avoids a broken pipe under pipefail, and an empty
	# result counts as a running game. A WirePlumber restart during play is
	# worse than a delayed cleanup.
	game_status="$("$HOME/.local/bin/overwatch-audio-session" status 2>/dev/null || true)"
	if [[ -z "$game_status" ]] || grep -Fxq 'Game: running' <<< "$game_status"; then
		printf 'Overwatch is open. Run the installer again later to clear the saved stream targets.\n'
		return 0
	fi
	systemctl --user stop wireplumber.service
	sed -i -E 's/"target":"easyeffects_sink",[[:space:]]*//g; s/,[[:space:]]*"target":"easyeffects_sink"//g' "$state_file"
	systemctl --user start wireplumber.service
	# The graph needs a moment to enumerate devices again.
	sleep 2
	printf 'Cleared the saved easyeffects_sink stream targets.\n'
}

unpin_effects_sink_targets

if (( ${#CHANGED_TARGETS[@]} > 0 )); then
	mkdir -p "$BACKUP_PARENT"
	printf '%s\n' "$BACKUP_ROOT" > "$LATEST_BACKUP_FILE"
	if [[ ! -e "$ORIGINAL_BACKUP_FILE" ]]; then
		printf '%s\n' "$BACKUP_ROOT" > "$ORIGINAL_BACKUP_FILE"
	fi
elif [[ ! -e "$ORIGINAL_BACKUP_FILE" && -r "$LATEST_BACKUP_FILE" ]]; then
	cp -- "$LATEST_BACKUP_FILE" "$ORIGINAL_BACKUP_FILE"
fi

TRANSACTION_ACTIVE=false
trap - ERR

printf 'Installed Omarchy Overwatch Surround Sound %s.\n' "$(<"$ROOT_DIR/VERSION")"
if [[ -d "$BACKUP_ROOT" ]]; then
	printf 'Backup: %s\n' "$BACKUP_ROOT"
fi
"$HOME/.local/bin/overwatch-audio-session" status
