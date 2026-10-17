package com.mtpatch.enapply;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.app.Dialog;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
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
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

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

    /** App releases are tagged vX.Y.Z and carry APK_ASSET (see checkForAppUpdate). */
    private static final String RELEASES_API =
            "https://api.github.com/repos/Aikiooo/mt-en-applier/releases?per_page=30";
    private static final String RELEASES_PAGE = "https://github.com/Aikiooo/mt-en-applier/releases";
    private static final String APK_ASSET = "MT-EN-Applier.apk";

    private static final String AUTO_PATCH_ADVICE =
            "Tap Install again once a patch is published for this game version.";

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
    /** md5 of the last bundle Auto-patch wrote: matches neither the published
     *  patch nor stock, so the live check must not call it "game updated". */
    private static final String PREF_AUTOPATCH_MD5 = "autopatch_md5";
    /** md5 of the Japanese bundle the last Auto-patch was built from. */
    private static final String PREF_AUTOPATCH_BASE = "autopatch_base_md5";
    /** md5 of the saved Japanese original (originalJa()), "" = none. */
    private static final String PREF_ORIGINAL_MD5 = "original_ja_md5";
    /** The player opted in to translated images (off by default). */
    private static final String PREF_IMAGES = "images_optin";
    /** Language of the images in the game's cache, "" = Japanese (ours not installed). */
    private static final String PREF_IMAGES_LANG = "images_lang";
    /** md5s of every image bundle this app wrote (comma-separated), any language:
     *  a cached bundle may only be overwritten when it is stock or one of these. */
    private static final String PREF_IMAGES_WRITTEN = "images_written";
    /** Name folders of the image bundles of the installed set (comma-separated). */
    private static final String PREF_IMAGES_BUNDLES = "images_bundles";
    private static final String STAGED_CUSTOM = "custom";

    /** Languages published on the release (English first), from version.json. */
    private volatile List<PatchLanguage> languages = new ArrayList<>();
    private LinearLayout langRow, updateCard;
    private TextView updateText;
    private volatile String updatePageUrl;
    private TextView langValue, langHint;

    private TextView logText;
    private ScrollView logScroll;
    private final ArrayDeque<String> logLines = new ArrayDeque<>();
    private TextView statusText, statusHint;
    private ProgressBar progressBar;
    private View statusDotView;
    private ObjectAnimator dotPulse;
    private LinearLayout imagesRow;
    private Switch imagesSwitch;
    private TextView imagesHint;
    private Button removeImagesBtn;
    private GradientDrawable statusDot;
    private Button applyBtn, uninstallBtn, pickBtn, shizukuBtn, shizukuGithubBtn, autoBtn, resetBtn;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private volatile IUserService service;

    private Shizuku.UserServiceArgs serviceArgs;

    /** One long-running operation at a time; all action buttons grey out while set. */
    private volatile boolean busy = false;
    /** Sticky status label after a successful install (null = none yet). */
    private volatile String doneLabel = null;
    /** Auto-patch progress 0..100 shown on the status card, -1 = none. */
    private volatile int progressPct = -1;
    private volatile String progressPhase = "";
    /** What the running operation is, for the status card ("Applying patch…"). */
    private volatile String busyLabel = "Working…";

    /** md5 of the newest live bundle from the last read-only check: null = not
     *  checked / unknown, "" = no live bundle, else 32 hex chars. */
    private volatile String liveMd5 = null;
    /** version.json "patch_md5_history": md5s of earlier English patches, comma-
     *  separated (the app's JSON reader has no arrays). A live bundle matching one
     *  is an outdated patch, not a game update. */
    private volatile String patchHistory = "";
    private String lastLoggedStaleMd5 = null;
    private final java.util.concurrent.atomic.AtomicBoolean liveChecking =
            new java.util.concurrent.atomic.AtomicBoolean(false);

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            if (binder != null && binder.pingBinder()) {
                service = IUserService.Stub.asInterface(binder);
            } else {
                log("ERROR: dead binder from Shizuku service.");
            }
            refreshStatus();
            checkLiveBundle();
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
                        checkLiveBundle();
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
        liveMd5 = null;
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

        // ---- app update banner (hidden until a newer release is found) ----
        updateCard = new LinearLayout(this);
        updateCard.setOrientation(LinearLayout.HORIZONTAL);
        updateCard.setGravity(Gravity.CENTER_VERTICAL);
        updateCard.setPadding(dp(14), dp(10), dp(10), dp(10));
        updateCard.setBackground(rounded(C_SURFACE, C_ACCENT, 12));
        updateText = new TextView(this);
        updateText.setTextSize(14);
        updateText.setTextColor(C_TEXT);
        updateCard.addView(updateText, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button updateBtn = makeButton("Get update", BTN_PRIMARY, v -> openUpdatePage());
        updateBtn.setTextSize(14);
        LinearLayout.LayoutParams ubLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(40));
        ubLp.leftMargin = dp(8);
        updateCard.addView(updateBtn, ubLp);
        updateCard.setVisibility(View.GONE);
        LinearLayout.LayoutParams ucLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        ucLp.bottomMargin = dp(8);
        root.addView(updateCard, ucLp);

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
        statusDotView = dotView;

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
        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setProgressTintList(ColorStateList.valueOf(C_ACCENT));
        progressBar.setIndeterminateTintList(ColorStateList.valueOf(C_ACCENT));
        progressBar.setVisibility(View.GONE);
        LinearLayout.LayoutParams barLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(6));
        barLp.setMargins(0, dp(8), 0, 0);
        statusTexts.addView(progressBar, barLp);
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

        // ---- translated images: opt-in, shown once the release publishes any ----
        imagesRow = new LinearLayout(this);
        imagesRow.setOrientation(LinearLayout.HORIZONTAL);
        imagesRow.setGravity(Gravity.CENTER_VERTICAL);
        imagesRow.setPadding(dp(14), dp(10), dp(10), dp(10));
        imagesRow.setBackground(rounded(C_SURFACE, C_STROKE, 12));
        LinearLayout imgTexts = new LinearLayout(this);
        imgTexts.setOrientation(LinearLayout.VERTICAL);
        TextView imgLabel = new TextView(this);
        imgLabel.setText("Translated images");
        imgLabel.setTextSize(15);
        imgLabel.setTextColor(C_TEXT);
        imgTexts.addView(imgLabel);
        imagesHint = new TextView(this);
        imagesHint.setTextSize(12);
        imagesHint.setTextColor(C_TEXT_DIM);
        imgTexts.addView(imagesHint);
        imagesRow.addView(imgTexts, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        imagesSwitch = new Switch(this);
        imagesSwitch.setThumbTintList(new ColorStateList(
                new int[][]{{android.R.attr.state_checked}, {}}, new int[]{C_ACCENT, C_TEXT_DIM}));
        imagesSwitch.setTrackTintList(new ColorStateList(
                new int[][]{{android.R.attr.state_checked}, {}}, new int[]{0x804F8EF7, C_STROKE}));
        imagesSwitch.setChecked(prefs().getBoolean(PREF_IMAGES, false));
        imagesSwitch.setOnCheckedChangeListener((b, on) -> {
            if (on == prefs().getBoolean(PREF_IMAGES, false)) return;
            prefs().edit().putBoolean(PREF_IMAGES, on).apply();
            log(on ? "Translated images: on. They are installed with the next Install."
                    : "Translated images: off. Images already installed stay until you tap "
                            + "\"Remove translated images\" or switch language.");
            refreshStatus();
        });
        imagesRow.addView(imagesSwitch);
        imagesRow.setVisibility(View.GONE);
        LinearLayout.LayoutParams imgLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        imgLp.topMargin = dp(8);
        root.addView(imagesRow, imgLp);

        // ---- actions (the whole screen scrolls) ----
        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.VERTICAL);
        actions.setPadding(0, dp(4), 0, dp(16));
        root.addView(actions, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

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

        // One button does it all: download the published patch, check it against the
        // game, and build the translation here (Auto-patch) when it doesn't fit.
        LinearLayout installRow = new LinearLayout(this);
        installRow.setOrientation(LinearLayout.HORIZONTAL);
        applyBtn = makeButton("Install English", BTN_PRIMARY, v -> onInstall());
        installRow.addView(applyBtn, new LinearLayout.LayoutParams(0, dp(56), 1f));
        Button installHelp = makeButton("?", BTN_SECONDARY, v -> showInstallHelp());
        installHelp.setPadding(0, 0, 0, 0);
        installHelp.setTextSize(17);
        installHelp.setTypeface(Typeface.DEFAULT_BOLD);
        installHelp.setContentDescription("How does Install work?");
        LinearLayout.LayoutParams helpLp = new LinearLayout.LayoutParams(dp(56), dp(56));
        helpLp.leftMargin = dp(8);
        installRow.addView(installHelp, helpLp);
        LinearLayout.LayoutParams installLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        installLp.topMargin = dp(12);
        actions.addView(installRow, installLp);

        actions.addView(sectionCaption("Advanced"));

        autoBtn = makeButton("Rebuild on this phone (Auto-patch)", BTN_SECONDARY, v -> onAutoPatch());
        actions.addView(autoBtn);

        pickBtn = makeButton("Install a __data file…", BTN_SECONDARY, v -> openPicker());
        actions.addView(pickBtn);

        resetBtn = makeButton("Delete all language packs (reset)", BTN_DANGER, v -> onResetLangPacks());
        actions.addView(resetBtn);

        removeImagesBtn = makeButton("Remove translated images", BTN_DANGER, v -> onRemoveImages());
        removeImagesBtn.setVisibility(View.GONE);
        actions.addView(removeImagesBtn);

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
        logScroll.setNestedScrollingEnabled(true);   // scrolls inside the page's scroll
        root.addView(logScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(260)));

        ScrollView page = new ScrollView(this);
        page.setBackgroundColor(C_BG);
        page.setFillViewport(true);
        page.setVerticalScrollBarEnabled(false);
        page.addView(root);
        setContentView(page);
        initLanguages();
        checkForAppUpdate();
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
            checkLiveBundle();
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
            PatchLanguage lang = selectedLanguage();

            // Language picker: hidden while only English is published.
            langRow.setVisibility(languages.size() > 1 ? View.VISIBLE : View.GONE);
            langRow.setEnabled(!busy);
            langRow.setAlpha(busy ? 0.5f : 1f);
            langValue.setText(lang.name + "  ▾");
            langHint.setText(lang.downloadable() ? "" : "Built on this phone: no ready-made download");
            langHint.setVisibility(lang.downloadable() ? View.GONE : View.VISIBLE);

            // Shizuku helpers: connected -> none; installed -> one "Open Shizuku";
            // not installed -> both store buttons.
            shizukuBtn.setVisibility(connected ? View.GONE : View.VISIBLE);
            shizukuBtn.setText(installed ? "Open Shizuku" : "Get Shizuku (Play Store)");
            shizukuGithubBtn.setVisibility(!connected && !installed ? View.VISIBLE : View.GONE);

            applyBtn.setText("Install " + lang.name);
            applyBtn.setEnabled(!busy && connected);
            pickBtn.setEnabled(!busy && connected);
            resetBtn.setEnabled(!busy && connected);
            autoBtn.setEnabled(!busy && connected);
            progressBar.setVisibility(busy ? View.VISIBLE : View.GONE);
            progressBar.setIndeterminate(progressPct < 0);
            if (progressPct >= 0) progressBar.setProgress(progressPct);

            boolean anyImages = false;
            for (PatchLanguage l : languages) anyImages |= l.hasImages();
            imagesRow.setVisibility(anyImages ? View.VISIBLE : View.GONE);
            imagesSwitch.setEnabled(!busy);
            imagesHint.setText(lang.hasImages()
                    ? "Buttons, banners and logos · " + (lang.imagesSize > 0
                            ? String.format(Locale.US, "%.0f MB", lang.imagesSize / 1e6) : "download")
                    : "None for " + lang.name + " yet");
            String imgLang = prefs().getString(PREF_IMAGES_LANG, "");
            removeImagesBtn.setVisibility(anyImages || !imgLang.isEmpty() ? View.VISIBLE : View.GONE);
            removeImagesBtn.setEnabled(!busy && connected);

            if (!connected) {
                if (!installed) {
                    setStatus(C_ERR, "Shizuku not installed", "Get it below, start it, then reopen this app.");
                } else if (Shizuku.pingBinder()) {
                    setStatus(C_WARN, "Shizuku permission needed", "Allow the prompt, or reopen this app.");
                } else {
                    setStatus(C_ERR, "Shizuku not running", "Open Shizuku and tap Start.");
                }
            } else if (busy && progressPct >= 0) {
                setStatus(C_ACCENT, busyLabel + " " + progressPct + "%", progressPhase);
            } else if (busy) {
                setStatus(C_ACCENT, busyLabel, progressPhase.isEmpty() ? "See the log below." : progressPhase);
            } else if (doneLabel != null) {
                setStatus(C_OK, doneLabel, "Launch the game. Tap Install again after each game update.");
            } else if (liveState(lang) == LIVE_PATCHED) {
                setStatus(C_OK, "Patch installed", "Launch the game.");
            } else if (liveState(lang) == LIVE_OUTDATED) {
                setStatus(C_WARN, "Older patch installed", "Tap Install to update it.");
            } else if (liveState(lang) == LIVE_UPDATED) {
                setStatus(C_WARN, "Game updated", "Tap Install to translate it again.");
            } else {
                setStatus(C_ACCENT, "Not installed yet", "Tap Install " + lang.name + ".");
            }
        });
    }

    private void setBusy(boolean b) {
        busy = b;
        ui.post(() -> {
            // a slow pulse on the status dot while something runs
            if (b && dotPulse == null) {
                dotPulse = ObjectAnimator.ofFloat(statusDotView, View.ALPHA, 1f, 0.25f);
                dotPulse.setDuration(700);
                dotPulse.setRepeatMode(ValueAnimator.REVERSE);
                dotPulse.setRepeatCount(ValueAnimator.INFINITE);
                dotPulse.start();
            } else if (!b && dotPulse != null) {
                dotPulse.cancel();
                dotPulse = null;
                statusDotView.setAlpha(1f);
            }
        });
        refreshStatus();
    }

    /** Claim the busy flag on the UI thread; false if another operation is running.
     *  The label names the operation on the status card while it runs. */
    private boolean tryBegin(String label) {
        if (busy) return false;
        busyLabel = label;
        progressPct = -1;
        progressPhase = "";
        setBusy(true);
        return true;
    }

    private void end() {
        progressPct = -1;
        progressPhase = "";
        setBusy(false);
        checkLiveBundle();
    }

    // ---------------- live bundle check (read-only) ----------------

    private static final int LIVE_UNKNOWN = 0, LIVE_PATCHED = 1, LIVE_STOCK = 2, LIVE_UPDATED = 3,
            LIVE_OUTDATED = 4;

    /** Classify the last-read live bundle md5 against the published release.
     *  UNKNOWN when not checked, no bundle, no release info, or it holds another
     *  language's patch. */
    private int liveState(PatchLanguage lang) {
        String md5 = liveMd5;
        List<PatchLanguage> langs = languages;
        if (md5 == null || md5.isEmpty() || langs.isEmpty()) return LIVE_UNKNOWN;
        if (!lang.patchMd5.isEmpty() && md5.equalsIgnoreCase(lang.patchMd5)) return LIVE_PATCHED;
        if (md5.equalsIgnoreCase(prefs().getString(PREF_AUTOPATCH_MD5, ""))) return LIVE_PATCHED;
        for (PatchLanguage l : langs) {
            if (!l.patchMd5.isEmpty() && md5.equalsIgnoreCase(l.patchMd5)) return LIVE_UNKNOWN;
        }
        String stock = langs.get(0).stockMd5;   // top-level stock_md5 (the game's stock pack)
        if (stock.isEmpty()) return LIVE_UNKNOWN;
        if (md5.equalsIgnoreCase(stock)) return LIVE_STOCK;
        for (String h : patchHistory.split(",")) {
            if (md5.equalsIgnoreCase(h.trim())) return LIVE_OUTDATED;
        }
        return LIVE_UPDATED;
    }

    /** md5 of the newest live bundle read via the shell uid: "" if there is no
     *  bundle, null if md5sum is unavailable or its output isn't a hash. */
    private String readLiveMd5() throws android.os.RemoteException {
        String path = newestLiveBundle();
        if (path == null) return "";
        String tok = shell("md5sum '" + path + "' 2>/dev/null").out.trim().split("\\s+")[0];
        return tok.matches("[0-9a-fA-F]{32}") ? tok.toLowerCase(Locale.US) : null;
    }

    /** Background, read-only: hash the live bundle and refresh the status line.
     *  Skipped while another operation runs (the caller re-triggers from end()). */
    private void checkLiveBundle() {
        if (!isConnected() || busy || languages.isEmpty()) return;
        if (!liveChecking.compareAndSet(false, true)) return;
        new Thread(() -> {
            try {
                String md5 = readLiveMd5();
                if (busy) return;   // an operation started meanwhile; end() will re-check
                liveMd5 = md5;
                if (liveState(selectedLanguage()) == LIVE_UPDATED && !md5.equals(lastLoggedStaleMd5)) {
                    lastLoggedStaleMd5 = md5;
                    log("Game's language pack differs from the published patch (game updated?).");
                }
                refreshStatus();
            } catch (Throwable ignored) {
                // status simply stays as it was
            } finally {
                liveChecking.set(false);
            }
        }, "live-check").start();
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
        patchHistory = String.valueOf(v.getOrDefault("patch_md5_history", ""));
        languages = PatchLanguage.fromVersion(v);
        refreshStatus();
        return v;
    }

    /** Saved version.json first (instant, works offline), then a quiet refresh. */
    private void initLanguages() {
        try {
            if (versionFile().exists()) {
                Map<String, Object> saved = JsonMap.parseObject(readSmall(versionFile()));
                patchHistory = String.valueOf(saved.getOrDefault("patch_md5_history", ""));
                languages = PatchLanguage.fromVersion(saved);
            }
        } catch (Throwable ignored) {
        }
        new Thread(() -> {
            try {
                saveVersion(Downloader.fetchString(VERSION_URL, s -> {}));
            } catch (Throwable ignored) {
                // offline: keep the saved list
            }
            checkLiveBundle();
        }, "languages").start();
    }

    private void showLanguagePicker() {
        List<PatchLanguage> langs = languages;
        if (busy || langs.size() < 2) return;
        String current = selectedLanguage().code;
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        Dialog[] sheet = new Dialog[1];
        for (PatchLanguage l : langs) {
            boolean sel = l.code.equals(current);
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(14), dp(12), dp(14), dp(12));
            row.setBackground(new RippleDrawable(ColorStateList.valueOf(0x22FFFFFF),
                    rounded(sel ? C_SURFACE_HI : C_BG, sel ? C_ACCENT : C_STROKE, 12), null));
            LinearLayout texts = new LinearLayout(this);
            texts.setOrientation(LinearLayout.VERTICAL);
            TextView name = new TextView(this);
            name.setText(l.name);
            name.setTextSize(16);
            name.setTypeface(Typeface.DEFAULT_BOLD);
            name.setTextColor(sel ? C_ACCENT : C_TEXT);
            texts.addView(name);
            TextView sub = new TextView(this);
            sub.setText((l.downloadable() ? "Ready-made download" : "Built on this phone with Auto-patch")
                    + (l.hasImages() ? " · images" : ""));
            sub.setTextSize(12);
            sub.setTextColor(C_TEXT_DIM);
            texts.addView(sub);
            row.addView(texts, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            if (sel) {
                TextView check = new TextView(this);
                check.setText("✓");
                check.setTextSize(18);
                check.setTextColor(C_ACCENT);
                row.addView(check);
            }
            row.setOnClickListener(v -> {
                sheet[0].dismiss();
                if (l.code.equals(current)) return;
                prefs().edit().putString(PREF_LANG, l.code).apply();
                doneLabel = null;
                log("Patch language: " + l.name + ".");
                refreshStatus();
            });
            LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            rlp.topMargin = dp(8);
            list.addView(row, rlp);
        }
        sheet[0] = showSheet("Patch language", null, list, null, null, "Cancel");
    }

    /** A dialog in the app's own look: rounded dark card, our buttons.
     *  primary may be null (then only the quiet secondary button shows). */
    private Dialog showSheet(String title, String message, View extra,
                             String primary, Runnable onPrimary, String secondary) {
        Dialog d = new Dialog(this);
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(20), dp(20), dp(12));
        box.setBackground(rounded(C_SURFACE, C_STROKE, 16));
        TextView t = new TextView(this);
        t.setText(title);
        t.setTextSize(19);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setTextColor(C_TEXT);
        box.addView(t);
        if (message != null) {
            TextView m = new TextView(this);
            m.setText(message);
            m.setTextSize(14);
            m.setTextColor(C_TEXT_DIM);
            m.setLineSpacing(0, 1.15f);
            m.setPadding(0, dp(10), 0, 0);
            box.addView(m);
        }
        if (extra != null) box.addView(extra);
        if (primary != null) {
            box.addView(makeButton(primary, BTN_PRIMARY, v -> {
                d.dismiss();
                if (onPrimary != null) onPrimary.run();
            }));
        }
        if (secondary != null) box.addView(makeButton(secondary, BTN_QUIET, v -> d.dismiss()));
        d.setContentView(box);
        d.show();
        android.view.Window w = d.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new ColorDrawable(0));
            int width = Math.min(getResources().getDisplayMetrics().widthPixels - dp(32), dp(440));
            w.setLayout(width, ViewGroup.LayoutParams.WRAP_CONTENT);
        }
        return d;
    }

    // ---------------- view helpers ----------------

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private String installedVersion() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Throwable t) {
            return null;
        }
    }

    // ---------------- app update check ----------------

    /** Quiet launch-time check: highest vX.Y.Z release that carries the APK.
     *  Doesn't trust GitHub's "Latest" flag (a PC or patch release can take it). */
    private void checkForAppUpdate() {
        String current = installedVersion();
        if (current == null) return;
        new Thread(() -> {
            try {
                org.json.JSONArray rels = new org.json.JSONArray(
                        Downloader.fetchString(RELEASES_API, s -> {}));
                String bestTag = null, bestUrl = null;
                for (int i = 0; i < rels.length(); i++) {
                    org.json.JSONObject r = rels.getJSONObject(i);
                    if (r.optBoolean("draft") || r.optBoolean("prerelease")) continue;
                    String tag = r.optString("tag_name");
                    if (!tag.matches("v\\d+(\\.\\d+){0,2}")) continue;
                    org.json.JSONArray assets = r.optJSONArray("assets");
                    boolean hasApk = false;
                    for (int j = 0; assets != null && j < assets.length(); j++) {
                        if (APK_ASSET.equals(assets.getJSONObject(j).optString("name"))) hasApk = true;
                    }
                    if (!hasApk) continue;
                    if (bestTag == null || compareVersions(tag.substring(1), bestTag.substring(1)) > 0) {
                        bestTag = tag;
                        bestUrl = r.optString("html_url");
                    }
                }
                if (bestTag == null || compareVersions(bestTag.substring(1), current) <= 0) return;
                String tag = bestTag, url = bestUrl;
                ui.post(() -> {
                    updatePageUrl = url;
                    updateText.setText("Update available: " + tag + " (you have v" + current + ")");
                    updateCard.setVisibility(View.VISIBLE);
                });
            } catch (Throwable ignored) {
                // offline / rate-limited: try again next launch
            }
        }, "update-check").start();
    }

    /** Numeric dotted compare ("2.10" > "2.9"); missing parts count as 0. */
    private static int compareVersions(String a, String b) {
        String[] x = a.split("\\."), y = b.split("\\.");
        for (int i = 0; i < Math.max(x.length, y.length); i++) {
            int p = i < x.length ? parseIntSafe(x[i]) : 0;
            int q = i < y.length ? parseIntSafe(y[i]) : 0;
            if (p != q) return Integer.compare(p, q);
        }
        return 0;
    }

    private static int parseIntSafe(String s) {
        try {
            return Integer.parseInt(s.replaceAll("[^0-9].*$", ""));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private void openUpdatePage() {
        String url = updatePageUrl != null && updatePageUrl.startsWith("https://github.com/")
                ? updatePageUrl : RELEASES_PAGE;
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (android.content.ActivityNotFoundException e) {
            log("No browser found. Get the update at " + RELEASES_PAGE);
        }
    }

    private String versionSuffix() {
        String v = installedVersion();
        return v == null ? "" : " · v" + v;
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
    /** After a successful install: what to expect in game, and a shortcut to it.
     *  The game boots on the Japanese text built into its own APK (which no patch
     *  can change) and only switches to the patched language pack once the title
     *  screen has loaded, so screens built before that, notably the loading tips,
     *  stay Japanese until the player returns to the title once. */
    private void showInstallHelp() {
        if (isFinishing()) return;
        showSheet("How Install works",
                "1. It downloads the latest published patch for the language, if there is one.\n\n"
                        + "2. It checks that patch against your game: the same tables, with the same "
                        + "lines.\n\n"
                        + "3. If your game updated since the patch was made, or no patch is published "
                        + "for the language, it builds the translation on this phone from the game's "
                        + "own Japanese text, in a few seconds (Auto-patch). Text the translation "
                        + "doesn't cover yet stays Japanese until a new patch is out.\n\n"
                        + "Tap Install again after each game update: the game replaces the patch "
                        + "when it downloads new data. Translated images, when turned on, are "
                        + "installed with it.",
                null, null, null, "Close");
    }

    private void showInstalledDialog(String title) {
        if (isFinishing()) return;
        showSheet(title, "Launch the game: menus, story and skills are now translated.\n\n"
                        + "Some text, like the loading tips, stays Japanese until you go back "
                        + "to the title screen once after starting the game. That text is built "
                        + "into the game app itself, which the patch can't change.",
                null, "Launch game", this::launchGame, "Close");
    }

    private void launchGame() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(GAME_PKG);
        if (launch == null) {
            log("Couldn't find the game. Is it installed?");
            return;
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(launch);
        } catch (Throwable t) {
            log("Couldn't open the game: " + t.getMessage());
        }
    }

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
        if (!tryBegin("Reading the file…")) return;
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
                section("Install a file");
                log("Read " + fmtBytes(total) + ".");
                busyLabel = "Installing the file…";
                doApply();
                stagedPatch().delete();   // used once; Install downloads its own
                setStagedLang(null);
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
            File src = localPatch();
            if (src == null || !src.exists()) {
                log("No patch file to install.");
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

            // After a game update the downloaded patch lacks the new rows (and would
            // drop them): build the patch on the phone instead.
            Boolean fits = patchFitsGame(src);
            if (Boolean.FALSE.equals(fits) && stagedLang == null) {
                log("⚠ This file doesn't match your game's current text (made for another game"
                        + " version?). Installing it anyway.");
            } else if (Boolean.FALSE.equals(fits)) {
                log("Your game has newer text than this patch (it updated since the patch was made)."
                        + " Auto-patching instead.");
                busyLabel = "Auto-patching…";
                runAutoPatch();
                return;
            }
            if (fits == null) log("Couldn't compare the patch with your game; installing it as is.");

            shell("am force-stop jp.gree_ent.mushoku");
            saveOriginalIfStock();

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
                syncImages(stagedLang != null ? stagedLang : selectedLanguage(), 0, 100);
                log("Launch the game. Tap Install again after each game update.");
                doneLabel = "Patch installed";
                ui.post(() -> uninstallBtn.setVisibility(View.VISIBLE));
                ui.post(() -> showInstalledDialog(what + " installed"));
            } else if (fallback) {
                log("✗ Copy failed. Is the game installed? Open it once so it downloads its data, then retry.");
            } else {
                log("✗ Copy failed. Retry, or check free space.");
            }
        } catch (Throwable t) {
            log("✗ Install failed: " + t.getMessage());
        }
    }

    /** Mark every cached language pack as not downloaded (invalidateLangPacks)
     *  so the game re-downloads stock JP.
     *  Use this when our patch made things worse (wrong-version bundle, crash
     *  on load, missing text): the game fetches a clean JP bundle next launch. */
    private void onResetLangPacks() {
        if (!isConnected()) {
            log("Connect Shizuku first (reset needs shell access).");
            return;
        }
        if (!tryBegin("Resetting language packs…")) return;
        new Thread(() -> {
            try {
                section("Reset");
                shell("am force-stop " + GAME_PKG);
                // mark every cached language pack (all versions) as not downloaded
                int del = invalidateLangPacks();
                // also drop our staged patch so a stale __data isn't reapplied later
                File staged = stagedPatch();
                boolean cleared = staged != null && staged.exists() && staged.delete();
                if (cleared) setStagedLang(null);
                log(del > 0
                        ? "Reset " + del + " language pack(s)" + (cleared ? " and cleared the staged patch" : "")
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

    /** Download the published patch, check it against the game and install it;
     *  build the translation on the phone when there is none or it doesn't fit. */
    private void onInstall() {
        if (!isConnected()) {
            log("Connect Shizuku first.");
            return;
        }
        if (!tryBegin("Installing…")) return;
        new Thread(() -> {
            try {
                section("Install " + selectedLanguage().name);
                if (downloadPatch()) doApply();
                else runAutoPatch();
            } finally {
                ui.post(this::end);
            }
        }, "install").start();
    }

    /** Stage the selected language's published patch, verified. False when there is
     *  none for this game version or it can't be fetched (then Auto-patch builds it). */
    private boolean downloadPatch() {
        progress(-1, "Checking for the latest patch");
        File staged = stagedPatch();
        PatchLanguage lang;
        try {
            saveVersion(Downloader.fetchString(VERSION_URL, s -> {}));
            lang = selectedLanguage();
        } catch (Throwable t) {
            lang = selectedLanguage();
            boolean have = lang.downloadable() && staged.exists() && lang.code.equals(stagedLangCode());
            log("Offline (" + t.getMessage() + ")" + (have ? ": installing the patch downloaded earlier."
                    : ": building the translation on this phone."));
            return have;
        }
        if (!lang.downloadable()) {
            log("No ready-made " + lang.name + " patch for this game version: building it on this phone.");
            return false;
        }
        try {
            log("Latest " + lang.name + " patch: built "
                    + (lang.builtAt.isEmpty() ? "?" : lang.builtAt.replace('T', ' ')) + ".");
            if (staged.exists() && lang.patchMd5.equalsIgnoreCase(md5Of(staged))) {
                setStagedLang(lang.code);
            } else {
                progress(-1, "Downloading the " + lang.name + " patch");
                Downloader.fetchToFile(lang.isDefault() ? DATA_URL : RELEASE_BASE + lang.patchAsset,
                        staged, s -> {});
                boolean badSize = lang.patchSize > 0 && staged.length() != lang.patchSize;
                if (badSize || !lang.patchMd5.equalsIgnoreCase(md5Of(staged))) {
                    // never leave a corrupt file staged under a language label
                    staged.delete();
                    setStagedLang(null);
                    log("✗ Download corrupted (" + (badSize ? "size" : "md5") + " mismatch):"
                            + " building the translation on this phone instead.");
                    return false;
                }
                setStagedLang(lang.code);
                log("✓ Downloaded and verified (" + fmtBytes(staged.length()) + ").");
            }
            try {
                Downloader.fetchToFile(cacheUrl(lang), cacheFile(lang), s -> {});
                writeCacheStamp(lang);
            } catch (Throwable t) {
                log("⚠ Translation cache not refreshed (" + t.getMessage() + ").");
            }
            return true;
        } catch (Throwable t) {
            log("✗ Download failed (" + t.getMessage() + "): building the translation on this phone.");
            return false;
        }
    }

    // ---------------- on-device auto-patch ----------------

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
        if (!tryBegin("Auto-patching…")) return;
        new Thread(() -> {
            try {
                runAutoPatch();
            } finally {
                ui.post(this::end);
            }
        }, "autopatch").start();
    }

    /** doAutoPatch with its failures logged. */
    private void runAutoPatch() {
        try {
            doAutoPatch(false);
        } catch (AutoPatchFail f) {
            log("✗ Auto-patch failed: " + f.getMessage());
            log(AUTO_PATCH_ADVICE);
        } catch (Throwable t) {
            String msg = String.valueOf(t.getMessage());
            int nl = msg.indexOf('\n');
            if (nl >= 0) msg = msg.substring(0, nl);
            log("✗ Auto-patch failed (" + t.getClass().getSimpleName() + ": " + msg + ").");
            log(AUTO_PATCH_ADVICE);
        }
    }

    /** Whether the patch holds the same rows as the game's live language pack.
     *  Row ids are the same in every language, so they tell game builds apart
     *  whatever the text. null when it can't be checked. */
    private Boolean patchFitsGame(File patch) {
        try {
            String live = newestLiveBundle();
            File dir = getExternalFilesDir(null);
            if (live == null || dir == null) return null;
            File liveF = new File(dir, "live_check.__data");
            if (!shell("cp '" + live + "' '" + liveF.getAbsolutePath() + "' && echo OK").out.contains("OK"))
                return null;
            byte[][] k = gameKeys(dir);
            List<String> names = tableNames();
            Map<String, List<String>> game = AutoPatcher.rowIds(
                    java.nio.file.Files.readAllBytes(liveF.toPath()), k[0], k[1], names,
                    (pct, phase) -> progress(pct / 2, "Checking the patch against your game"));
            liveF.delete();
            Map<String, List<String>> ours = AutoPatcher.rowIds(
                    java.nio.file.Files.readAllBytes(patch.toPath()), k[0], k[1], names,
                    (pct, phase) -> progress(50 + pct / 2, "Checking the patch against your game"));
            if (game.size() < 100 || ours.size() < 100) return null;
            return game.equals(ours);
        } catch (Throwable t) {
            return null;
        }
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

    // ---------------- translated images ----------------
    // The game caches its image bundles like the language pack:
    // UnityCache/Shared/<name folder>/<version folder>/__data. The release zip
    // holds, per language, each patched bundle under its name folder plus a
    // manifest (src_md5 = stock, out_md5 = ours); see tools/prefab-patch/
    // build_android_images.py. A cached bundle is overwritten only when it is
    // stock or one this app wrote, so a game update leaves new bundles alone.

    private static final String GAME_SHARED =
            "/sdcard/Android/data/" + GAME_PKG + "/files/UnityCache/Shared/";

    private static Set<String> csvSet(String csv) {
        Set<String> out = new java.util.HashSet<>();
        for (String x : csv.split(",")) if (!x.trim().isEmpty()) out.add(x.trim().toLowerCase(Locale.US));
        return out;
    }

    /** After a language is installed: that language's images when the player
     *  opted in, else take away images of another language (never a mix). */
    private void syncImages(PatchLanguage lang, int p0, int p1) {
        try {
            String installed = prefs().getString(PREF_IMAGES_LANG, "");
            if (prefs().getBoolean(PREF_IMAGES, false) && lang.hasImages()) {
                installImages(lang, p0, p1);
            } else if (!installed.isEmpty() && !installed.equals(lang.code)) {
                log("Removing the translated images of the previous language.");
                removeImages();
            }
        } catch (Throwable t) {
            log("⚠ Images not updated (" + t.getMessage() + "). The text patch is installed.");
        }
    }

    /** "md5  name/version/__data" for every cached copy of the given bundles. */
    private Map<String, String> cachedImageMd5s(java.util.Collection<String> names) throws Exception {
        Map<String, String> out = new java.util.LinkedHashMap<>();
        List<String> all = new ArrayList<>(names);
        for (int i = 0; i < all.size(); i += 40) {
            StringBuilder cmd = new StringBuilder("cd " + GAME_SHARED + " && md5sum");
            for (String n : all.subList(i, Math.min(all.size(), i + 40))) cmd.append(' ').append(n).append("/*/__data");
            for (String line : shell(cmd + " 2>/dev/null").out.split("\n")) {
                String[] parts = line.trim().split("\\s+");
                if (parts.length == 2 && parts[0].matches("[0-9a-fA-F]{32}"))
                    out.put(parts[1], parts[0].toLowerCase(Locale.US));
            }
        }
        return out;
    }

    private void installImages(PatchLanguage lang, int p0, int p1) throws Exception {
        int span = p1 - p0;
        progress(p0, "Downloading the translated images");
        File zip = appFile("images-" + lang.code + ".zip");
        if (!zip.exists() || !lang.imagesMd5.equalsIgnoreCase(md5Of(zip))) {
            Downloader.fetchToFile(RELEASE_BASE + lang.imagesAsset, zip, s -> {});
            if (!lang.imagesMd5.equalsIgnoreCase(md5Of(zip))) {
                zip.delete();
                throw new Exception("image download corrupted, retry");
            }
        }

        // unpack next to it (the shell uid copies from there)
        progress(p0 + span / 4, "Unpacking the images");
        File dir = appFile("images-" + lang.code);
        File[] old = dir.listFiles();
        if (old != null) for (File f : old) f.delete();
        dir.mkdirs();
        org.json.JSONArray manifest = null;
        try (java.util.zip.ZipInputStream zin = new java.util.zip.ZipInputStream(
                new java.io.FileInputStream(zip))) {
            java.util.zip.ZipEntry ze;
            while ((ze = zin.getNextEntry()) != null) {
                String n = ze.getName();
                if (n.equals("manifest.json")) {
                    manifest = new org.json.JSONArray(new String(readAll(zin), java.nio.charset.StandardCharsets.UTF_8));
                } else if (n.matches("[0-9a-f]{32}")) {
                    java.nio.file.Files.write(new File(dir, n).toPath(), readAll(zin));
                }
            }
        }
        if (manifest == null) throw new Exception("image zip has no manifest");

        Map<String, String[]> wanted = new java.util.LinkedHashMap<>();   // name -> {src, out}
        for (int i = 0; i < manifest.length(); i++) {
            org.json.JSONObject e = manifest.getJSONObject(i);
            String n = e.getString("bundle");
            if (n.matches("[0-9a-f]{32}") && new File(dir, n).exists())
                wanted.put(n, new String[]{e.getString("src_md5").toLowerCase(Locale.US),
                        e.getString("out_md5").toLowerCase(Locale.US)});
        }

        // overwrite every cached copy that is stock or ours; keep its __info valid
        progress(p0 + span / 2, "Installing the images");
        Set<String> ours = csvSet(prefs().getString(PREF_IMAGES_WRITTEN, ""));
        for (String[] so : wanted.values()) ours.add(so[1]);
        List<String> cmds = new ArrayList<>();
        Set<String> done = new java.util.HashSet<>();
        Set<String> seen = new java.util.HashSet<>();
        for (Map.Entry<String, String> c : cachedImageMd5s(wanted.keySet()).entrySet()) {
            String rel = c.getKey(), md5 = c.getValue();
            String name = rel.substring(0, rel.indexOf('/'));
            String[] so = wanted.get(name);
            if (so == null) continue;
            seen.add(name);
            String info = GAME_SHARED + rel.substring(0, rel.lastIndexOf('/')) + "/__info";
            String fixInfo = "[ -s '" + info + "' ] || printf '%s\\n%s\\n1\\n__data\\n' -1 \"$(date +%s)\" > '" + info + "'";
            if (md5.equals(so[1])) {
                cmds.add(fixInfo + "; echo 'IMG_OK " + name + "'");
            } else if (md5.equals(so[0]) || ours.contains(md5)) {
                cmds.add("cp '" + new File(dir, name).getAbsolutePath() + "' '" + GAME_SHARED + rel
                        + "' && echo 'IMG_OK " + name + "'; " + fixInfo);
            }
            // anything else is a game build we don't know (an older copy the game no longer
            // loads, or a newer one): leave it as it is
        }
        for (int i = 0; i < cmds.size(); i += 25) {
            String out = shell(String.join("; ", cmds.subList(i, Math.min(cmds.size(), i + 25)))).out;
            for (String line : out.split("\n"))
                if (line.trim().startsWith("IMG_OK ")) done.add(line.trim().substring(7));
            progress(p0 + span / 2 + (span / 2) * Math.min(cmds.size(), i + 25) / Math.max(1, cmds.size()),
                    "Installing the images");
        }
        for (File f : dir.listFiles()) f.delete();   // the zip stays, for the next switch
        dir.delete();

        prefs().edit()
                .putString(PREF_IMAGES_LANG, lang.code)
                .putString(PREF_IMAGES_WRITTEN, String.join(",", ours))
                .putString(PREF_IMAGES_BUNDLES, String.join(",", wanted.keySet()))
                .apply();
        // counted per image set, not per cached copy: old game versions leave extra copies
        int notCached = wanted.size() - seen.size();
        int foreign = seen.size() - done.size();
        log("✓ Translated images: " + done.size() + " of " + wanted.size() + " image sets in " + lang.name
                + (foreign > 0 ? ", " + foreign + " left as they are (changed by a game update)" : "")
                + (notCached > 0 ? ", " + notCached + " not downloaded by the game yet" : "") + ".");
    }

    private static byte[] readAll(java.io.InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
        byte[] buf = new byte[1 << 16];
        int n;
        while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
        return bo.toByteArray();
    }

    /** Back to the Japanese images: blank the __info of every bundle we wrote,
     *  so the game downloads the stock one at next launch (we can't delete). */
    private int removeImages() throws Exception {
        Set<String> names = csvSet(prefs().getString(PREF_IMAGES_BUNDLES, ""));
        Set<String> ours = csvSet(prefs().getString(PREF_IMAGES_WRITTEN, ""));
        List<String> cmds = new ArrayList<>();
        for (Map.Entry<String, String> c : cachedImageMd5s(names).entrySet()) {
            if (!ours.contains(c.getValue())) continue;
            String rel = c.getKey();
            String info = GAME_SHARED + rel.substring(0, rel.lastIndexOf('/')) + "/__info";
            cmds.add(": > '" + info + "' && echo 'IMG_RESET'");
        }
        int n = 0;
        for (int i = 0; i < cmds.size(); i += 25) {
            for (String line : shell(String.join("; ", cmds.subList(i, Math.min(cmds.size(), i + 25)))).out.split("\n"))
                if (line.trim().equals("IMG_RESET")) n++;
        }
        prefs().edit().putString(PREF_IMAGES_LANG, "").apply();
        log(n > 0 ? "Removed the translated images from " + n + " bundle" + (n == 1 ? "" : "s")
                + ": the game downloads the Japanese ones at next launch."
                : "No translated images installed.");
        return n;
    }

    private void onRemoveImages() {
        if (!isConnected()) {
            log("Connect Shizuku first.");
            return;
        }
        if (!tryBegin("Removing images…")) return;
        new Thread(() -> {
            try {
                section("Remove translated images");
                shell("am force-stop " + GAME_PKG);
                removeImages();
            } catch (Throwable t) {
                log("✗ Couldn't remove the images: " + t.getMessage());
            } finally {
                ui.post(this::end);
            }
        }, "remove-images").start();
    }

    /** Status-card progress for Auto-patch; repeated values are dropped. */
    private void progress(int pct, String phase) {
        if (pct == progressPct && phase.equals(progressPhase)) return;
        progressPhase = phase;
        progressPct = pct;
        refreshStatus();
    }

    // ---------------- the Japanese original ----------------
    // The translations match Japanese text, so patching an already-patched pack
    // changes almost nothing. Like the PC installer's stock copy, keep the
    // Japanese pack before replacing it, and start from it when switching.

    private File originalJa() {
        return appFile("original_ja.__data");
    }

    private boolean isPublishedStock(String md5) {
        for (PatchLanguage l : languages)
            if (!l.stockMd5.isEmpty() && md5.equalsIgnoreCase(l.stockMd5)) return true;
        return false;
    }

    /** A pack this app installed or published: a patch, never the Japanese original. */
    private boolean isKnownPatch(String md5) {
        if (md5.equalsIgnoreCase(prefs().getString(PREF_AUTOPATCH_MD5, ""))) return true;
        for (PatchLanguage l : languages)
            if (!l.patchMd5.isEmpty() && md5.equalsIgnoreCase(l.patchMd5)) return true;
        for (String h : patchHistory.split(","))
            if (md5.equalsIgnoreCase(h.trim())) return true;
        return false;
    }

    /** Whether the saved original is intact and is the pack the live patch was
     *  built from (an original of an older game version must not be used). */
    private boolean originalMatches(String liveMd5) throws Exception {
        String orig = prefs().getString(PREF_ORIGINAL_MD5, "");
        if (orig.isEmpty() || !originalJa().exists() || !orig.equalsIgnoreCase(md5Of(originalJa())))
            return false;
        if (liveMd5.equalsIgnoreCase(prefs().getString(PREF_AUTOPATCH_MD5, "")))
            return orig.equalsIgnoreCase(prefs().getString(PREF_AUTOPATCH_BASE, ""));
        for (PatchLanguage l : languages)
            if (!l.patchMd5.isEmpty() && liveMd5.equalsIgnoreCase(l.patchMd5))
                return orig.equalsIgnoreCase(l.stockMd5);
        return false;
    }

    private void keepOriginal(File japanese, String md5) {
        try {
            if (md5.equalsIgnoreCase(prefs().getString(PREF_ORIGINAL_MD5, "")) && originalJa().exists()) return;
            java.nio.file.Files.copy(japanese.toPath(), originalJa().toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            prefs().edit().putString(PREF_ORIGINAL_MD5, md5.toLowerCase(Locale.US)).apply();
        } catch (Throwable t) {
            log("⚠ Couldn't keep a copy of the Japanese pack (" + t.getMessage() + ").");
        }
    }

    /** Apply is about to replace the live pack: keep it if it's the published stock. */
    private void saveOriginalIfStock() {
        try {
            String md5 = readLiveMd5();
            String live = newestLiveBundle();
            if (md5 == null || live == null || !isPublishedStock(md5)) return;
            if (md5.equalsIgnoreCase(prefs().getString(PREF_ORIGINAL_MD5, "")) && originalJa().exists()) return;
            ShellResult r = shell("cp '" + live + "' '" + originalJa().getAbsolutePath() + "' && echo OK");
            if (r.out.contains("OK") && md5.equalsIgnoreCase(md5Of(originalJa())))
                prefs().edit().putString(PREF_ORIGINAL_MD5, md5).apply();
        } catch (Throwable ignored) {
            // best effort: Auto-patch falls back to a re-download
        }
    }

    /** Make the game download its Japanese language pack again. The shell uid
     *  can overwrite the game's cache files but not delete them (the folders
     *  have no group write), so blank each entry's __info instead: Unity then
     *  treats the entry as not cached and downloads it on next launch.
     *  Returns how many entries were reset. */
    private int invalidateLangPacks() throws android.os.RemoteException {
        ShellResult r = shell("for f in " + GAME_CACHE_GLOB + "; do [ -f \"$f\" ] || continue; "
                + "i=\"${f%/__data}/__info\"; : > \"$i\" 2>/dev/null; "
                + "[ -f \"$i\" ] && [ ! -s \"$i\" ] && echo \"RESET:$f\"; done");
        int n = 0;
        for (String line : r.out.split("\n"))
            if (line.trim().startsWith("RESET:")) n++;
        return n;
    }

    /** The game holds a patch and no matching Japanese original is saved: open
     *  the game briefly so it downloads the Japanese pack, then close it.
     *  True once Unity has written a fresh entry (its __info is back). */
    private boolean fetchJapanese() throws Exception {
        log("The game has a patched language pack, and Auto-patch translates from the Japanese one. "
                + "Opening the game briefly so it downloads it again…");
        progress(10, "Getting the Japanese pack from the game");
        if (invalidateLangPacks() == 0) return false;
        shell("monkey -p " + GAME_PKG + " -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1");
        String ready = "";
        long deadline = System.currentTimeMillis() + 120_000;
        while (ready.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(2000);
            ready = shell("for f in " + GAME_CACHE_GLOB + "; do [ -s \"${f%/__data}/__info\" ] "
                    + "&& echo \"READY:$f\"; done").out;
        }
        if (ready.contains("READY:")) Thread.sleep(2000);   // let Unity finish closing the file
        shell("am force-stop " + GAME_PKG);
        try {
            startActivity(new Intent(this, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        } catch (Throwable ignored) {
            // closing the game usually brings us back anyway
        }
        return ready.contains("READY:");
    }

    /** Opening the game didn't bring a fresh pack (no network, a dialog in the way). */
    private void askToOpenGame() {
        log("The game didn't download its Japanese pack in time.");
        log("→ Open the game until the title screen, close it, then tap Auto-patch again.");
        doneLabel = null;
        ui.post(this::showRedownloadDialog);
    }

    private void showRedownloadDialog() {
        if (isFinishing()) return;
        showSheet("One more step", "Auto-patch needs the game's Japanese language pack, and the game "
                        + "didn't download it while it was open.\n\nOpen the game until the title "
                        + "screen, close it, then come back and tap Auto-patch again. The app keeps "
                        + "that Japanese pack, so switching languages later won't need this.",
                null, "Launch game", this::launchGame, "Close");
    }

    /** @param retried true on the second pass, after the game re-downloaded Japanese. */
    /** Names of the language pack's tables (bundled asset). */
    private List<String> tableNames() throws java.io.IOException {
        List<String> names = new ArrayList<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.InputStreamReader(
                getAssets().open("tables.txt")))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                ln = ln.trim();
                if (!ln.isEmpty()) names.add(ln);
            }
        }
        return names;
    }

    private boolean builtInKeyOffsets;

    private String keyMismatch() {
        return "the AES keys don't match this game build"
                + (builtInKeyOffsets ? " (built-in key offsets were used)." : ".");
    }

    /** The game's AES keys, read from its global-metadata.dat (copied into dir).
     *  Offsets come from the live version.json; the baked fallback goes stale
     *  with every game update. */
    private byte[][] gameKeys(File dir) throws Exception {
        String q = dir.getAbsolutePath();
        File metaF = new File(dir, "global-metadata.dat");
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

        Map<String, Object> v = loadReleaseInfo();
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
        builtInKeyOffsets = !liveOffsets;
        byte[] meta = java.nio.file.Files.readAllBytes(metaF.toPath());
        byte[][] keys;
        try {
            keys = MasterCrypto.extractKeys(meta, keyOff, ivOff);
        } catch (IllegalArgumentException e) {
            throw new AutoPatchFail(keyMismatch());
        }

        return keys;
    }

    private void doAutoPatch(boolean retried) throws Exception {
        if (!retried) section("Auto-patch");
        else log("The game downloaded its Japanese pack. Patching from it…");
        progress(0, "Reading the game files");
        shell("am force-stop " + GAME_PKG);

        // 1. live bundle path(s)
        List<String> dests = findLiveBundles();
        if (dests.isEmpty())
            throw new AutoPatchFail("no language pack on the device. Open the game once so it downloads its data.");

        // source = NEWEST bundle (an old asset-hash folder may linger post-update)
        String newest = newestLiveBundle();
        String srcBundle = newest != null ? newest : dests.get(0);

        // 2. stage the bundle into our own dir (the shell uid can write it there)
        File dir = getExternalFilesDir(null);
        if (dir == null) throw new AutoPatchFail("app storage is unavailable.");
        String q = dir.getAbsolutePath();
        File stockF = new File(dir, "stock_new.__data");
        ShellResult r1 = shell("cp '" + srcBundle + "' '" + q
                + "/stock_new.__data' && echo OK1");
        if (!r1.out.contains("OK1"))
            throw new AutoPatchFail("could not read the game's language pack" + r1.reason() + ".");
        progress(5, "Reading the game's keys");
        byte[][] keys = gameKeys(dir);
        PatchLanguage lang = selectedLanguage();
        log("Language: " + lang.name + ".");

        // 4. translation cache (refreshed whenever the release is newer)
        progress(7, "Loading the translations");
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
        List<String> names = tableNames();

        // 6. start from the Japanese original: a pack this app installed is a
        // patch, so use the saved original it was built from, if any.
        String liveMd5 = md5Of(stockF).toLowerCase(Locale.US);
        File srcF = stockF;
        if (isKnownPatch(liveMd5)) {
            if (!originalMatches(liveMd5)) {
                if (!retried && fetchJapanese()) doAutoPatch(true);
                else askToOpenGame();
                return;
            }
            log("The game has a patch installed: starting from the saved Japanese pack.");
            srcF = originalJa();
        }

        // 7. patch fully on-device. Per-table notes stay out of the UI log;
        // only the summary below is shown.
        byte[] stock = java.nio.file.Files.readAllBytes(srcF.toPath());
        List<String> notes = new ArrayList<>();
        AutoPatcher.Result res;
        try {
            res = AutoPatcher.run(stock, keys[0], keys[1], cache, hand, names, notes::add,
                    (pct, phase) -> progress(10 + pct * 80 / 100, phase));
        } catch (IllegalStateException e) {
            if (String.valueOf(e.getMessage()).contains("AES keys")) throw new AutoPatchFail(keyMismatch());
            throw e;
        }
        // Someone else's patch, or a saved copy that isn't Japanese after all.
        if (!res.sourceIsJapanese()) {
            if (srcF != stockF) prefs().edit().remove(PREF_ORIGINAL_MD5).apply();
            if (!retried && fetchJapanese()) doAutoPatch(true);
            else askToOpenGame();
            return;
        }
        if (srcF == stockF) keepOriginal(stockF, liveMd5);
        progress(92, "Installing");
        File outF = new File(dir, "patched.__data");
        java.nio.file.Files.write(outF.toPath(), res.data);
        prefs().edit()
                .putString(PREF_AUTOPATCH_MD5, MasterCrypto.md5Hex(res.data).toLowerCase(Locale.US))
                .putString(PREF_AUTOPATCH_BASE, MasterCrypto.md5Hex(stock).toLowerCase(Locale.US))
                .apply();

        StringBuilder sum = new StringBuilder("Patched " + res.patched + "/" + res.tablesFound + " tables");
        int missing = names.size() - res.tablesFound;
        if (missing > 0) sum.append(", ").append(missing).append(" not found");
        if (res.fitAfterRevert > 0) sum.append(", ").append(res.fitAfterRevert).append(" trimmed to fit");
        if (res.jaOnly > 0) sum.append(", ").append(res.jaOnly).append(" kept Japanese");
        sum.append(".\n").append(String.format(Locale.US, "%,d", res.leftJaCells))
                .append(" cells left Japanese (new content).");
        log(sum.toString());

        // 8. write back over every live copy
        for (String dest : dests) {
            ShellResult rr = shell("cp '" + outF.getAbsolutePath() + "' '" + dest
                    + "' && echo CP_OK; chmod 0666 '" + dest + "' 2>/dev/null");
            if (!rr.out.contains("CP_OK"))
                throw new AutoPatchFail("could not write " + shortPath(dest) + rr.reason() + ".");
        }
        syncImages(lang, 93, 99);
        progress(100, "Installed");
        log("✓ Auto-patch installed to " + dests.size()
                + (dests.size() == 1 ? " cache location" : " cache locations") + ". Launch the game.");
        doneLabel = lang.isDefault() ? "Auto-patch installed" : lang.name + " auto-patch installed";
        String title = doneLabel;
        ui.post(() -> showInstalledDialog(title));
    }
}
