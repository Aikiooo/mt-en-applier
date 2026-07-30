package com.mtpatch.enapply;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.text.method.ScrollingMovementMethod;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;

import com.mtpatch.enapply.core.AutoPatcher;
import com.mtpatch.enapply.core.JsonMap;
import com.mtpatch.enapply.core.MasterCrypto;

import rikka.shizuku.Shizuku;

/**
 * MT-EN Applier — one-tap installer for the Mushoku Tensei English patch.
 * Uses a Shizuku UserService (shell/ADB uid) to copy __data over the game's
 * UnityCache copy. No root, no PC, no storage permission.
 */
public class MainActivity extends Activity {

    private static final String GAME_CACHE =
            "/sdcard/Android/data/jp.gree_ent.mushoku/files/UnityCache/Shared/"
                    + "cad73e991807559422ab03e01424a9d3/"
                    + "b7499781b4d69361fc70fcf2ee08c1ce/__data";

    /** Candidate locations of the live language bundle. The language pack lives
     *  under the STABLE group folder cad73e99…; only the asset-hash child changes
     *  per update. NEVER broaden this glob: UnityCache holds hundreds of other
     *  asset bundles under sibling group folders. */
    private static final String GAME_CACHE_GLOB =
            "/sdcard/Android/data/jp.gree_ent.mushoku/files/UnityCache/Shared/"
                    + "cad73e991807559422ab03e01424a9d3/*/__data"
                    + " /sdcard/Android/data/jp.gree_ent.mushoku/files/il2cpp/*/UnityCache/Shared/"
                    + "cad73e991807559422ab03e01424a9d3/*/__data";

    private static final long EXPECTED_SIZE = 1779698L;

    private static final String GAME_PKG = "jp.gree_ent.mushoku";
    private static final String RELEASE_BASE =
            "https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/";
    private static final String VERSION_URL = RELEASE_BASE + "version.json";
    private static final String DATA_URL = RELEASE_BASE + "__data";
    private static final String CACHE_URL = RELEASE_BASE + "translation_cache.json";
    private static final String META_PATH =
            "/sdcard/Android/data/jp.gree_ent.mushoku/files/il2cpp/Metadata/global-metadata.dat";
    private static final int REQ_SHIZUKU = 1001;
    private static final int REQ_PICK_FILE = 1002;
    private static final String SHIZUKU_PKG = "moe.shizuku.privileged.api";

    private TextView log;
    private TextView statusText;
    private android.graphics.drawable.GradientDrawable statusDot;
    private Button applyBtn, uninstallBtn, pickBtn, shizukuBtn, downloadBtn, autoBtn;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private IUserService service;

