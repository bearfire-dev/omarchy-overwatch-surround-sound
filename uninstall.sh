#!/bin/bash

set -euo pipefail

readonly STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/overwatch-audio"
readonly BACKUP_PARENT="$STATE_ROOT/install-backups"
readonly ORIGINAL_BACKUP_FILE="$BACKUP_PARENT/original"
readonly ORIGINAL_STATE_FILE="$BACKUP_PARENT/original-state"
REMOVAL_ROOT="$STATE_ROOT/uninstall-backups/$(date +%Y%m%dT%H%M%S)-$$"
readonly REMOVAL_ROOT

managed_paths=(
	"$HOME/.local/bin/overwatch-audio-session"
	"$HOME/.local/bin/overwatch-audio-observe"
	"$HOME/.local/bin/overwatch-audio-maintenance"
	"$HOME/.local/bin/overwatch-audio-effects-config"
	"$HOME/.config/pipewire/pipewire-pulse.conf.d/overwatch-audio-routing.conf"
	"$HOME/.config/systemd/user/easyeffects.service"
	"$HOME/.config/systemd/user/overwatch-audio-session.service"
	"$HOME/.config/systemd/user/overwatch-audio-maintenance.service"
	"$HOME/.config/systemd/user/overwatch-audio-maintenance.timer"
	"$HOME/.local/share/easyeffects/output/PRO X Overwatch Conservative.json"
	"$HOME/.local/share/easyeffects/output/PRO X Neutral Reference.json"
)

if [[ -x "$HOME/.local/bin/overwatch-audio-session" ]] \
	&& "$HOME/.local/bin/overwatch-audio-session" status 2>/dev/null | grep -Fxq 'Game: running'; then
	printf 'Error: Close the configured game before uninstalling.\n' >&2
	exit 1
fi

systemctl --user stop overwatch-audio-apply-update.service 2>/dev/null || true
systemctl --user disable --now overwatch-audio-maintenance.timer 2>/dev/null || true
systemctl --user stop overwatch-audio-maintenance.service 2>/dev/null || true
if [[ -x "$HOME/.local/bin/overwatch-audio-session" ]]; then
	"$HOME/.local/bin/overwatch-audio-session" rollback || true
else
	systemctl --user disable --now overwatch-audio-session.service easyeffects.service 2>/dev/null || true
fi

original_backup=""
if [[ -r "$ORIGINAL_BACKUP_FILE" ]]; then
	read -r original_backup < "$ORIGINAL_BACKUP_FILE"
fi

for destination in "${managed_paths[@]}"; do
	backup="${original_backup:+$original_backup/${destination#/}}"
	if [[ -e "$destination" || -L "$destination" ]]; then
		removal="$REMOVAL_ROOT/${destination#/}"
		mkdir -p "$(dirname -- "$removal")"
		mv -- "$destination" "$removal"
	fi
	if [[ -n "$backup" && ( -e "$backup" || -L "$backup" ) ]]; then
		mkdir -p "$(dirname -- "$destination")"
		cp --archive -- "$backup" "$destination"
	fi
done

systemctl --user daemon-reload
systemctl --user restart pipewire-pulse.service

original_linger=""
original_easyeffects_enabled=""
original_easyeffects_active=""
if [[ -r "$ORIGINAL_STATE_FILE" ]]; then
	while IFS='=' read -r key value; do
		case "$key" in
			linger) original_linger="$value" ;;
			easyeffects_enabled) original_easyeffects_enabled="$value" ;;
			easyeffects_active) original_easyeffects_active="$value" ;;
		esac
	done < "$ORIGINAL_STATE_FILE"
fi

if [[ "$original_linger" == "no" ]]; then
	loginctl disable-linger "$USER" || true
	printf 'Restored the linger setting to off.\n'
fi

# The removal returns the EasyEffects stream capture keys to their upstream
# defaults. This runs while EasyEffects is stopped.
easyeffects_rc="${XDG_CONFIG_HOME:-$HOME/.config}/easyeffects/db/easyeffectsrc"
if [[ -f "$easyeffects_rc" ]]; then
	sed -i -E '/^processAllOutputs=false$/d; /^processAllInputs=false$/d' "$easyeffects_rc"
	printf 'Restored the EasyEffects stream capture defaults.\n'
fi

if [[ -e "$HOME/.config/systemd/user/easyeffects.service" ]]; then
	if [[ "$original_easyeffects_enabled" == "yes" ]]; then
		systemctl --user enable easyeffects.service 2>/dev/null || true
	fi
	if [[ "$original_easyeffects_active" == "yes" ]]; then
		systemctl --user start easyeffects.service 2>/dev/null || true
	fi
	if [[ "$original_easyeffects_enabled" == "yes" || "$original_easyeffects_active" == "yes" ]]; then
		printf 'Restored the previous EasyEffects service state.\n'
	fi
fi

printf 'Disabled the automatic audio services.\n'
printf 'Kept the configuration and logs.\n'
printf 'Removed files are recoverable from: %s\n' "$REMOVAL_ROOT"
if [[ -n "$original_backup" ]]; then
	printf 'Restored replaced files from: %s\n' "$original_backup"
fi
