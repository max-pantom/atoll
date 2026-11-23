# Focus, meetings and dev mode

## Do Not Disturb during focus sessions

Atoll turns Do Not Disturb on and off by running two Shortcuts with `shortcuts run`. Create them in the Shortcuts app:

1. New shortcut named exactly `Atoll Focus On`: add the action "Set Focus", choose Do Not Disturb, turn On.
2. New shortcut named exactly `Atoll Focus Off`: the same action with Off.

If either shortcut is missing Atoll skips this step silently; Settings > Focus shows a hint.

## Meeting bar

The orange dot (microphone) and green dot (camera) come from CoreAudio and CoreMediaIO "running somewhere" flags. No permission is needed. Meeting title, time left and the 2-minute heads-up use Calendar and only work if you already granted Atoll calendar access (the Calendar activity asks for it).

## Terminal pings

```sh
atoll notify "Build done" "42 tests passed" ok     # status is ok, fail, or omitted
```

The `atoll` script is in `Atoll.app/Contents/Resources/`. Link it onto your PATH:

```sh
ln -s /Applications/Atoll.app/Contents/Resources/atoll /usr/local/bin/atoll
```

It opens `atoll://notify?title=...&body=...&status=ok|fail`.

To ping automatically when a command runs longer than 10 seconds, add this to `~/.zshrc` (change `ATOLL_PING_MIN` to set the threshold):

```sh
source /path/to/atoll/docs/atoll-ping.zsh
```

## GitHub Actions and Vercel

Add tokens and repos in Settings > Developer. Tokens are stored in the Keychain only. GitHub needs a token that can read Actions on the repos; Vercel is optional.