    private Shizuku.UserServiceArgs serviceArgs;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            log("Shizuku service connected.");
            if (binder != null && binder.pingBinder()) {
                service = IUserService.Stub.asInterface(binder);
                applyBtn.setEnabled(true);
                refreshStatus();
            } else {
                log("ERROR: dead binder from Shizuku service.");
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            log("Shizuku user service disconnected (direct shell fallback stays available).");
            service = null;
            applyBtn.setEnabled(shizukuReady);
            refreshStatus();
        }
    };

    private final Shizuku.OnRequestPermissionResultListener permListener =
            (requestCode, grantResult) -> {
                if (requestCode == REQ_SHIZUKU) {
                    if (grantResult == PackageManager.PERMISSION_GRANTED) {
                        log("Shizuku permission granted.");
                        shizukuReady = true;
                        ui.post(() -> applyBtn.setEnabled(true));
                        bindService();
                    } else {
                        log("Shizuku permission DENIED. Reopen app to retry.");
                    }
                }
            };

    /** Fires (possibly async) once the Shizuku server delivers its binder to our provider. */
    private final Shizuku.OnBinderReceivedListener binderReceivedListener = this::onShizukuReady;
    private final Shizuku.OnBinderDeadListener binderDeadListener = () -> {
        log("Shizuku binder died (server stopped). Restart Shizuku and reopen the app."
                + "\nIf this happens right after \"Binding Shizuku user service…\", the"
                + " phone's phantom-process/task killer is killing Shizuku. Fixes:\n"
                + "1. Battery settings: set Shizuku to \"No restrictions\".\n"
                + "2. One-time, via a PC: adb shell settings put global"
                + " settings_enable_monitor_phantom_procs false");
        shizukuReady = false;
        ui.post(() -> applyBtn.setEnabled(false));
        service = null;
        shizukuHandled = false;
        refreshStatus();
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        serviceArgs = new Shizuku.UserServiceArgs(
                new ComponentName(getPackageName(), UserService.class.getName()))
                .daemon(true)
                .processNameSuffix("shizuku")
                .debuggable(false)
                .version(1);

        ScrollView sv = new ScrollView(this);
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        ll.setPadding(pad, pad, pad, pad);
        sv.addView(ll);

        TextView title = new TextView(this);
        title.setText("MT-EN Applier\nMushoku Tensei English patch installer");
        title.setTextSize(18);
        title.setPadding(0, 0, 0, pad / 2);
        ll.addView(title);

        // Status row: colored dot + label (red = need Shizuku, yellow = need file, green = ready)
        LinearLayout statusRow = new LinearLayout(this);
        statusRow.setOrientation(LinearLayout.HORIZONTAL);
        statusRow.setGravity(android.view.Gravity.CENTER_VERTICAL);
        statusRow.setPadding(0, 0, 0, pad / 2);
        int dotSize = (int) (14 * getResources().getDisplayMetrics().density);
        statusDot = new android.graphics.drawable.GradientDrawable();
        statusDot.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        View dotView = new View(this);
        LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dotSize, dotSize);
        dotLp.setMargins(0, 0, pad / 2, 0);
        dotView.setLayoutParams(dotLp);
        dotView.setBackground(statusDot);
        statusRow.addView(dotView);
        statusText = new TextView(this);
        statusText.setTextSize(15);
        statusRow.addView(statusText);
        ll.addView(statusRow);
        statusText.setOnClickListener(v -> runDiagnostics());
        setStatus(0xFFD32F2F, "Waiting for Shizuku — install & start Shizuku, then reopen.");

        log = new TextView(this);
        log.setTextSize(13);
        log.setMovementMethod(new ScrollingMovementMethod());
        log.setPadding(0, 0, 0, pad);
        ll.addView(log);

        shizukuBtn = new Button(this);
        shizukuBtn.setOnClickListener(v -> {
            if (isShizukuInstalled()) {
                Intent launch = getPackageManager().getLaunchIntentForPackage(SHIZUKU_PKG);
                if (launch != null) startActivity(launch);
            } else {
                openShizukuStorePage();
            }
        });
        ll.addView(shizukuBtn);

        pickBtn = new Button(this);
        pickBtn.setText("Choose __data file…");
        pickBtn.setOnClickListener(v -> openPicker());
        ll.addView(pickBtn);

        downloadBtn = new Button(this);
        downloadBtn.setText("Download latest patch");
        downloadBtn.setOnClickListener(v -> onDownload());
        ll.addView(downloadBtn);

        autoBtn = new Button(this);
        autoBtn.setText("Auto-patch after update (beta)");
        autoBtn.setOnClickListener(v -> onAutoPatch());
        ll.addView(autoBtn);

        applyBtn = new Button(this);
        applyBtn.setText("Apply English patch");
        applyBtn.setEnabled(false);
        applyBtn.setOnClickListener(v -> onApply());
        ll.addView(applyBtn);

        uninstallBtn = new Button(this);
        uninstallBtn.setText("Uninstall this app (needed again after each game update)");
        uninstallBtn.setVisibility(View.GONE);
        uninstallBtn.setOnClickListener(v -> startActivity(new Intent(
                Intent.ACTION_DELETE, Uri.parse("package:" + getPackageName()))));
        ll.addView(uninstallBtn);

        setContentView(sv);

        try {
            Shizuku.addRequestPermissionResultListener(permListener);
            Shizuku.addBinderDeadListener(binderDeadListener);
            // Sticky: fires immediately if the binder is already here, otherwise
            // asynchronously when the Shizuku server delivers it to our provider.
            Shizuku.addBinderReceivedListenerSticky(binderReceivedListener);
        } catch (Throwable t) {
            log("Shizuku API unavailable: " + t.getMessage());
        }

        if (Shizuku.pingBinder()) {
            onShizukuReady();
        } else {
            log("Waiting for Shizuku…\n(Install Shizuku, start it, then reopen this app.)");
            startDiagnostics();
        }
    }

    private int pollCount = 0;

    /** Poll quietly for the binder; log only the final outcome. The per-second
     *  handshake dump was useful for debugging but confuses end users. */
    private void startDiagnostics() {
        ui.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (Shizuku.pingBinder()) {
                    onShizukuReady();
                    return;
                }
                pollCount++;
                if (pollCount < 30) {
                    ui.postDelayed(this, 1000);
                } else {
                    log("\nShizuku is not running (or this app is not authorized).\n"
                            + "1. Install Shizuku from the Play Store and start it.\n"
                            + "2. Reopen this app and allow the Shizuku permission prompt.");
                }
            }
        }, 1000);
    }

    @Override
    protected void onDestroy() {
        try {
            Shizuku.removeRequestPermissionResultListener(permListener);
            Shizuku.removeBinderReceivedListener(binderReceivedListener);
            Shizuku.removeBinderDeadListener(binderDeadListener);
            Shizuku.unbindUserService(serviceArgs, connection, true);
        } catch (Throwable ignored) {
        }
        super.onDestroy();
    }

    private boolean shizukuHandled = false;
    /** True when the Shizuku server binder is alive + permission granted — enough
     *  for the newProcess shell path even if bindUserService keeps failing. */
    private boolean shizukuReady = false;

    /** Called once the Shizuku binder is available. Drives permission -> bind.
     *  Guarded: both the sticky listener and the direct ping may fire it. */
    private void onShizukuReady() {
        if (shizukuHandled) return;
        shizukuHandled = true;
        int ver = -1;
        try {
            ver = Shizuku.getVersion();
        } catch (Throwable ignored) {
        }
        log("Shizuku connected. API version: " + ver);

        if (Shizuku.isPreV11() || (ver != -1 && ver < 11)) {
            log("ERROR: Shizuku v11+ required. Please update Shizuku.");
            return;
        }

        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            log("Shizuku permission already granted.");
            shizukuReady = true;
            ui.post(() -> applyBtn.setEnabled(true));
            bindService();
        } else {
            log("Requesting Shizuku permission…");
            Shizuku.requestPermission(REQ_SHIZUKU);
        }
    }

    private void log(String s) {
        ui.post(() -> log.append(s + "\n"));
    }

    private void setStatus(int color, String text) {
        ui.post(() -> {
            statusDot.setColor(color);
            statusText.setText(text);
        });
    }

    /** Recompute the status light and the Shizuku helper button from current state. */
    private void refreshStatus() {
        ui.post(() -> {
            if (service == null) {
                if (isShizukuInstalled()) {
                    shizukuBtn.setText("Open Shizuku & tap Start");
                } else {
                    shizukuBtn.setText("Get Shizuku (Play Store)");
                }
                shizukuBtn.setVisibility(View.VISIBLE);
            } else {
                shizukuBtn.setVisibility(View.GONE);
            }
        });
        if (service == null) {
            setStatus(0xFFD32F2F, isShizukuInstalled()
                    ? "Shizuku is installed but not running — open it and tap Start."
                    : "Shizuku is not installed — get it from the Play Store (button below).");
        } else if (localPatch() != null && localPatch().exists()) {
            setStatus(0xFF388E3C, "Ready — tap \"Apply English patch\".");
        } else {
            setStatus(0xFFF9A825, "Shizuku connected — now choose the __data file below.");
        }
    }

    private boolean isShizukuInstalled() {
        try {
            getPackageManager().getPackageInfo(SHIZUKU_PKG, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    /** Open Shizuku's Play Store page; fall back to the browser if no store app. */
    private void openShizukuStorePage() {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW,
                    Uri.parse("market://details?id=" + SHIZUKU_PKG)));
        } catch (android.content.ActivityNotFoundException e) {
            startActivity(new Intent(Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=" + SHIZUKU_PKG)));
        }
    }

    private void bindService() {
        log("Binding Shizuku user service…");
        try {
            Shizuku.bindUserService(serviceArgs, connection);
        } catch (Throwable t) {
            log("ERROR binding service: " + t.getMessage());
        }
    }

    private void onApply() {
        applyBtn.setEnabled(false);
        new Thread(this::doApply, "apply").start();
    }

    /** The staged copy (from the file picker). Lives on /sdcard (our external
     *  files dir) so the shell-uid Shizuku service can read it. */
    private File stagedPatch() {
        File dir = getExternalFilesDir(null);
        return dir == null ? new File(getFilesDir(), "__data") : new File(dir, "__data");
    }

    private File localPatch() {
        // Prefer the staged copy from the picker; else fall back to the manual drop folder.
        File staged = stagedPatch();
        if (staged.exists()) return staged;
        File dir = getExternalFilesDir(null);
        return dir == null ? null : new File(dir, "__data");
    }

    private void openPicker() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        startActivityForResult(i, REQ_PICK_FILE);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_PICK_FILE && resultCode == RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri != null) stageFile(uri);
        }
    }

    /** Copy the picked file into our files dir (readable by the shell-uid service). */
    private void stageFile(Uri uri) {
        new Thread(() -> {
            try (java.io.InputStream in = getContentResolver().openInputStream(uri);
                 java.io.FileOutputStream out = new java.io.FileOutputStream(stagedPatch())) {
                byte[] buf = new byte[1 << 16];
                int n;
                long total = 0;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    total += n;
                }
                out.flush();
                long size = total;
                log("File staged (" + size + " bytes).");
                refreshStatus();
                if (size != EXPECTED_SIZE) {
                    log("WARNING: size != expected " + EXPECTED_SIZE + ". Make sure it's the right file.");
                } else if (service != null) {
                    log("Ready — tap \"Apply English patch\".");
                } else {
                    log("File OK, but Shizuku is not connected yet — see the note above. "
                            + "The file stays staged; just connect Shizuku and tap Apply.");
                }
            } catch (Throwable t) {
                log("ERROR reading file: " + t.getMessage());
            }
        }, "stage").start();
    }

    /** Run a command as the Shizuku (shell) uid: persistent UserService when
     *  bound, otherwise the one-shot newProcess path (for devices where the
     *  server dies spawning a UserService). Same output contract. */
    private String execShell(String cmd) throws android.os.RemoteException {
        if (service != null) return service.exec(cmd);
        return ShellRunner.exec(cmd);
    }

    private void doApply() {
        try {
            if (service == null && !shizukuReady) {
                log("ERROR: Shizuku is not connected. Reopen the app.");
                return;
            }
            log("Shell path: " + (service != null ? "UserService" : "newProcess fallback"));
            File src = localPatch();
            log("\n— Applying —");
            if (src == null || !src.exists()) {
                log("ERROR: __data not found.\nPlace the English __data file here (any file manager):\n  "
                        + (src == null ? "(no external files dir)" : src.getAbsolutePath())
                        + "\nThen tap Apply again.");
                return;
            }
            long len = src.length();
            log("Local __data size: " + len);
            if (len != EXPECTED_SIZE) {
                log("WARNING: size != expected " + EXPECTED_SIZE + " (continuing anyway).");
            }

            execShell("am force-stop jp.gree_ent.mushoku");

            // The asset-hash subfolder changes on some game updates, so resolve
            // the live bundle path(s) at apply time and patch every copy found.
            String found = execShell(
                    "for f in " + GAME_CACHE_GLOB + "; do [ -f \"$f\" ] && echo \"FOUND:$f\"; done");
            java.util.List<String> dests = new java.util.ArrayList<>();
            for (String line : found.split("\n")) {
                line = line.trim();
                if (line.startsWith("FOUND:")) dests.add(line.substring(6));
            }
            boolean fallback = dests.isEmpty();
            if (fallback) {
                log("No live bundle found via auto-detect; falling back to the known path.\n"
                        + "If this fails, open the game once so it downloads its data.");
                dests.add(GAME_CACHE);
            }

            boolean ok = false;
            for (String dest : dests) {
                log("Copying to game cache:\n  " + dest);
                String r = execShell("cp '" + src.getAbsolutePath() + "' '" + dest + "' && echo CP_OK");
                if (!r.contains("CP_OK")) {
                    log("COPY FAILED for " + dest + "\n" + r);
                    continue;
                }
                execShell("chmod 0666 '" + dest + "' 2>/dev/null");

                String sz = execShell("stat -c %s '" + dest + "' 2>/dev/null || wc -c < '" + dest + "'");
                log("On-device size: " + sz.trim());
                if (sz.contains(String.valueOf(len))) {
                    ok = true;
                } else {
                    log("WARNING: size mismatch after copy to " + dest);
                }
            }

            if (!ok && fallback) {
                log("COPY FAILED.\nIs the game installed and has it downloaded data once?\n"
                        + "Check folder:\n" + GAME_CACHE);
                return;
            }

            if (ok) {
                log("\nSUCCESS — English patch installed.\nLaunch the game; menus/skills/story should be English."
                        + "\n\nAfter a game update the Japanese file is re-downloaded, so you'll need"
                        + " to run this patch again — keeping this app is recommended."
                        + " (Uninstall below if you're sure.)");
                setStatus(0xFF388E3C, "Patch installed! Launch the game.");
                ui.post(() -> uninstallBtn.setVisibility(View.VISIBLE));
            } else {
                log("\nWARNING: size mismatch after copy. Retry, or check free space.");
            }
        } catch (Throwable t) {
            log("ERROR: " + t);
        } finally {
            ui.post(() -> applyBtn.setEnabled(true));
        }
    }

    /** Tap the status line: self-test BOTH shell paths + killer-setting hints. */
    private void runDiagnostics() {
        new Thread(() -> {
            log("\n— Diagnostics —");
            log("UserService bound: " + (service != null)
                    + " | newProcess available: " + ShellRunner.available());
            if (service != null) {
                try {
                    log("UserService id: " + service.exec("id").trim());
                } catch (Throwable t) {
                    log("UserService exec FAILED: " + t.getMessage());
                }
            }
            log("newProcess id: " + ShellRunner.exec("id").trim());
            log("phantom_procs setting: " + ShellRunner.exec(
                    "settings get global settings_enable_monitor_phantom_procs").trim());
            log("device: " + android.os.Build.MODEL + " | Android "
                    + android.os.Build.VERSION.RELEASE);
        }, "diag").start();
    }

    // ---------------- helpers: small files, md5 ----------------

    private File cacheFile() {
        File dir = getExternalFilesDir(null);
        return dir == null ? new File(getFilesDir(), "translation_cache.json")
                : new File(dir, "translation_cache.json");
    }

    private File versionFile() {
        File dir = getExternalFilesDir(null);
        return dir == null ? new File(getFilesDir(), "version.json")
                : new File(dir, "version.json");
    }

    private static String readSmall(File f) throws Exception {
        return new String(java.nio.file.Files.readAllBytes(f.toPath()),
                java.nio.charset.StandardCharsets.UTF_8);
    }

    private static void writeSmall(File f, String s) throws Exception {
        java.nio.file.Files.write(f.toPath(), s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    private static String md5Of(File f) throws Exception {
        return MasterCrypto.md5Hex(java.nio.file.Files.readAllBytes(f.toPath()));
    }

    // ---------------- download latest patch (P1) ----------------

    private void onDownload() {
        downloadBtn.setEnabled(false);
        new Thread(() -> {
            try {
                log("\n— Checking latest patch —");
                String vj = Downloader.fetchString(VERSION_URL, this::log);
                java.util.Map<String, String> v = JsonMap.parseFlat(vj);
                writeSmall(versionFile(), vj);
                long wantSize = Long.parseLong(v.getOrDefault("patch_size", "0"));
                String wantMd5 = v.getOrDefault("patch_md5", "");
                log("Latest: " + wantSize + " bytes, built " + v.getOrDefault("built_at", "?"));
                File staged = stagedPatch();
                if (staged.exists() && wantMd5.equalsIgnoreCase(md5Of(staged))) {
                    log("You already have the latest patch — nothing to download.");
                } else {
                    log("Downloading patch…");
                    Downloader.fetchToFile(DATA_URL, staged, this::log);
                    String got = md5Of(staged);
                    if (!wantMd5.equalsIgnoreCase(got)) {
                        log("ERROR: md5 mismatch after download (" + got + ")");
                        return;
                    }
                    if (wantSize > 0 && staged.length() != wantSize) {
                        log("ERROR: size mismatch after download");
                        return;
                    }
                    log("Patch downloaded & verified.");
                }
                try {
                    Downloader.fetchToFile(CACHE_URL, cacheFile(), this::log);
                    log("Translation cache refreshed.");
                } catch (Throwable t) {
                    log("(cache refresh failed, keeping old one: " + t.getMessage() + ")");
                }
                log("Done — tap \"Apply English patch\".");
                ui.post(this::refreshStatus);
            } catch (Throwable t) {
                log("DOWNLOAD ERROR: " + t.getMessage()
                        + "\nCheck internet, or use \"Choose __data file…\" instead.");
            } finally {
                ui.post(() -> downloadBtn.setEnabled(true));
            }
        }, "download").start();
    }

    // ---------------- on-device auto-patch (beta) ----------------

    private void onAutoPatch() {
        if (service == null && !shizukuReady) {
            log("ERROR: connect Shizuku first.");
            return;
        }
        if (service == null) {
            log("UserService not bound — using newProcess fallback.");
        }
        autoBtn.setEnabled(false);
        new Thread(() -> {
            try {
                doAutoPatch();
            } catch (Throwable t) {
                log("AUTO-PATCH FAILED: " + t.getMessage()
                        + "\nFallback: \"Download latest patch\" works once we publish a build"
                        + " for this game version.");
            } finally {
                ui.post(() -> autoBtn.setEnabled(true));
            }
        }, "autopatch").start();
    }

    private void doAutoPatch() throws Exception {
        log("\n— Auto-patch (fully on-device) —");
        execShell("am force-stop " + GAME_PKG);

        // 1. live bundle path(s)
        String found = execShell("for f in " + GAME_CACHE_GLOB
                + "; do [ -f \"$f\" ] && echo \"FOUND:$f\"; done");
        java.util.List<String> dests = new java.util.ArrayList<>();
        for (String line : found.split("\n")) {
            line = line.trim();
            if (line.startsWith("FOUND:")) dests.add(line.substring(6));
        }
        if (dests.isEmpty())
            throw new IllegalStateException("no language bundle found — run the game once first");

        // source = NEWEST bundle (an old asset-hash folder may linger post-update)
        String srcQ = execShell("ls -t " + GAME_CACHE_GLOB + " 2>/dev/null | head -1")
                .replace("exit=0", "").trim();
        String srcBundle = srcQ.startsWith("/sdcard/") ? srcQ.split("\n")[0] : dests.get(0);
        log("source bundle (newest): " + srcBundle);

        // 2. stage bundle + global-metadata into our own dir (shell uid can read them)
        File dir = getExternalFilesDir(null);
        if (dir == null) throw new IllegalStateException("no external files dir");
        String q = dir.getAbsolutePath();
        File stockF = new File(dir, "stock_new.__data");
        File metaF = new File(dir, "global-metadata.dat");
        String r1 = execShell("cp '" + srcBundle + "' '" + q
                + "/stock_new.__data' && echo OK1");
        if (!r1.contains("OK1")) throw new IllegalStateException("cannot read bundle:\n" + r1);
        String r2 = execShell("cp '" + META_PATH + "' '" + q
                + "/global-metadata.dat' && echo OK2");
        if (!r2.contains("OK2")) {
            log("metadata not at the usual path, searching…");
            String fr = execShell("find /sdcard/Android/data/" + GAME_PKG
                    + "/files -name global-metadata.dat 2>/dev/null | head -1");
            String mp = fr.replace("exit=0", "").trim();
            if (!mp.startsWith("/"))
                throw new IllegalStateException("global-metadata.dat not found on device");
            r2 = execShell("cp '" + mp + "' '" + q + "/global-metadata.dat' && echo OK2");
            if (!r2.contains("OK2"))
                throw new IllegalStateException("cannot read metadata:\n" + r2);
        }

        // 3. AES keys from the game's own metadata (offsets from version.json or defaults)
        int keyOff = 0xBCEA58, ivOff = 0xBD6228;
        try {
            if (versionFile().exists()) {
                java.util.Map<String, String> v = JsonMap.parseFlat(readSmall(versionFile()));
                if (v.containsKey("meta_key_off")) keyOff = Long.decode(v.get("meta_key_off")).intValue();
                if (v.containsKey("meta_iv_off")) ivOff = Long.decode(v.get("meta_iv_off")).intValue();
            }
        } catch (Throwable ignored) {}
        byte[] meta = java.nio.file.Files.readAllBytes(metaF.toPath());
        byte[][] keys = MasterCrypto.extractKeys(meta, keyOff, ivOff);

        // 4. translation cache (download once, then reuse)
        if (!cacheFile().exists()) {
            log("downloading translation cache (one-time)…");
            Downloader.fetchToFile(CACHE_URL, cacheFile(), this::log);
        }
        java.util.Map<String, Object> pl = JsonMap.parseObject(readSmall(cacheFile()));
        @SuppressWarnings("unchecked")
        java.util.Map<String, Object> cacheRaw = (java.util.Map<String, Object>) pl.get("cache");
        java.util.Map<String, String> cache = new java.util.LinkedHashMap<>(cacheRaw.size());
        for (java.util.Map.Entry<String, Object> e : cacheRaw.entrySet())
            cache.put(e.getKey(), String.valueOf(e.getValue()));
        java.util.Map<String, java.util.Map<String, String>> hand = new java.util.LinkedHashMap<>();
        Object handObj = pl.get("hand");
        if (handObj instanceof java.util.Map) {
            @SuppressWarnings("unchecked")
            java.util.Map<String, Object> hm = (java.util.Map<String, Object>) handObj;
            for (java.util.Map.Entry<String, Object> e : hm.entrySet()) {
                @SuppressWarnings("unchecked")
                java.util.Map<String, Object> inner = (java.util.Map<String, Object>) e.getValue();
                java.util.Map<String, String> dst = new java.util.LinkedHashMap<>();
                for (java.util.Map.Entry<String, Object> e2 : inner.entrySet())
                    dst.put(e2.getKey(), String.valueOf(e2.getValue()));
                hand.put(e.getKey(), dst);
            }
        }

        // 5. known table names (bundled asset)
        java.util.List<String> names = new java.util.ArrayList<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.InputStreamReader(
                getAssets().open("tables.txt")))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty()) names.add(ln);
            }
        }

        // 6. patch fully on-device
        byte[] stock = java.nio.file.Files.readAllBytes(stockF.toPath());
        AutoPatcher.Result res = AutoPatcher.run(stock, keys[0], keys[1], cache, hand, names, this::log);
        File outF = new File(dir, "patched.__data");
        java.nio.file.Files.write(outF.toPath(), res.data);
        log("patched " + res.patched + "/" + res.tablesFound + " tables; "
                + res.leftJaCells + " cells left Japanese (new content); "
                + res.data.length + " bytes");

        // 7. write back over every live copy
        for (String dest : dests) {
            String rr = execShell("cp '" + outF.getAbsolutePath() + "' '" + dest
                    + "' && echo CP_OK; chmod 0666 '" + dest + "' 2>/dev/null");
            if (!rr.contains("CP_OK"))
                throw new IllegalStateException("write failed for " + dest + "\n" + rr);
            log("written: " + dest);
        }
        log("\nSUCCESS — auto-patched on device. Launch the game!");
        setStatus(0xFF388E3C, "Auto-patch installed! Launch the game.");
    }
}
