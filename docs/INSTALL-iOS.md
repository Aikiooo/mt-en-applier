# English patch on iPhone / iPad

Free, no cable, no jailbreak. You need a **Windows PC on the same Wi-Fi** as the iPhone,
only while the game downloads its data (a few minutes). The PC hands the game English
copies of its text and image files; the game keeps them, so afterwards you play without
the PC.

You need the free **[WireGuard](https://apps.apple.com/app/wireguard/id1441195209)** app
on the iPhone and about 150 MB free on the PC.

## 1. Start the patch on the PC

1. Download **[MT-EN-iOS.zip](https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest/MT-EN-iOS.zip)**,
   right-click it › **Extract All**.
2. Double-click **Installer-iOS.bat** in the extracted folder.
   - Windows may warn that the file comes from the internet: **Run** (or **More info** ›
     **Run anyway**).
   - The first time it downloads [mitmproxy](https://mitmproxy.org) (86 MB, checked
     against its official fingerprint) into `%LOCALAPPDATA%\MT-EN-iOS`.
   - If Windows Firewall asks: tick **Private networks** and **Allow**. The iPhone
     connects through it.
3. A page opens in your browser with three steps and two QR codes. It follows what the
   iPhone does and turns each step green. **Keep the black window open** until the end.

## 2. Connect the iPhone

1. Install **WireGuard** from the App Store.
2. In WireGuard: **+** › **Create from QR code**, scan the **first** QR code on the PC page,
   name it `MT EN`, **Allow** the VPN configuration, then switch the tunnel **on**.
   Any other VPN must be off: iOS runs one at a time.

Step 1 on the PC page turns green: *iPhone connected*.

Only the game's download server goes through the PC. Everything else (other apps, the
game's login and purchases) passes straight through untouched.

## 3. Trust the patch certificate (first time only)

The game's downloads are encrypted (HTTPS). The PC made its own certificate so it can
answer them; iOS asks you to approve it twice.

1. With the Camera, scan the **second** QR code on the PC page (or type `http://10.0.0.53`
   in Safari). A page opens on the iPhone.
2. Tap **Download the certificate** › **Allow** › **Close**.
3. iPhone **Settings** › **Profile Downloaded** (near the top) › **Install**, your
   passcode, **Install**, **Done**.
4. **Settings** › **General** › **About** › **Certificate Trust Settings** (at the very
   bottom) › switch on **mitmproxy** › **Continue**.
5. Go back to the page in Safari: it turns **green** by itself, and so does step 2 on the PC.

⚠️ **Wait for green before opening the game.** Without the trusted certificate the game
can't download anything while the tunnel is on.

The certificate was made on your PC and never leaves it.

## 4. Download the game data in English

- **New player:** just open the game and let it download.
- **Already playing:** on the title screen open the menu (**メニュー**, top right) and
  choose **Delete local data** (*ローカルデータ削除*, *Suppression des données locales*).
  It only removes downloaded files; **your account and progress stay**. Then tap the
  screen: the game downloads its data again.

  ⚠️ **Never** the option that deletes player data (*データ削除*, *Supprimer les données*).
  That one erases your save.

The bar on the PC page counts the English files sent. When it says **Done**:

1. Switch the WireGuard tunnel **off** on the iPhone.
2. Close the black window on the PC.

The English files stay in the game.

## Good to know

- **Load twice.** The title-screen menu, the loading tips of the very first load and the
  title logo live inside the app, which iOS doesn't let anyone change. A few texts also
  show in English only after you go back to the title screen once (same as on Android).
- **After a game update** the game downloads new Japanese files. Wait for the new patch
  (announced on [mtcoe.com](https://mtcoe.com/#/en-patch)), then run **Installer-iOS.bat**
  again, switch the tunnel on and open the game. The certificate is already trusted. If
  some screens stay Japanese, do **Delete local data** again with the tunnel on.
  The PC page says so if the game is newer than the patch.
- **Step 1 stays grey?** The iPhone and the PC must be on the same Wi-Fi (not a guest
  network), and the firewall prompt must have been allowed. Re-run the bat if you
  closed the prompt; or in *Windows Security* › *Firewall* › *Allow an app*, allow
  `mitmdump`.
- **"Download failed" in the game?** Check the tunnel is on and the PC window open, then
  retry. The PC page lists files it couldn't send.
- **Back to Japanese:** with the tunnel off, **Delete local data** in the game menu.
- **Remove everything:** delete the `MT EN` tunnel in WireGuard; *Settings* › *General* ›
  *VPN & Device Management* › *mitmproxy* › **Remove Profile**; on the PC delete
  `%LOCALAPPDATA%\MT-EN-iOS`.
- Already own **Shadowrocket**, **Surge**, **Loon** or **Egern Pro**? Those apps can do the
  same without a PC, with this module (its MITM certificate enabled):
  `https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest/mt-en-ios.sgmodule`
  (Egern: `.../mt-en-ios.yaml`). They're paid; the PC method above is free.
