# T3 Code on Android

Run the newest **nightly [T3 Code](https://github.com/pingdotgg/t3code)** on an Android tablet,
the same way the desktop app runs it on a PC. The agents (Claude Code, Codex, Grok, OpenCode,
Antigravity, Cursor, ...) run on the tablet itself, and everything keeps itself up to date.

T3 Code's Android app is only a remote control for a T3 Code *server*. This project gives the
tablet its own server: T3 Code's official `linux-arm64` nightly build, running in a Debian
container inside [Termux](https://github.com/termux/termux-app), with the agent CLIs
installed next to it.

| | |
|---|---|
| **Server** | Official T3 Code nightly, started by T3's own service launcher (as `t3 service install` does on Linux), so **Update server** in the apps works. Starts at boot. |
| **Updates** | Moves to the newest nightly every time it starts and daily at 04:00. A nightly that fails to start is rolled back automatically. |
| **App** | The official T3 Code Android app, as built for each nightly release. Obtainium keeps it current, and the app also updates itself over the air. Or use Chrome for the full desktop UI. |
| **Agents** | Claude Code, Codex, Grok Build and OpenCode are installed (Gemini CLI and Pi optional). Antigravity and Cursor install from T3's **Settings > Providers**. |

## Install

**New to this? Follow the [step-by-step guide](GUIDE.md).** It shows what you see at every step.

You need an arm64 Android device with Android 7 or newer and about 4 GB of free space.

1. **Install Obtainium.** On the tablet, download `app-arm64-v8a-release.apk` from
   [Obtainium's releases](https://github.com/ImranR98/Obtainium/releases/latest) and open it.
2. **Add the apps.** Tap each link on the tablet, choose Obtainium, then tap **Install**.
   - [T3 Code (nightly)][com.t3tools.t3code]: the newest app build from T3 Code's nightly releases
   - [Termux][com.termux]
   - [Termux:Boot][com.termux.boot]: starts T3 Code when the tablet boots
   - [Termux:API][com.termux.api]: clipboard and browser integration
   - [Termux:Widget][com.termux.widget] (optional): home-screen shortcuts

   If you already have Termux from F-Droid, keep it and install Termux:Boot and Termux:API
   from F-Droid instead. Termux and its add-ons must come from the same place.
3. **Open Termux:Boot once.** This lets it run at boot.
4. **Open Termux and paste:**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Quive87/t3code-android/main/install.sh | bash
   ```

   This takes 10–20 minutes the first time. When it finishes, T3 Code is running, and a link
   for the app has been copied to the clipboard.
5. **Connect the app.** Open the T3 Code app and tap **Add environment**. Under **Or enter it**,
   type the **Address** (`127.0.0.1:3773`) and the **Code** that Termux printed, then tap the
   checkmark. Codes work for 15 minutes; `t3code pair` prints a new one. To use Chrome instead,
   run `t3code open`.
6. **Sign in to your agents** in Termux:

   ```sh
   t3code login claude
   t3code login codex      # --device-auth to sign in with a code
   t3code login grok
   t3code login opencode
   t3code login github     # pull requests from T3 Code
   ```

   Antigravity and Cursor sign in from T3 Code: **Settings > Providers**, choose the tablet's
   environment, enable, **Install** / **Sign in**. Browser sign-ins open in the tablet's browser
   and come back to the agent by themselves.
7. **Stop Android from killing agents** (Android 12+). Run `t3code fix-android` once and
   follow it. It also tells you to set **Settings > Apps > Termux > Battery > Unrestricted**.

## Your PC's agents too

The app can be connected to several machines at once. Add your PC as a second environment and
everything set up there works from the tablet as well:

- **Same Wi-Fi:** in the desktop app open **Settings > Connections**, turn on **Network
  access**, and create a pairing link. Scan it in the tablet app under **Add environment**.
- **Anywhere:** turn on **T3 Connect** in the desktop app and sign in to the same account in
  the tablet app.

Each new thread lets you pick the machine it runs on. The reverse works too: `t3code pair --lan`
prints a link and QR code for adding the tablet to your PC's desktop app.

## Everyday use

| Command | |
|---|---|
| `t3code start` / `stop` / `restart` | Run the server in the background (it also starts at boot) |
| `t3code status` | Running? Which version? In-app updates available? |
| `t3code pair` | Link for the app on this tablet (`--lan`: for other devices) |
| `t3code open` | T3 Code in Chrome |
| `t3code update` | Newest nightly right now (`--all`: also agents, Debian and Termux) |
| `t3code providers` | Agent CLI versions (`install gemini,pi` to add more) |
| `t3code logs -f` | Follow the logs |
| `t3code shell` | Shell inside the Debian container, as the `t3` user |
| `t3code root apt install X` | Install system packages in the container |
| `t3code doctor` | Diagnostics |
| `t3code self-update` | Update this tool |

Projects live in the container under `/home/t3/projects` (fast). The tablet's shared storage is
at `/sdcard`, which is much slower for git.

Settings are in `~/.config/t3code-android/config`:

| Setting | Default | |
|---|---|---|
| `T3A_UPDATE_HOUR` | `4` | Daily update hour, or `off` |
| `T3A_AUTO_UPDATE` | `1` | Update every time the server starts |
| `T3A_PORT` | `3773` | Server port |
| `T3A_PROVIDERS` | `claude,codex,grok,opencode` | Agent CLIs that `update --all` refreshes |
| `T3A_WAKE_LOCK` | `1` | Keep the CPU awake while the server runs |

To give agents environment variables such as API keys, put `KEY=value` lines in
`/home/t3/.config/t3code-android/env` inside the container (`t3code shell`, then edit it).

## How updates work

- **Server:** T3 Code runs under its own service launcher. **Update server** in the desktop or
  mobile app, and the desktop app's *update everything* button, therefore work here the same
  way they do on a Linux server. In addition, every start moves to the newest nightly (from
  the `nightly` tag of the `t3` npm package, where T3 Code itself looks), and the server
  restarts into a new nightly once a day. Before switching versions, the database is copied.
  If the new version fails to start three times, it is put back along with the database, and
  that version is skipped from then on.
- **App:** Obtainium checks the nightly releases in the background. Between new builds, the
  app downloads JavaScript updates by itself.
- **Agents:** **Settings > Providers > Update** in T3 Code, or `t3code update --all`.

## Troubleshooting

- **Agents stop when the screen is off:** run `t3code fix-android`, and set Termux's battery
  usage to Unrestricted.
- **Nothing happens at boot:** open Termux:Boot once. Termux and Termux:Boot must come from the
  same source. Check `t3code autostart`.
- **The server doesn't come up:** run `t3code logs`. T3 Code's own logs are in
  `/home/t3/.t3/userdata/logs` inside the container.
- **16 KB memory pages** (some newer devices; `t3code doctor` shows the page size): T3 Code's
  binary is realigned automatically during install and on `t3code update`. In-app **Update
  server** may fail on these devices. Use `t3code update` there.
- **Obtainium shows 403 or "rate limited":** GitHub allows about 60 unauthenticated API calls per
  hour per connection. Wait up to an hour, or add a token under Obtainium **Settings >
  Source-specific > GitHub access token** (see the [guide](GUIDE.md#github-access-token-stops-obtainiums-403-errors)).
- **Starting over:** `t3code uninstall`, then run the install command again.

## Development

`install.sh` is self-contained. It writes the `t3code` command and the helpers inside the
container from the heredocs it contains. The test workflow lints all of them and runs the
whole installer inside the [termux-docker](https://github.com/termux/termux-docker) aarch64
image on GitHub's arm64 runners. It checks install, pairing, the agent CLIs, launcher-managed
updates, auto-update, rollback of a broken nightly and 16 KB realignment. The Obtainium links
come from `node tools/obtainium-links.mjs --markdown`.

<!-- Obtainium import links (generated by tools/obtainium-links.mjs --markdown) -->
[com.t3tools.t3code]: https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.t3tools.t3code%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fpingdotgg%2Ft3code%22%2C%22author%22%3A%22pingdotgg%22%2C%22name%22%3A%22T3%20Code%20(nightly)%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Atrue%2C%5C%22includeDrafts%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5ET3%20Code%20Nightly%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Afalse%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseNotesFilter%5C%22%3Afalse%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%5C%22%2C%5C%22versionDetection%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22%5Et3code-android-internal-.*%5C%5C%5C%5C.apk%24%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%2C%5C%22appName%5C%22%3A%5C%22T3%20Code%20(nightly)%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22pingdotgg%5C%22%2C%5C%22about%5C%22%3A%5C%22Nightly%20Android%20build%20of%20T3%20Code%20from%20github.com%2Fpingdotgg%2Ft3code%20releases.%5C%22%7D%22%7D
[com.termux]: https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.termux%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Ftermux%2Ftermux-app%22%2C%22author%22%3A%22termux%22%2C%22name%22%3A%22Termux%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22includeDrafts%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Afalse%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseNotesFilter%5C%22%3Afalse%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%5C%22%2C%5C%22versionDetection%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22_(arm64-v8a%7Cx86_64)%5C%5C%5C%5C.apk%24%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%2C%5C%22appName%5C%22%3A%5C%22Termux%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22termux%5C%22%7D%22%7D
[com.termux.boot]: https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.termux.boot%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Ftermux%2Ftermux-boot%22%2C%22author%22%3A%22termux%22%2C%22name%22%3A%22Termux%3ABoot%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22includeDrafts%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Afalse%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseNotesFilter%5C%22%3Afalse%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%5C%22%2C%5C%22versionDetection%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%2C%5C%22appName%5C%22%3A%5C%22Termux%3ABoot%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22termux%5C%22%7D%22%7D
[com.termux.api]: https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.termux.api%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Ftermux%2Ftermux-api%22%2C%22author%22%3A%22termux%22%2C%22name%22%3A%22Termux%3AAPI%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22includeDrafts%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Afalse%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseNotesFilter%5C%22%3Afalse%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%5C%22%2C%5C%22versionDetection%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%2C%5C%22appName%5C%22%3A%5C%22Termux%3AAPI%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22termux%5C%22%7D%22%7D
[com.termux.widget]: https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%22com.termux.widget%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Ftermux%2Ftermux-widget%22%2C%22author%22%3A%22termux%22%2C%22name%22%3A%22Termux%3AWidget%22%2C%22additionalSettings%22%3A%22%7B%5C%22includePrereleases%5C%22%3Afalse%2C%5C%22includeDrafts%5C%22%3Afalse%2C%5C%22fallbackToOlderReleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseTitlesFilter%5C%22%3Afalse%2C%5C%22filterReleaseNotesByRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertReleaseNotesFilter%5C%22%3Afalse%2C%5C%22verifyLatestTag%5C%22%3Afalse%2C%5C%22sortMethodChoice%5C%22%3A%5C%22date%5C%22%2C%5C%22useLatestAssetDateAsReleaseDate%5C%22%3Afalse%2C%5C%22releaseTitleAsVersion%5C%22%3Afalse%2C%5C%22trackOnly%5C%22%3Afalse%2C%5C%22versionExtractionRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22matchGroupToUse%5C%22%3A%5C%22%5C%22%2C%5C%22versionDetection%5C%22%3Afalse%2C%5C%22useVersionCodeAsOSVersion%5C%22%3Afalse%2C%5C%22apkFilterRegEx%5C%22%3A%5C%22%5C%22%2C%5C%22invertAPKFilter%5C%22%3Afalse%2C%5C%22autoApkFilterByArch%5C%22%3Atrue%2C%5C%22shizukuPretendToBeGooglePlay%5C%22%3Afalse%2C%5C%22allowInsecure%5C%22%3Afalse%2C%5C%22exemptFromBackgroundUpdates%5C%22%3Afalse%2C%5C%22skipUpdateNotifications%5C%22%3Afalse%2C%5C%22refreshBeforeDownload%5C%22%3Afalse%2C%5C%22appName%5C%22%3A%5C%22Termux%3AWidget%5C%22%2C%5C%22appAuthor%5C%22%3A%5C%22termux%5C%22%7D%22%7D
