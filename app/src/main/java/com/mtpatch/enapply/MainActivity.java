package com.mtpatch.enapply;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

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

    /** Fallback only: the live patch_size comes from version.json (see
     *  expectedPatchSize()), so size changes never require an app update. */
    private static final long DEFAULT_EXPECTED_SIZE = 1898964L;

    /** Fallback only: the live meta_key_off / meta_iv_off come from version.json.
     *  These move with game updates, so using them triggers a loud warning. */
    private static final int FALLBACK_KEY_OFF = 0xBC3DF0;
    private static final int FALLBACK_IV_OFF = 0xBC6870;

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

    private static final String AUTO_PATCH_ADVICE =
            "Use \"Download latest patch\" once a build is published for this game version.";

    // ---------------- palette (dark) ----------------
    private static final int C_BG = 0xFF121417;
    private static final int C_SURFACE = 0xFF1C2026;
    private static final int C_SURFACE_HI = 0xFF2A3038;
    private static final int C_STROKE = 0xFF333A44;
    private static final int C_TEXT = 0xFFE8EAED;
    private static final int C_TEXT_DIM = 0xFF9AA0A6;
    private static final int C_ACCENT = 0xFF4F8EF7;
    private static final int C_DANGER = 0xFFEF6B6B;
    private static final int C_DISABLED_BG = 0xFF23272D;
    private static final int C_DISABLED_TEXT = 0xFF5F6670;
    private static final int C_LOG_BG = 0xFF0B0D10;
    private static final int C_LOG_TEXT = 0xFFB8C4CE;
    private static final int C_OK = 0xFF4CAF50;
    private static final int C_WARN = 0xFFFFB300;
    private static final int C_ERR = 0xFFEF5350;

    private static final int BTN_PRIMARY = 0, BTN_SECONDARY = 1, BTN_DANGER = 2, BTN_QUIET = 3;

    private static final int LOG_MAX_LINES = 300;

    private static final String PREFS = "applier";
    /** Patch language the user picked (a PatchLanguage code). */
    private static final String PREF_LANG = "lang";
    /** Language of the staged __data: a code, or STAGED_CUSTOM for a picked file. */
    private static final String PREF_STAGED_LANG = "staged_lang";
    private static final String STAGED_CUSTOM = "custom";

    /** Languages published on the release (English first), from version.json. */
    private volatile List<PatchLanguage> languages = new ArrayList<>();
    private LinearLayout langRow;
    private TextView langValue, langHint;

    private TextView logText;
    private ScrollView logScroll;
    private final ArrayDeque<String> logLines = new ArrayDeque<>();
    private TextView statusText, statusHint;
    private GradientDrawable statusDot;
    private Button applyBtn, uninstallBtn, pickBtn, shizukuBtn, shizukuGithubBtn, downloadBtn, autoBtn, resetBtn;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private volatile IUserService service;

    private Shizuku.UserServiceArgs serviceArgs;

    /** One long-running operation at a time; all action buttons grey out while set. */
    private volatile boolean busy = false;
    /** Sticky status label after a successful install (null = none yet). */
    private volatile String doneLabel = null;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            if (binder != null && binder.pingBinder()) {
                service = IUserService.Stub.asInterface(binder);
            } else {
                log("ERROR: dead binder from Shizuku service.");
            }
            refreshStatus();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            // direct shell (newProcess) fallback stays available while shizukuReady
            service = null;
            refreshStatus();
        }
    };

    private final Shizuku.OnRequestPermissionResultListener permListener =
            (requestCode, grantResult) -> {
                if (requestCode == REQ_SHIZUKU) {
                    if (grantResult == PackageManager.PERMISSION_GRANTED) {
                        log("Shizuku permission granted.");
                        shizukuReady = true;
                        refreshStatus();
                        bindService();
                    } else {
                        log("Shizuku permission denied. Reopen the app to retry.");
                        refreshStatus();
                    }
                }
            };

    /** Fires (possibly async) once the Shizuku server delivers its binder to our provider. */
    private final Shizuku.OnBinderReceivedListener binderReceivedListener = this::onShizukuReady;
    private final Shizuku.OnBinderDeadListener binderDeadListener = () -> {
        // Usually the phone's phantom-process/task killer killing Shizuku right
        // after the UserService bind.
        log("Shizuku stopped. Restart it, then reopen this app.\n"
                + "If it keeps stopping: set Shizuku's battery use to \"No restrictions\", or once via PC:\n"
                + "adb shell settings put global settings_enable_monitor_phantom_procs false");
        shizukuReady = false;
        service = null;
        shizukuHandled = false;
        refreshStatus();
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        setTheme(android.R.style.Theme_Material_NoActionBar);
        super.onCreate(savedInstanceState);

        serviceArgs = new Shizuku.UserServiceArgs(
                new ComponentName(getPackageName(), UserService.class.getName()))
                .daemon(true)
                .processNameSuffix("shizuku")
                .debuggable(false)
                .version(1);

        getWindow().setStatusBarColor(C_BG);
        getWindow().setNavigationBarColor(C_BG);
        getWindow().getDecorView().setBackgroundColor(C_BG);

        int pad = dp(16);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(C_BG);
        root.setPadding(pad, pad, pad, pad);

        // ---- header ----
        TextView title = new TextView(this);
        title.setText("MT-EN Applier");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(C_TEXT);
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("Unofficial fan translation for Mushoku Tensei" + versionSuffix());
        subtitle.setTextSize(13);
        subtitle.setTextColor(C_TEXT_DIM);
        subtitle.setPadding(0, dp(2), 0, dp(12));
        root.addView(subtitle);

        // ---- status card: colored dot + short label (tap for diagnostics) ----
        LinearLayout statusCard = new LinearLayout(this);
        statusCard.setOrientation(LinearLayout.HORIZONTAL);
        statusCard.setGravity(Gravity.CENTER_VERTICAL);
        statusCard.setPadding(dp(14), dp(12), dp(14), dp(12));
        statusCard.setBackground(new RippleDrawable(ColorStateList.valueOf(0x22FFFFFF),
                rounded(C_SURFACE, C_STROKE, 12), null));
        statusCard.setClickable(true);
        statusCard.setOnClickListener(v -> runDiagnostics());

        statusDot = new GradientDrawable();
        statusDot.setShape(GradientDrawable.OVAL);
        View dotView = new View(this);
        LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dp(12), dp(12));
        dotLp.setMargins(0, 0, dp(12), 0);
        dotView.setLayoutParams(dotLp);
        dotView.setBackground(statusDot);
        statusCard.addView(dotView);

        LinearLayout statusTexts = new LinearLayout(this);
        statusTexts.setOrientation(LinearLayout.VERTICAL);
        statusText = new TextView(this);
        statusText.setTextSize(16);
        statusText.setTypeface(Typeface.DEFAULT_BOLD);
        statusText.setTextColor(C_TEXT);
        statusTexts.addView(statusText);
        statusHint = new TextView(this);
        statusHint.setTextSize(13);
        statusHint.setTextColor(C_TEXT_DIM);
        statusTexts.addView(statusHint);
        statusCard.addView(statusTexts, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView diagLink = new TextView(this);
        diagLink.setText("Diagnostics");
        diagLink.setTextSize(12);
        diagLink.setTextColor(C_TEXT_DIM);
        diagLink.setPadding(dp(8), 0, 0, 0);
        statusCard.addView(diagLink);
        root.addView(statusCard);

        // ---- patch language: only shown once the release publishes >1 language ----
        langRow = new LinearLayout(this);
        langRow.setOrientation(LinearLayout.HORIZONTAL);
        langRow.setGravity(Gravity.CENTER_VERTICAL);
        langRow.setPadding(dp(14), dp(10), dp(14), dp(10));
        langRow.setBackground(new RippleDrawable(ColorStateList.valueOf(0x22FFFFFF),
                rounded(C_SURFACE, C_STROKE, 12), null));
        langRow.setClickable(true);
        langRow.setOnClickListener(v -> showLanguagePicker());

        LinearLayout langTexts = new LinearLayout(this);
        langTexts.setOrientation(LinearLayout.VERTICAL);
        TextView langLabel = new TextView(this);
        langLabel.setText("Patch language");
        langLabel.setTextSize(15);
        langLabel.setTextColor(C_TEXT);
        langTexts.addView(langLabel);
        langHint = new TextView(this);
        langHint.setTextSize(12);
        langHint.setTextColor(C_TEXT_DIM);
        langTexts.addView(langHint);
        langRow.addView(langTexts, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        langValue = new TextView(this);
        langValue.setTextSize(15);
        langValue.setTypeface(Typeface.DEFAULT_BOLD);
        langValue.setTextColor(C_ACCENT);
        langValue.setPadding(dp(8), 0, 0, 0);
        langRow.addView(langValue);
        langRow.setVisibility(View.GONE);
        LinearLayout.LayoutParams langLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        langLp.topMargin = dp(8);
        root.addView(langRow, langLp);

        // ---- actions (own scroll region; never pushed around by the log) ----
        ScrollView actionsScroll = new ScrollView(this);
        actionsScroll.setVerticalScrollBarEnabled(false);
        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.VERTICAL);
        actions.setPadding(0, dp(4), 0, dp(12));
        actionsScroll.addView(actions);
        root.addView(actionsScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        // Shizuku helpers: visibility/label driven by refreshStatus().
        shizukuBtn = makeButton("Get Shizuku (Play Store)", BTN_SECONDARY, v -> {
            if (isShizukuInstalled()) {
                Intent launch = getPackageManager().getLaunchIntentForPackage(SHIZUKU_PKG);
                if (launch != null) startActivity(launch);
                else log("Could not open Shizuku — launch it from your app drawer.");
            } else {
                openShizukuStorePage();
            }
        });
        actions.addView(shizukuBtn);

        shizukuGithubBtn = makeButton("Get Shizuku (GitHub)", BTN_SECONDARY, v -> {
            try {
                startActivity(new Intent(Intent.ACTION_VIEW,
                        Uri.parse("https://github.com/RikkaApps/Shizuku/releases")));
            } catch (android.content.ActivityNotFoundException e) {
                log("No browser found to open GitHub.");
            }
        });
        actions.addView(shizukuGithubBtn);

        applyBtn = makeButton("Apply English patch", BTN_PRIMARY, v -> onApply());
        actions.addView(applyBtn);

        downloadBtn = makeButton("Download latest patch", BTN_SECONDARY, v -> onDownload());
        actions.addView(downloadBtn);

        pickBtn = makeButton("Choose __data file…", BTN_SECONDARY, v -> openPicker());
        actions.addView(pickBtn);

        actions.addView(sectionCaption("Advanced"));

        resetBtn = makeButton("Delete all language packs (reset)", BTN_DANGER, v -> onResetLangPacks());
        actions.addView(resetBtn);

        autoBtn = makeButton("Auto-patch after update (beta)", BTN_SECONDARY, v -> onAutoPatch());
        actions.addView(autoBtn);

        uninstallBtn = makeButton("Uninstall this app", BTN_QUIET, v -> requestUninstall());
        uninstallBtn.setVisibility(View.GONE);
        actions.addView(uninstallBtn);

        // ---- log: fixed-height, self-scrolling panel ----
        LinearLayout logHeader = new LinearLayout(this);
        logHeader.setOrientation(LinearLayout.HORIZONTAL);
        logHeader.setGravity(Gravity.CENTER_VERTICAL);
        logHeader.setPadding(0, 0, 0, dp(6));
        TextView logTitle = captionText("Log");
        logHeader.addView(logTitle, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView clearLog = new TextView(this);
        clearLog.setText("Clear");
        clearLog.setTextSize(13);
        clearLog.setTextColor(C_ACCENT);
        clearLog.setPadding(dp(12), dp(4), 0, dp(4));
        clearLog.setOnClickListener(v -> {
            logLines.clear();
            logText.setText("");
        });
        logHeader.addView(clearLog);
        root.addView(logHeader);

        logScroll = new ScrollView(this);
        logScroll.setBackground(rounded(C_LOG_BG, C_STROKE, 10));
        logScroll.setScrollBarStyle(View.SCROLLBARS_INSIDE_OVERLAY);
        logText = new TextView(this);
        logText.setTextSize(12);
        logText.setTypeface(Typeface.MONOSPACE);
        logText.setTextColor(C_LOG_TEXT);
        logText.setLineSpacing(0, 1.1f);
        logText.setPadding(dp(10), dp(8), dp(10), dp(8));
        logText.setTextIsSelectable(true);
        logScroll.addView(logText);
        root.addView(logScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(170)));

        setContentView(root);
        initLanguages();
        refreshStatus();

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
            log("Waiting for Shizuku…");
            startDiagnostics();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Shizuku may have been installed/started, or __data dropped in, meanwhile.
        refreshStatus();
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
                    log("Shizuku not detected. Install and start it, then reopen this app"
                            + " and allow the permission prompt.");
                    refreshStatus();
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

    private volatile boolean shizukuHandled = false;
    /** True when the Shizuku server binder is alive + permission granted — enough
     *  for the newProcess shell path even if bindUserService keeps failing. */
    private volatile boolean shizukuReady = false;

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

        if (Shizuku.isPreV11() || (ver != -1 && ver < 11)) {
            log("ERROR: Shizuku v11+ required (found v" + ver + "). Please update Shizuku.");
            refreshStatus();
            return;
        }

        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
            log("Shizuku connected (API v" + ver + ").");
            shizukuReady = true;
            refreshStatus();
            bindService();
        } else {
            log("Requesting Shizuku permission…");
            refreshStatus();
            Shizuku.requestPermission(REQ_SHIZUKU);
        }
    }

    // ---------------- log panel ----------------

    /** Append to the bounded log panel (thread-safe). Blank lines are dropped. */
    private void log(String s) {
        ui.post(() -> appendLog(s));
    }

    private void section(String name) {
        log("— " + name + " —");
    }

    private void appendLog(String s) {
        boolean follow = isLogAtBottom();
        for (String line : s.split("\n")) {
            if (line.trim().isEmpty()) continue;
            logLines.addLast(line);
        }
        while (logLines.size() > LOG_MAX_LINES) logLines.removeFirst();
        logText.setText(String.join("\n", logLines));
        // Follow new output only if the user hasn't scrolled up to read.
        if (follow) logScroll.post(() -> logScroll.scrollTo(0, logText.getHeight()));
    }

    private boolean isLogAtBottom() {
        int viewport = logScroll.getHeight();
        if (viewport == 0) return true;
        return logText.getHeight() - (logScroll.getScrollY() + viewport) <= dp(24);
    }

    // ---------------- status + button state ----------------

    private void setStatus(int color, String label, String hint) {
        statusDot.setColor(color);
        statusText.setText(label);
        statusHint.setText(hint);
        statusHint.setVisibility(hint == null || hint.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private boolean isConnected() {
        return service != null || shizukuReady;
    }

    /** Recompute the status light, button enablement and the Shizuku helper
     *  buttons from current state. Safe to call from any thread. */
    private void refreshStatus() {
        ui.post(() -> {
            boolean connected = isConnected();
            boolean installed = isShizukuInstalled();
            File patch = localPatch();
            boolean fileThere = patch != null && patch.exists();
            PatchLanguage lang = selectedLanguage();
            String staged = stagedLangCode();
            boolean customFile = STAGED_CUSTOM.equals(staged);
            // A staged file of another language must not be applied by mistake.
            boolean havePatch = fileThere && (customFile || staged.equals(lang.code));

            // Language picker: hidden while only English is published.
            langRow.setVisibility(languages.size() > 1 ? View.VISIBLE : View.GONE);
            langRow.setEnabled(!busy);
            langRow.setAlpha(busy ? 0.5f : 1f);
            langValue.setText(lang.name + "  ▾");
            langHint.setText(lang.downloadable() ? "" : "No ready-made download yet: use Auto-patch");
            langHint.setVisibility(lang.downloadable() ? View.GONE : View.VISIBLE);

            // Shizuku helpers: connected -> none; installed -> one "Open Shizuku";
            // not installed -> both store buttons.
            shizukuBtn.setVisibility(connected ? View.GONE : View.VISIBLE);
            shizukuBtn.setText(installed ? "Open Shizuku" : "Get Shizuku (Play Store)");
            shizukuGithubBtn.setVisibility(!connected && !installed ? View.VISIBLE : View.GONE);

            applyBtn.setText(customFile && fileThere ? "Apply chosen file"
                    : lang.isDefault() ? "Apply English patch" : "Apply patch · " + lang.name);
            applyBtn.setEnabled(!busy && connected && havePatch);
            downloadBtn.setEnabled(!busy && lang.downloadable());
            pickBtn.setEnabled(!busy);
            resetBtn.setEnabled(!busy && connected);
            autoBtn.setEnabled(!busy && connected);

            if (!connected) {
                if (!installed) {
                    setStatus(C_ERR, "Shizuku not installed", "Get it below, start it, then reopen this app.");
                } else if (Shizuku.pingBinder()) {
                    setStatus(C_WARN, "Shizuku permission needed", "Allow the prompt, or reopen this app.");
                } else {
                    setStatus(C_ERR, "Shizuku not running", "Open Shizuku and tap Start.");
                }
            } else if (busy) {
                setStatus(C_WARN, "Working…", "See the log below.");
            } else if (doneLabel != null) {
                setStatus(C_OK, doneLabel, "Launch the game. Re-apply after each game update.");
            } else if (havePatch) {
                setStatus(C_OK, "Ready — tap Apply", "Patch file: "
                        + (customFile ? "chosen file" : lang.name) + ", " + fmtBytes(patch.length()));
            } else if (!lang.downloadable()) {
                setStatus(C_WARN, "No " + lang.name + " download yet",
                        "Use Auto-patch (beta) to build it on this phone.");
            } else if (fileThere) {
                setStatus(C_WARN, "No " + lang.name + " patch file yet",
                        "Download it, or switch the patch language back.");
            } else {
                setStatus(C_WARN, "No patch file yet", "Download the latest patch or choose a __data file.");
            }
        });
    }

    private void setBusy(boolean b) {
        busy = b;
        refreshStatus();
    }

    /** Claim the busy flag on the UI thread; false if another operation is running. */
    private boolean tryBegin() {
        if (busy) return false;
        setBusy(true);
        return true;
    }

    private void end() {
        setBusy(false);
    }

    // ---------------- patch languages ----------------

    private android.content.SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    /** The picked language while it's published, else English. The pick itself
     *  is kept, so it comes back once the release lists it again. */
    private PatchLanguage selectedLanguage() {
        List<PatchLanguage> langs = languages;
        PatchLanguage l = PatchLanguage.find(langs,
                prefs().getString(PREF_LANG, PatchLanguage.DEFAULT_CODE));
        if (l == null) l = PatchLanguage.find(langs, PatchLanguage.DEFAULT_CODE);
        return l != null ? l : PatchLanguage.english(new java.util.HashMap<>());
    }

    /** Language of the staged __data. Before languages existed it was always English. */
    private String stagedLangCode() {
        return prefs().getString(PREF_STAGED_LANG, PatchLanguage.DEFAULT_CODE);
    }

    private void setStagedLang(String code) {
        if (code == null) prefs().edit().remove(PREF_STAGED_LANG).apply();
        else prefs().edit().putString(PREF_STAGED_LANG, code).apply();
    }

    /** Parse + save a fetched version.json and refresh the language list from it. */
    private Map<String, Object> saveVersion(String vj) throws Exception {
        Map<String, Object> v = JsonMap.parseObject(vj);
        writeSmall(versionFile(), vj);
        languages = PatchLanguage.fromVersion(v);
        refreshStatus();
        return v;
    }

    /** Saved version.json first (instant, works offline), then a quiet refresh. */
    private void initLanguages() {
        try {
            if (versionFile().exists()) {
                languages = PatchLanguage.fromVersion(JsonMap.parseObject(readSmall(versionFile())));
            }
        } catch (Throwable ignored) {
        }
        new Thread(() -> {
            try {
                saveVersion(Downloader.fetchString(VERSION_URL, s -> {}));
            } catch (Throwable ignored) {
                // offline: keep the saved list
            }
        }, "languages").start();
    }

    private void showLanguagePicker() {
        List<PatchLanguage> langs = languages;
        if (busy || langs.size() < 2) return;
        String current = selectedLanguage().code;
        String[] labels = new String[langs.size()];
        int checked = 0;
        for (int i = 0; i < langs.size(); i++) {
            PatchLanguage l = langs.get(i);
            labels[i] = l.downloadable() ? l.name : l.name + "  (Auto-patch only)";
            if (l.code.equals(current)) checked = i;
        }
        new android.app.AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle("Patch language")
                .setSingleChoiceItems(labels, checked, (d, which) -> {
                    PatchLanguage l = langs.get(which);
                    d.dismiss();
                    if (l.code.equals(current)) return;
                    prefs().edit().putString(PREF_LANG, l.code).apply();
                    doneLabel = null;
                    log("Patch language: " + l.name + ".");
                    refreshStatus();
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    // ---------------- view helpers ----------------

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private String versionSuffix() {
        try {
            return " · v" + getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Throwable t) {
            return "";
        }
    }

    private GradientDrawable rounded(int fill, int stroke, int radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(radiusDp));
        if (stroke != 0) d.setStroke(dp(1), stroke);
        return d;
    }

    private TextView captionText(String text) {
        TextView t = new TextView(this);
        t.setText(text.toUpperCase(Locale.US));
        t.setTextSize(12);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setLetterSpacing(0.08f);
        t.setTextColor(C_TEXT_DIM);
        return t;
    }

    private TextView sectionCaption(String text) {
        TextView t = captionText(text);
        t.setPadding(dp(2), dp(20), 0, dp(2));
        return t;
    }

    /** Flat, dark-theme button whose disabled state is visibly greyed out. */
    private Button makeButton(String text, int style, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setStateListAnimator(null);
        b.setOnClickListener(onClick);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(16), dp(10), dp(16), dp(10));

        int fill, stroke, textColor, height;
        switch (style) {
            case BTN_PRIMARY:
                fill = C_ACCENT; stroke = 0; textColor = 0xFFFFFFFF; height = 56;
                b.setTextSize(17);
                b.setTypeface(Typeface.DEFAULT_BOLD);
                break;
            case BTN_DANGER:
                fill = C_SURFACE; stroke = C_STROKE; textColor = C_DANGER; height = 48;
                b.setTextSize(15);
                break;
            case BTN_QUIET:
                fill = 0x00000000; stroke = 0; textColor = C_TEXT_DIM; height = 44;
                b.setTextSize(14);
                break;
            default:
                fill = C_SURFACE_HI; stroke = 0; textColor = C_TEXT; height = 48;
                b.setTextSize(15);
                break;
        }

        StateListDrawable bg = new StateListDrawable();
        bg.addState(new int[]{-android.R.attr.state_enabled},
                rounded(style == BTN_QUIET ? 0x00000000 : C_DISABLED_BG, 0, 10));
        bg.addState(new int[]{}, rounded(fill, stroke, 10));
        Drawable mask = rounded(0xFFFFFFFF, 0, 10);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), bg, mask));
        b.setTextColor(new ColorStateList(
                new int[][]{{-android.R.attr.state_enabled}, {}},
                new int[]{C_DISABLED_TEXT, textColor}));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(height));
        lp.topMargin = dp(style == BTN_PRIMARY ? 12 : 8);
        b.setLayoutParams(lp);
        return b;
    }

    private static String fmtBytes(long n) {
        return String.format(Locale.US, "%,d B", n);
    }

    /** "…/<hash8>…" for a UnityCache __data path; keeps the log on one line. */
    private static String shortPath(String dest) {
        String[] p = dest.split("/");
        String hash = p.length >= 2 ? p[p.length - 2] : dest;
        if (hash.length() > 8) hash = hash.substring(0, 8) + "…";
        return (dest.contains("/il2cpp/") ? "il2cpp/" : "") + hash;
    }

    // ---------------- Shizuku ----------------

    private boolean isShizukuInstalled() {
        try {
            getPackageManager().getPackageInfo(SHIZUKU_PKG, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    /** System uninstall prompt; if a ROM still refuses it, open this app's
     *  settings page, which always has an Uninstall button. */
    private void requestUninstall() {
        Uri pkg = Uri.parse("package:" + getPackageName());
        try {
            startActivity(new Intent(Intent.ACTION_DELETE, pkg));
        } catch (Throwable t) {
            try {
                startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg));
            } catch (Throwable t2) {
                log("Couldn't open the uninstall prompt; uninstall from Settings > Apps.");
            }
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
        try {
            Shizuku.bindUserService(serviceArgs, connection);
        } catch (Throwable t) {
            log("ERROR binding Shizuku service: " + t.getMessage());
        }
    }

    // ---------------- shell ----------------

    /** Parsed exec result. Both ShellRunner.exec and UserService.exec return
     *  "exit=N\n" + stdout + "[stderr]\n" + stderr (or "exec_error=..."). */
    private static final class ShellResult {
        final int code;
        final String out;
        final String err;

        private ShellResult(int code, String out, String err) {
            this.code = code;
            this.out = out;
            this.err = err;
        }

        static ShellResult parse(String raw) {
            if (raw == null) return new ShellResult(-1, "", "no output");
            if (raw.startsWith("exec_error=")) {
                return new ShellResult(-1, "", raw.substring("exec_error=".length()).trim());
            }
            int code = -1;
            String rest = raw;
            if (raw.startsWith("exit=")) {
                int nl = raw.indexOf('\n');
                String num = nl < 0 ? raw.substring(5) : raw.substring(5, nl);
                try {
                    code = Integer.parseInt(num.trim());
                } catch (NumberFormatException ignored) {
                }
                rest = nl < 0 ? "" : raw.substring(nl + 1);
            }
            String out = rest, err = "";
            int m = rest.startsWith("[stderr]\n") ? 0 : rest.indexOf("\n[stderr]\n");
            if (m >= 0) {
                int cut = m == 0 ? 0 : m + 1;
                out = rest.substring(0, cut);
                err = rest.substring(cut + "[stderr]\n".length());
            }
            return new ShellResult(code, out.trim(), err.trim());
        }

        String firstLine() {
            int nl = out.indexOf('\n');
            return (nl < 0 ? out : out.substring(0, nl)).trim();
        }

        /** " (reason)" for failure messages: first stderr line, else the exit code. */
        String reason() {
            if (!err.isEmpty()) {
                int nl = err.indexOf('\n');
                return " (" + (nl < 0 ? err : err.substring(0, nl)) + ")";
            }
            return code > 0 ? " (exit " + code + ")" : "";
        }
    }

    /** Run a command as the Shizuku (shell) uid: persistent UserService when
     *  bound, otherwise the one-shot newProcess path (for devices where the
     *  server dies spawning a UserService). Same output contract. */
    private String execShell(String cmd) throws android.os.RemoteException {
        IUserService s = service;
        if (s != null) return s.exec(cmd);
        return ShellRunner.exec(cmd);
    }

    /** execShell + parse: exit code and clean stdout/stderr. Use this for
     *  anything logged or parsed — never log a raw exec blob. */
    private ShellResult shell(String cmd) throws android.os.RemoteException {
        return ShellResult.parse(execShell(cmd));
    }

    /** Every live language-bundle copy on the device (may be empty). */
    private List<String> findLiveBundles() throws android.os.RemoteException {
        ShellResult found = shell(
                "for f in " + GAME_CACHE_GLOB + "; do [ -f \"$f\" ] && echo \"FOUND:$f\"; done");
        List<String> dests = new ArrayList<>();
        for (String line : found.out.split("\n")) {
            line = line.trim();
            if (line.startsWith("FOUND:")) dests.add(line.substring(6));
        }
        return dests;
    }

    /** NEWEST live bundle (an old asset-hash folder may linger post-update), or null. */
    private String newestLiveBundle() throws android.os.RemoteException {
        String first = shell("ls -t " + GAME_CACHE_GLOB + " 2>/dev/null | head -1").firstLine();
        return first.startsWith("/sdcard/") ? first : null;
    }

    /** Size of a file on the device as seen by the shell uid, or -1. */
    private long remoteSize(String path) throws android.os.RemoteException {
        String sz = shell("stat -c %s '" + path + "' 2>/dev/null || wc -c < '" + path + "'").firstLine();
        try {
            return Long.parseLong(sz.trim());
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    // ---------------- apply ----------------

    private void onApply() {
        if (!tryBegin()) return;
        new Thread(() -> {
            try {
                doApply();
            } finally {
                ui.post(this::end);
            }
        }, "apply").start();
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
        if (!tryBegin()) return;
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
                setStagedLang(STAGED_CUSTOM);
                long want = expectedPatchSize(selectedLanguage());
                if (total != want) {
                    log("Staged __data: " + fmtBytes(total) + " — expected " + fmtBytes(want)
                            + ". Make sure it's the right file.");
                } else if (isConnected()) {
                    log("Staged __data (" + fmtBytes(total) + ") — tap Apply.");
                } else {
                    log("Staged __data (" + fmtBytes(total) + "). Connect Shizuku, then tap Apply.");
                }
            } catch (Throwable t) {
                log("ERROR reading file: " + t.getMessage());
            } finally {
                ui.post(this::end);
            }
        }, "stage").start();
    }

    private void doApply() {
        try {
            if (!isConnected()) {
                log("Shizuku is not connected. Start Shizuku, then reopen the app.");
                return;
            }
            section("Apply");
            File src = localPatch();
            if (src == null || !src.exists()) {
                log("No patch file. Download it or choose a __data file.");
                return;
            }
            String stagedCode = stagedLangCode();
            PatchLanguage stagedLang = STAGED_CUSTOM.equals(stagedCode)
                    ? null : PatchLanguage.find(languages, stagedCode);
            String what = STAGED_CUSTOM.equals(stagedCode) ? "Chosen patch"
                    : (stagedLang != null ? stagedLang.name : "English") + " patch";
            long len = src.length();
            long want = expectedPatchSize(stagedLang != null ? stagedLang : selectedLanguage());
            if (len != want) {
                log("Note: patch is " + fmtBytes(len) + ", expected " + fmtBytes(want) + " (continuing).");
            }

            shell("am force-stop jp.gree_ent.mushoku");

            // The asset-hash subfolder changes on some game updates, so resolve
            // the live bundle path(s) at apply time and patch every copy found.
            List<String> dests = findLiveBundles();
            boolean fallback = dests.isEmpty();
            if (fallback) {
                log("No live language pack found; trying the default path.");
                dests.add(GAME_CACHE);
            }

            int okCount = 0;
            for (String dest : dests) {
                ShellResult cp = shell("cp '" + src.getAbsolutePath() + "' '" + dest + "' && echo CP_OK");
                if (!cp.out.contains("CP_OK")) {
                    log("✗ " + shortPath(dest) + ": copy failed" + cp.reason());
                    continue;
                }
                shell("chmod 0666 '" + dest + "' 2>/dev/null");
                long got = remoteSize(dest);
                if (got == len) {
                    okCount++;
                } else {
                    log("✗ " + shortPath(dest) + ": size " + (got < 0 ? "unknown" : fmtBytes(got))
                            + " after copy");
                }
            }

            if (okCount > 0) {
                log("✓ " + what + " installed to " + okCount
                        + (okCount == 1 ? " cache location (" : " cache locations (")
                        + fmtBytes(len) + (okCount == 1 ? ")." : " each)."));
                log("Launch the game. Re-apply after each game update.");
                doneLabel = "Patch installed";
                ui.post(() -> uninstallBtn.setVisibility(View.VISIBLE));
            } else if (fallback) {
                log("✗ Copy failed. Is the game installed? Open it once so it downloads its data, then retry.");
            } else {
                log("✗ Copy failed. Retry, or check free space.");
            }
        } catch (Throwable t) {
            log("✗ Apply failed: " + t.getMessage());
        }
    }

    /** Delete every cached language pack so the game re-downloads stock JP.
     *  Use this when our patch made things worse (wrong-version bundle, crash
     *  on load, missing text): the game fetches a clean JP bundle next launch. */
    private void onResetLangPacks() {
        if (!isConnected()) {
            log("Connect Shizuku first (reset needs shell access).");
            return;
        }
        if (!tryBegin()) return;
        new Thread(() -> {
            try {
                section("Reset");
                shell("am force-stop " + GAME_PKG);
                // delete every __data under the language group folder (all versions)
                ShellResult r = shell(
                        "for f in " + GAME_CACHE_GLOB + "; do rm -f \"$f\" && echo \"DEL:$f\"; done");
                int del = 0;
                for (String line : r.out.split("\n")) {
                    if (line.trim().startsWith("DEL:")) del++;
                }
                // also drop our staged patch so a stale __data isn't reapplied later
                File staged = stagedPatch();
                boolean cleared = staged != null && staged.exists() && staged.delete();
                if (cleared) setStagedLang(null);
                log(del > 0
                        ? "Deleted " + del + " language pack(s)" + (cleared ? " and the staged patch" : "")
                                + ". The game re-downloads Japanese on next launch."
                        : "No language packs found (game already clean?)"
                                + (cleared ? " Cleared the staged patch." : ""));
                doneLabel = null;
            } catch (Throwable t) {
                log("✗ Reset failed: " + t.getMessage());
            } finally {
                ui.post(this::end);
            }
        }, "reset").start();
    }

    /** Tap the status card: self-test BOTH shell paths + killer-setting hints. */
    private void runDiagnostics() {
        new Thread(() -> {
            section("Diagnostics");
            IUserService s = service;
            log("UserService bound: " + (s != null)
                    + " | newProcess available: " + ShellRunner.available());
            if (s != null) {
                try {
                    ShellResult id = ShellResult.parse(s.exec("id"));
                    log("UserService: " + (id.out.isEmpty() ? "exit " + id.code + id.reason() : id.firstLine()));
                } catch (Throwable t) {
                    log("UserService exec FAILED: " + t.getMessage());
                }
            }
            ShellResult id = ShellResult.parse(ShellRunner.exec("id"));
            log("newProcess: " + (id.out.isEmpty() ? "exit " + id.code + id.reason() : id.firstLine()));
            ShellResult ph = ShellResult.parse(ShellRunner.exec(
                    "settings get global settings_enable_monitor_phantom_procs"));
            log("phantom_procs: " + (ph.out.isEmpty() ? "?" + ph.reason() : ph.firstLine()));
            log("Device: " + android.os.Build.MODEL + " | Android "
                    + android.os.Build.VERSION.RELEASE);
        }, "diag").start();
    }

    // ---------------- helpers: small files, md5 ----------------

    private File appFile(String name) {
        File dir = getExternalFilesDir(null);
        return dir == null ? new File(getFilesDir(), name) : new File(dir, name);
    }

    /** translation_cache.json (English) or translation_cache.<code>.json. */
    private File cacheFile(PatchLanguage lang) {
        return appFile(lang.isDefault() ? "translation_cache.json"
                : "translation_cache." + lang.code + ".json");
    }

    /** Release stamp (PatchLanguage.cacheStamp) of the cache we hold for a language. */
    private File cacheStampFile(PatchLanguage lang) {
        return appFile(lang.isDefault() ? "translation_cache.stamp"
                : "translation_cache." + lang.code + ".stamp");
    }

    private String cacheUrl(PatchLanguage lang) {
        return lang.isDefault() ? CACHE_URL : RELEASE_BASE + lang.cacheAsset;
    }

    private File versionFile() {
        File dir = getExternalFilesDir(null);
        return dir == null ? new File(getFilesDir(), "version.json")
                : new File(dir, "version.json");
    }

    /** Expected patch size: the language's live patch_size from version.json when
     *  published, else the baked default. Keeps the "size != expected" warnings
     *  correct across game updates without shipping a new APK. */
    private long expectedPatchSize(PatchLanguage lang) {
        return lang.patchSize > 0 ? lang.patchSize : DEFAULT_EXPECTED_SIZE;
    }

    private void writeCacheStamp(PatchLanguage lang) {
        String stamp = lang.cacheStamp();
        if (stamp == null) return;
        try {
            writeSmall(cacheStampFile(lang), stamp);
        } catch (Throwable ignored) {}
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

    /** Size of the newest live language bundle on the device, or -1 if none. */
    private long newestLiveBundleSize() {
        try {
            String src = newestLiveBundle();
            return src == null ? -1 : remoteSize(src);
        } catch (Throwable t) {
            return -1;
        }
    }

    private void onDownload() {
        if (!tryBegin()) return;
        new Thread(() -> {
            try {
                section("Download");
                saveVersion(Downloader.fetchString(VERSION_URL, s -> {}));
                PatchLanguage lang = selectedLanguage();
                if (!lang.downloadable()) {
                    log("No ready-made " + lang.name + " patch for this game version yet.\n"
                            + "Use Auto-patch (beta) to build it on this phone.");
                    return;
                }
                long wantSize = lang.patchSize;
                String wantMd5 = lang.patchMd5;
                log("Latest " + lang.name + " patch: " + fmtBytes(wantSize) + ", built "
                        + (lang.builtAt.isEmpty() ? "?" : lang.builtAt) + ".");
                // Cross-check against the live bundle on the device: if the game
                // updated since this patch was built, the sizes won't match and
                // the downloadable patch is the WRONG version for this game.
                long live = isConnected() ? newestLiveBundleSize() : -1;
                if (live > 0 && wantSize > 0 && live != wantSize) {
                    log("⚠ Your game's language pack is " + fmtBytes(live)
                            + ": the game updated after this patch was built.\n"
                            + "  Applying it would install the wrong version — try Auto-patch (beta) instead.");
                }
                File staged = stagedPatch();
                if (staged.exists() && wantMd5.equalsIgnoreCase(md5Of(staged))) {
                    setStagedLang(lang.code);
                    log("Already up to date.");
                } else {
                    Downloader.fetchToFile(lang.isDefault() ? DATA_URL : RELEASE_BASE + lang.patchAsset,
                            staged, s -> {});
                    String got = md5Of(staged);
                    boolean badSize = wantSize > 0 && staged.length() != wantSize;
                    if (!wantMd5.equalsIgnoreCase(got) || badSize) {
                        // never leave a corrupt file staged under a language label
                        staged.delete();
                        setStagedLang(null);
                        log("✗ Download corrupted (" + (badSize ? "size" : "md5") + " mismatch). Try again.");
                        return;
                    }
                    setStagedLang(lang.code);
                    log("✓ " + lang.name + " patch downloaded and verified.");
                }
                try {
                    Downloader.fetchToFile(cacheUrl(lang), cacheFile(lang), s -> {});
                    writeCacheStamp(lang);
                } catch (Throwable t) {
                    log("⚠ Translation cache not refreshed (" + t.getMessage() + ").");
                }
                log("Ready — tap Apply.");
            } catch (Throwable t) {
                log("✗ Download failed: " + t.getMessage()
                        + "\nCheck your connection, or use \"Choose __data file…\".");
            } finally {
                ui.post(this::end);
            }
        }, "download").start();
    }

    // ---------------- on-device auto-patch (beta) ----------------

    /** Expected, user-explainable auto-patch failure (message is shown as-is). */
    private static final class AutoPatchFail extends Exception {
        AutoPatchFail(String msg) {
            super(msg);
        }
    }

    private void onAutoPatch() {
        if (!isConnected()) {
            log("Connect Shizuku first.");
            return;
        }
        if (!tryBegin()) return;
        new Thread(() -> {
            try {
                doAutoPatch();
            } catch (AutoPatchFail f) {
                log("✗ Auto-patch failed: " + f.getMessage());
                log(AUTO_PATCH_ADVICE);
            } catch (Throwable t) {
                String msg = String.valueOf(t.getMessage());
                int nl = msg.indexOf('\n');
                if (nl >= 0) msg = msg.substring(0, nl);
                log("✗ Auto-patch failed (" + t.getClass().getSimpleName() + ": " + msg + ").");
                log(AUTO_PATCH_ADVICE);
            } finally {
                ui.post(this::end);
            }
        }, "autopatch").start();
    }

    /** Fresh version.json when online (saved for later), else the saved copy, else null. */
    private Map<String, Object> loadReleaseInfo() {
        try {
            return saveVersion(Downloader.fetchString(VERSION_URL, s -> {}));
        } catch (Throwable ignored) {
        }
        try {
            if (versionFile().exists()) {
                log("Offline — using the saved release info.");
                return JsonMap.parseObject(readSmall(versionFile()));
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    /** Re-download the language's translation cache when it's missing or was
     *  fetched for an older release than the one version.json now reports. */
    private void ensureFreshCache(PatchLanguage lang) throws AutoPatchFail {
        File cf = cacheFile(lang);
        String want = lang.cacheStamp();
        String have = "";
        try {
            if (cacheStampFile(lang).exists()) have = readSmall(cacheStampFile(lang)).trim();
        } catch (Throwable ignored) {
        }
        boolean existed = cf.exists();
        if (existed && (want == null || want.equals(have))) return;
        try {
            Downloader.fetchToFile(cacheUrl(lang), cf, s -> {});
            writeCacheStamp(lang);
            log(existed ? "Translation cache updated to the latest release." : "Translation cache downloaded.");
        } catch (Throwable t) {
            if (existed) {
                log("⚠ Couldn't refresh the translation cache; using the older copy.");
            } else {
                throw new AutoPatchFail("translation cache unavailable — connect to the internet and retry.");
            }
        }
    }

    private void doAutoPatch() throws Exception {
        section("Auto-patch (beta)");
        shell("am force-stop " + GAME_PKG);

        // 1. live bundle path(s)
        List<String> dests = findLiveBundles();
        if (dests.isEmpty())
            throw new AutoPatchFail("no language pack on the device. Open the game once so it downloads its data.");

        // source = NEWEST bundle (an old asset-hash folder may linger post-update)
        String newest = newestLiveBundle();
        String srcBundle = newest != null ? newest : dests.get(0);

        // 2. stage bundle + global-metadata into our own dir (shell uid can read them)
        File dir = getExternalFilesDir(null);
        if (dir == null) throw new AutoPatchFail("app storage is unavailable.");
        String q = dir.getAbsolutePath();
        File stockF = new File(dir, "stock_new.__data");
        File metaF = new File(dir, "global-metadata.dat");
        ShellResult r1 = shell("cp '" + srcBundle + "' '" + q
                + "/stock_new.__data' && echo OK1");
        if (!r1.out.contains("OK1"))
            throw new AutoPatchFail("could not read the game's language pack" + r1.reason() + ".");
        ShellResult r2 = shell("cp '" + META_PATH + "' '" + q
                + "/global-metadata.dat' && echo OK2");
        if (!r2.out.contains("OK2")) {
            String mp = shell("find /sdcard/Android/data/" + GAME_PKG
                    + "/files -name global-metadata.dat 2>/dev/null | head -1").firstLine();
            if (!mp.startsWith("/"))
                throw new AutoPatchFail("the game's global-metadata.dat was not found.");
            r2 = shell("cp '" + mp + "' '" + q + "/global-metadata.dat' && echo OK2");
            if (!r2.out.contains("OK2"))
                throw new AutoPatchFail("could not read the game's metadata" + r2.reason() + ".");
        }

        // 3. AES keys from the game's own metadata. Offsets come from the live
        // version.json; the baked fallback goes stale with every game update.
        Map<String, Object> v = loadReleaseInfo();
        PatchLanguage lang = selectedLanguage();
        log("Language: " + lang.name + ".");
        int keyOff = FALLBACK_KEY_OFF, ivOff = FALLBACK_IV_OFF;
        boolean liveOffsets = false;
        if (v != null && v.containsKey("meta_key_off") && v.containsKey("meta_iv_off")) {
            try {
                keyOff = Long.decode(String.valueOf(v.get("meta_key_off")).trim()).intValue();
                ivOff = Long.decode(String.valueOf(v.get("meta_iv_off")).trim()).intValue();
                liveOffsets = true;
            } catch (Throwable ignored) {
                keyOff = FALLBACK_KEY_OFF;
                ivOff = FALLBACK_IV_OFF;
            }
        }
        if (!liveOffsets) {
            log("⚠ WARNING: no release info (version.json) — using BUILT-IN AES key offsets "
                    + String.format(Locale.US, "0x%x/0x%x", keyOff, ivOff) + ".\n"
                    + "⚠ These go stale with game updates. Go online and retry if this fails.");
        }
        String keyMismatch = "the AES keys don't match this game build"
                + (liveOffsets ? "." : " (built-in key offsets were used).");
        byte[] meta = java.nio.file.Files.readAllBytes(metaF.toPath());
        byte[][] keys;
        try {
            keys = MasterCrypto.extractKeys(meta, keyOff, ivOff);
        } catch (IllegalArgumentException e) {
            throw new AutoPatchFail(keyMismatch);
        }

        // 4. translation cache (refreshed whenever the release is newer)
        ensureFreshCache(lang);
        Map<String, Object> pl = JsonMap.parseObject(readSmall(cacheFile(lang)));
        @SuppressWarnings("unchecked")
        Map<String, Object> cacheRaw = (Map<String, Object>) pl.get("cache");
        if (cacheRaw == null) throw new AutoPatchFail("translation cache is malformed — retry while online.");
        Map<String, String> cache = new java.util.LinkedHashMap<>(cacheRaw.size());
        for (Map.Entry<String, Object> e : cacheRaw.entrySet())
            cache.put(e.getKey(), String.valueOf(e.getValue()));
        Map<String, Map<String, String>> hand = new java.util.LinkedHashMap<>();
        Object handObj = pl.get("hand");
        if (handObj instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> hm = (Map<String, Object>) handObj;
            for (Map.Entry<String, Object> e : hm.entrySet()) {
                @SuppressWarnings("unchecked")
                Map<String, Object> inner = (Map<String, Object>) e.getValue();
                Map<String, String> dst = new java.util.LinkedHashMap<>();
                for (Map.Entry<String, Object> e2 : inner.entrySet())
                    dst.put(e2.getKey(), String.valueOf(e2.getValue()));
                hand.put(e.getKey(), dst);
            }
        }

        // 5. known table names (bundled asset)
        List<String> names = new ArrayList<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.InputStreamReader(
                getAssets().open("tables.txt")))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty()) names.add(ln);
            }
        }

        // 6. patch fully on-device. Per-table notes stay out of the UI log;
        // only the summary below is shown.
        byte[] stock = java.nio.file.Files.readAllBytes(stockF.toPath());
        List<String> notes = new ArrayList<>();
        AutoPatcher.Result res;
        try {
            res = AutoPatcher.run(stock, keys[0], keys[1], cache, hand, names, notes::add);
        } catch (IllegalStateException e) {
            if (String.valueOf(e.getMessage()).contains("AES keys")) throw new AutoPatchFail(keyMismatch);
            throw e;
        }
        File outF = new File(dir, "patched.__data");
        java.nio.file.Files.write(outF.toPath(), res.data);

        StringBuilder sum = new StringBuilder("Patched " + res.patched + "/" + res.tablesFound + " tables");
        int missing = names.size() - res.tablesFound;
        if (missing > 0) sum.append(", ").append(missing).append(" not found");
        if (res.fitAfterRevert > 0) sum.append(", ").append(res.fitAfterRevert).append(" trimmed to fit");
        if (res.jaOnly > 0) sum.append(", ").append(res.jaOnly).append(" kept Japanese");
        sum.append(".\n").append(String.format(Locale.US, "%,d", res.leftJaCells))
                .append(" cells left Japanese (new content).");
        log(sum.toString());

        // 7. write back over every live copy
        for (String dest : dests) {
            ShellResult rr = shell("cp '" + outF.getAbsolutePath() + "' '" + dest
                    + "' && echo CP_OK; chmod 0666 '" + dest + "' 2>/dev/null");
            if (!rr.out.contains("CP_OK"))
                throw new AutoPatchFail("could not write " + shortPath(dest) + rr.reason() + ".");
        }
        log("✓ Auto-patch installed to " + dests.size()
                + (dests.size() == 1 ? " cache location" : " cache locations") + ". Launch the game.");
        doneLabel = lang.isDefault() ? "Auto-patch installed" : lang.name + " auto-patch installed";
    }
}
