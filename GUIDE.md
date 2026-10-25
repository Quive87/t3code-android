# Step by step: T3 Code on your Android tablet

Each step says what to do, then what you will see. Do everything on the tablet.

**Before you start:** plug the tablet in, connect to Wi-Fi, and check that it has about 5 GB free
(Settings > Storage). The whole setup takes 30–45 minutes, mostly waiting.

---

## Part 1: Install the apps (about 10 minutes)

### Step 1. Install Obtainium

Obtainium installs the other apps and keeps them up to date.

1. In Chrome, go to **github.com/ImranR98/Obtainium/releases/latest**.
2. Scroll down to **Assets** and tap **app-arm64-v8a-release.apk**.
3. When the download finishes, tap **Open**.
   - *You see:* "For your security, your tablet isn't allowed to install unknown apps from
     this source." Tap **Settings**, turn on **Allow from this source**, and press Back.
4. *You see:* "Do you want to install this app?" Tap **Install**, then **Open**.
   - If Google Play Protect shows a warning, tap **More details > Install anyway**.
5. If Obtainium asks to send notifications, tap **Allow**.

### Step 2. Add T3 Code and Termux to Obtainium

1. In Chrome, go to **github.com/Quive87/t3code-android**.
2. Under **2. Add the apps**, tap **T3 Code (nightly)**. If Chrome asks to open Obtainium, allow it.
   - *You see:* Obtainium opens a box called **Import app**. Tap **Continue**.
   - *You see:* "Imported 1 app". T3 Code is now in Obtainium's list.
3. Go back to Chrome and do the same for **Termux**, **Termux:Boot** and **Termux:API**.
   You can skip Termux:Widget.

### Step 3. Install the four apps

1. In Obtainium, tap **T3 Code**, then tap **Install** at the bottom.
   - The first time, Android asks to allow Obtainium to install apps: tap **Settings**, turn on
     **Allow from this source**, and press Back.
   - *You see:* "Do you want to install this app?" Tap **Install**. T3 Code is a big download
     (about 280 MB), so it takes a minute.
2. Do the same for **Termux**, **Termux:Boot** and **Termux:API**.

If Termux says **App not installed** or **conflicts with an existing package**, an older Termux is
already on the tablet. Uninstall it (long-press its icon > Uninstall) and try again.

### Step 4. Open Termux:Boot once

Open **Termux:Boot** from your apps. *You see:* a short page of text. Close it. That's all: now
T3 Code can start by itself when the tablet restarts.

---

## Part 2: Install T3 Code inside Termux (about 15–25 minutes)

### Step 5. Open Termux

*You see:* "Installing…" for a few seconds (first time only). Then a black screen with
**Welcome to Termux!** and a last line ending in **~ $**. A row of extra keys (ESC, CTRL, arrows)
sits above the keyboard.

### Step 6. Copy the install command

In Chrome on **github.com/Quive87/t3code-android**, find the grey box under
**4. Open Termux and paste** and tap the copy icon in its top-right corner. The box contains:

```sh
curl -fsSL https://raw.githubusercontent.com/Quive87/t3code-android/main/install.sh | bash
```

### Step 7. Paste it into Termux and press Enter

1. Go back to Termux. Long-press anywhere on the black screen and tap **Paste**.
2. Press **Enter** on the keyboard.
3. Leave Termux open on the screen until it finishes. Don't type anything while it works.

*You see:* a lot of scrolling text. That is normal. It goes through these stages, each starting
with **==>**:

| Stage | How long |
|---|---|
| `==> Updating Termux packages` | a few minutes |
| `==> Installing a Debian container` | about a minute |
| `==> Setting up Debian (developer tools, Node.js)` | the longest part, 5–15 minutes |
| `==> Installing T3 Code nightly and agent CLIs` | a few minutes; you see `--- claude`, `--- codex`, `--- grok`, `--- opencode` |
| `==> Starting T3 Code` | ends with **T3 Code is running.** |

If Android asks **Let Termux always run in background?**, tap **Allow**.

