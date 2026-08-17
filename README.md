# Omarchy Overwatch Surround Sound

Automatic EasyEffects tuning and audio routing for Overwatch on the [Omarchy Arch Linux distribution](https://github.com/basecamp/omarchy).

This setup targets Overwatch on the Logitech G PRO X Wireless headset out of the box. You can add other games as profiles and change `config/session.conf` for another headset.

The presets apply a stereo equalizer. They do not add spatial surround processing.

## Install

```bash
git clone https://github.com/bearfire-dev/omarchy-overwatch-surround-sound.git
cd omarchy-overwatch-surround-sound
./install.sh
```

The installer verifies the audio prerequisites, validates the project, backs up replaced files, and enables the user services. On Omarchy, it adds missing packages with `omarchy pkg add`. On other Arch systems, it uses `sudo pacman`. On other distributions, it prints the package list and verifies the required commands. It requires the native EasyEffects at version 8.1.3 or newer for the bypass-state query. Flatpak EasyEffects is not supported. If a configured game is open, the installer defers the service restart until the game exits.

The installer includes RTKit so PipeWire can use real-time scheduling. The EasyEffects service does not use RTKit. This separation prevents the kernel real-time CPU guard from terminating EasyEffects during preset processing. It does not change the preset, sample rate, or processing quality. The service permits five start attempts within five minutes. This limit prevents an unbounded crash loop.

Run `./install.sh --update` to pull and install an update. Run `./uninstall.sh` to disable the services and restore the files that the first install replaced. The uninstall also restores the linger setting and the previous EasyEffects service state.

## Profiles

The base configuration in `~/.config/overwatch-audio/session.conf` defines the default profile. Add more games as files in `~/.config/overwatch-audio/profiles/*.conf`. Each profile sets `PROCESS_PATTERN` and `PRESET_NAME`, and can set `STREAM_PATTERN`. Install the preset for a profile into `~/.local/share/easyeffects/output/`.

The watcher activates the first profile with a running process. The default profile has priority. A profile preset must contain an equalizer, because the health check verifies the equalizer node.

Crash and recovery events use about 50 MiB at most under `~/.local/state/overwatch-audio/logs`. The desktop shows a limited number of failure notifications.

MIT licensed.
