# Omarchy Overwatch Surround Sound

Automatic EasyEffects tuning and audio routing for Overwatch on the [Omarchy Arch Linux distribution](https://github.com/basecamp/omarchy).

This setup supports Overwatch only. It has only been tested with the Logitech G PRO X Wireless headset. You can fork it and change `config/session.conf` and the presets for another headset, game, or more general setup.

## Install

```bash
git clone https://github.com/bearfire-dev/omarchy-overwatch-surround-sound.git
cd omarchy-overwatch-surround-sound
./install.sh
```

The installer verifies Omarchy and its audio prerequisites, validates the project, backs up replaced files, and enables the user services. If Overwatch is open, it defers the service restart until the game exits.

Run `./install.sh --update` to pull and install an update. Run `./uninstall.sh` to disable the services and restore the files that the first install replaced.

Crash and recovery events use about 50 MiB at most under `~/.local/state/overwatch-audio/logs`. The desktop shows a limited number of failure notifications.

MIT licensed.