At the end you see **All set.** and a box like this (your code is different):

```
Connect the T3 Code app on this device (the code works for 15 minutes):
  1. Open the T3 Code app and tap Add environment
  2. Under "Or enter it", fill in:
       Address:  127.0.0.1:3773
       Code:     AB12CD34EF56
  3. Tap the checkmark at the top.
```

Go straight to Part 3.

If it stops with red **Installation failed** text, paste the same command again and press Enter.
It continues from where it stopped.

---

## Part 3: Connect the T3 Code app (1 minute)

### Step 8. Open the T3 Code app

*You see:* **No environments connected** and a button **Add environment**. Tap it. If it asks to
send notifications, tap **Allow**.

### Step 9. Type the address and code

1. *You see:* a camera box (**Scan QR code**) at the top. Ignore it.
2. Under **Or enter it**:
   - **Address:** `127.0.0.1:3773`
   - **Code:** the code from Termux
3. Tap the **checkmark** at the top.

*You see:* it connects, then **No projects found**. That is correct: the tablet has no projects
yet.

If more than 15 minutes have passed, the code has expired. In Termux, type `t3code pair` and press
Enter to get a new one.

### Step 10. Add a project

Start a new thread, and tap **+** (Add project). Then choose:

- **Git URL** to download a project from GitHub,
- **New project** to start an empty one, or
- **Local folder** to pick a folder.

---

## Part 4: Sign in to the AI models (about 5 minutes)

Your PC's logins don't carry over. Sign in once on the tablet.

### Step 11. In Termux, type each line and press Enter

```sh
t3code login claude
t3code login codex
t3code login grok
t3code login opencode
```

*You see:* the tablet's browser opens a sign-in page. Sign in and approve, then go back to Termux.

- If the page shows a code instead, copy it, go back to Termux, long-press, tap **Paste**, and
  press Enter.
- OpenCode shows a list in Termux: pick with the arrow keys on the extra-keys row, then press
  Enter.
- For GitHub pull requests, also run `t3code login github`.

**Antigravity and Cursor** sign in from inside T3 Code. In Termux, type `t3code open` and press
Enter. T3 Code opens in Chrome. Go to **Settings > Providers**, choose the tablet, turn on
Antigravity or Cursor, tap **Install**, then **Sign in**.

---

## Part 5: Stop Android from closing it (5 minutes, once)

### Step 12. Battery

Settings > Apps > **Termux** > Battery > **Unrestricted**.

### Step 13. Background limit

Check your version in Settings > About tablet > **Android version**, then:

- **Android 14 or newer:**
  1. Settings > About tablet (> Software information) > tap **Build number** 7 times, until it
     says "You are now a developer".
  2. Settings > **Developer options** > turn on **Disable child process restrictions**.
- **Android 12 or 13:** in Termux, type `t3code fix-android`, then type `y` and follow the
  instructions. It uses Wireless debugging, so the tablet needs Wi-Fi.
- **Android 11 or older:** nothing to do.

---

## Part 6: Every day

- Open the **T3 Code** app. It connects to the tablet by itself. Pick a model in the thread
  (Claude, Codex, Grok, OpenCode, ...) and type what you want.
- A Termux notification stays at the top. That's what keeps T3 Code running, so don't swipe it
  away or tap **Exit** in it.
- After restarting the tablet, wait about a minute after unlocking. T3 Code starts by itself.
- Updates install themselves. If the app shows an update, tap it. Obtainium updates the app.

**Optional: use your PC's models too.** In the tablet app, open Settings > Environments >
**Add environment**. Either tap **Sign in to T3 Connect** (same account as on your PC), or on the
PC open Settings > Connections, create a pairing link, and scan its QR code with the tablet app.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| The app can't connect | In Termux, type `t3code start` |
| The code expired | In Termux, type `t3code pair` |
| Agents stop when the screen is off | Do Part 5 again |
| Red **Installation failed** | Run the install command again |
| Anything else | In Termux, type `t3code doctor` and send a screenshot |
