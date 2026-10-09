# Mushoku Tensei (mobile) — English patch — No PC, No Root

Replaces the game's Japanese text with the English translation.
**Android 11 and newer. No root, no computer.** You need ~5 minutes and two free apps.

The only file you need is **`MT-EN-Applier.apk`**, a small installer app. It downloads
the translation by itself.

> **Updating from v2.2.2 or older?** v2.4.0 is signed with a new key, so Android
> can't install it on top of the old app. Uninstall MT-EN Applier first, then
> install this one. Your game and its English patch are not affected. You only
> do this once; future versions install over this one.

---

## Step 1 — Install Shizuku (one-time, ~2 min)

Shizuku lets the installer app write into the game's data folder without root.

1. Install **Shizuku** from the Play Store.
2. Enable **Developer options** (Settings → About phone → tap **Build number** 7 times).
3. In **Developer options**, turn on **Wireless debugging**.
4. Open **Shizuku** → tap **"Start via wireless debugging" → "Pairing"** →
   it jumps to Wireless debugging → tap **"Pair device with pairing code"** →
   a 6-digit code appears → pull down the notification shade, type the code into
   the Shizuku notification, send.
5. Back in Shizuku, tap **"Start"**. It should say **"Shizuku is running"**.

> Shizuku stops when you reboot. To re-enable: redo steps 4–5 (30 seconds).

---

## Step 2 — Install the game & MT-EN Applier

1. Install **Mushoku Tensei** (無職転生) from the Play Store, **open it once**
   to the title screen (so it downloads its data), then fully close it
   (swipe away from recents).
2. Install **`MT-EN-Applier.apk`** (tap it; allow "install unknown apps" if asked).

---

## Step 3 — Download and apply

1. Open **MT-EN Applier**. If it says **"Shizuku not running"**, tap **Open Shizuku**
   and start it. Allow the permission prompt.
2. Tap **"Download latest patch"**. It downloads and checks the file.
3. Tap **"Apply English patch"** and wait for **"✓ English patch installed"**.
4. Launch the game. Menus, skills, items and story are now in English.

The app tells you when a newer version of itself is out ("Get update").

---

## Notes

- **After a game update**, the game may re-download the Japanese file. Open the app
  and tap **Download latest patch**, then **Apply**. If no patch for the new game
  version is out yet, use **Auto-patch after update (beta)**: the phone rebuilds the
  translation from the new Japanese data (only brand-new text stays Japanese).
- **Back to Japanese:** tap **Delete all language packs (reset)**; the game
  re-downloads the Japanese text.
- The game itself is untouched (stock, Play-signed), so logins and updates keep working.
- Some lines only switch to English the second time a screen loads: go back to the
  title menu and re-enter.

**File check (optional):** `MT-EN-Applier.apk` v2.4.0 — 889,563 bytes,
MD5 `2efbe66b6de7de54dbaaa8456810595c`. Signing certificate SHA-256
`96:84:57:15:19:B4:00:5E:98:EC:43:32:B7:F6:EF:69:D2:2E:8E:30:F0:30:11:57:56:16:5A:80:9E:F2:0D:B1`.

---

## Troubleshooting: "Shizuku stopped"

If Shizuku keeps stopping right after the app connects, your phone is killing the
Shizuku server, usually Android 12+'s *phantom process killer* or an OEM
battery/task killer (Xiaomi / OPPO / vivo / Samsung are the aggressive ones).

1. **Whitelist Shizuku from battery**: Settings → Apps → Shizuku → Battery →
   *Unrestricted*, enable *Autostart*, and don't swipe Shizuku away in recents.
2. **Disable the phantom-process limit** (needs a PC once):
   ```
   adb shell settings put global settings_enable_monitor_phantom_procs false
   ```
   On Android 13+, also: Developer options → *Disable child process restrictions*.
3. Restart Shizuku, then reopen the app.

Still stuck? Tap the status card at the top of the app (**Diagnostics**) and include
the log in an issue: https://github.com/Aikiooo/mt-en-applier/issues
