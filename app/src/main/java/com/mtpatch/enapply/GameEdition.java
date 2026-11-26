package com.mtpatch.enapply;

import android.content.pm.PackageManager;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * Supported regional editions of the game client.
 *
 * Japan (JP) keeps unprefixed SharedPreferences keys and local filenames so
 * existing installs upgrade seamlessly. Taiwan (TW) namespaces its own keys,
 * backups, staged files and version.json sub-object ("tw"), letting both
 * clients live side-by-side on the same device without colliding.
 */
enum GameEdition {

    JP("jp", "Japan", "jp.gree_ent.mushoku",
            "cad73e991807559422ab03e01424a9d3",
            "b7499781b4d69361fc70fcf2ee08c1ce/__data",
            1913628L, 0xBC51F8, 0xBC7C78,
            "", "", "original_ja.__data",
            "Japanese", "__data", "translation_cache.json"),

    TW("tw", "Taiwan", "com.cayenne.mtr",
            "513353b6ad174a743e3dbc22a70182c7",
            "8cc6ee793b6a9727ee9051261b34100f/__data",
            1544064L, 0xC8C5E8, 0xC914C0,
            "tw_", "tw_", "original_tw.__data",
            "Chinese", "__data.tw", "translation_cache.tw.en.json");

    private static final Pattern SAFE_GUID = Pattern.compile("[0-9a-fA-F]{32}");

    final String code;
    final String name;
    final String pkg;
    final String defaultLangGuid;
    final String fallbackCacheSubpath;
    final long defaultExpectedSize;
    final int fallbackKeyOff;
    final int fallbackIvOff;
    final String prefPrefix;
    final String filePrefix;
    final String originalFileName;
    final String sourceLangName;
    final String defaultPatchAsset;
    final String defaultCacheAsset;

    GameEdition(String code, String name, String pkg, String defaultLangGuid,
                String fallbackCacheSubpath, long defaultExpectedSize,
                int fallbackKeyOff, int fallbackIvOff,
                String prefPrefix, String filePrefix, String originalFileName,
                String sourceLangName, String defaultPatchAsset, String defaultCacheAsset) {
        this.code = code;
        this.name = name;
        this.pkg = pkg;
        this.defaultLangGuid = defaultLangGuid;
        this.fallbackCacheSubpath = fallbackCacheSubpath;
        this.defaultExpectedSize = defaultExpectedSize;
        this.fallbackKeyOff = fallbackKeyOff;
        this.fallbackIvOff = fallbackIvOff;
        this.prefPrefix = prefPrefix;
        this.filePrefix = filePrefix;
        this.originalFileName = originalFileName;
        this.sourceLangName = sourceLangName;
        this.defaultPatchAsset = defaultPatchAsset;
        this.defaultCacheAsset = defaultCacheAsset;
    }

    static GameEdition fromCode(String code) {
        if (code != null) {
            for (GameEdition e : values()) {
                if (e.code.equalsIgnoreCase(code)) return e;
            }
        }
        return JP;
    }

    String sharedDir() {
        return "/sdcard/Android/data/" + pkg + "/files/UnityCache/Shared/";
    }

    String metaPath() {
        return "/sdcard/Android/data/" + pkg + "/files/il2cpp/Metadata/global-metadata.dat";
    }

    String safeGuid(String maybeGuid) {
        return maybeGuid != null && SAFE_GUID.matcher(maybeGuid).matches()
                ? maybeGuid.toLowerCase(java.util.Locale.US) : defaultLangGuid;
    }

    /** Candidate locations of the live language bundle for this edition.
     *  NEVER broaden this glob: UnityCache holds thousands of sibling asset bundles. */
    String cacheGlob(String langGuid) {
        String g = safeGuid(langGuid);
        return sharedDir() + g + "/*/__data"
                + " /sdcard/Android/data/" + pkg + "/files/il2cpp/*/UnityCache/Shared/"
                + g + "/*/__data";
    }

    String fallbackCachePath(String langGuid) {
        return sharedDir() + safeGuid(langGuid) + "/" + fallbackCacheSubpath;
    }

    String prefKey(String base) {
        return prefPrefix + base;
    }

    String fileName(String base) {
        return filePrefix + base;
    }

    boolean isInstalled(PackageManager pm) {
        try {
            pm.getPackageInfo(pkg, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    /** Edition-specific section of version.json (top-level for JP, nested "tw" for TW). */
    @SuppressWarnings("unchecked")
    Map<String, Object> versionBlock(Map<String, Object> root) {
        if (root == null) return null;
        if (this == JP) return root;
        Object sub = root.get(code);
        return sub instanceof Map ? (Map<String, Object>) sub : null;
    }

    /** Effective language group GUID from version.json (allows OTA updates without APK bump). */
    String langGuidFrom(Map<String, Object> root) {
        Map<String, Object> block = versionBlock(root);
        if (block == null) return defaultLangGuid;
        Object g = block.get("lang_guid");
        return g == null || g instanceof Map ? defaultLangGuid : safeGuid(String.valueOf(g).trim());
    }
}
