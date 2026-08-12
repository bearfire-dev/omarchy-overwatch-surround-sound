#!/bin/bash

set -euo pipefail

readonly STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/overwatch-audio"
readonly BACKUP_PARENT="$STATE_ROOT/install-backups"
readonly ORIGINAL_BACKUP_FILE="$BACKUP_PARENT/original"
REMOVAL_ROOT="$STATE_ROOT/uninstall-backups/$(date +%Y%m%dT%H%M%S)-$$"
readonly REMOVAL_ROOT

managed_paths=(
	"$HOME/.local/bin/overwatch-audio-session"
	"$HOME/.local/bin/overwatch-audio-observe"
	"$HOME/.config/systemd/user/easyeffects.service"
	"$HOME/.config/systemd/user/overwatch-audio-session.service"
	"$HOME/.local/share/easyeffects/output/PRO X Overwatch Conservative.json"
	"$HOME/.local/share/easyeffects/output/PRO X Neutral Reference.json"
)

systemctl --user stop overwatch-audio-apply-update.service 2>/dev/null || true
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

printf 'Disabled the automatic audio services.\n'
printf 'Kept the configuration and logs.\n'
printf 'Removed files are recoverable from: %s\n' "$REMOVAL_ROOT"
if [[ -n "$original_backup" ]]; then
	printf 'Restored replaced files from: %s\n' "$original_backup"
fi
