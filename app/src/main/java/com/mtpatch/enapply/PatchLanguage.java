package com.mtpatch.enapply;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * One patch language published on the release, as listed by version.json.
 *
 * English is the historic top-level block (patch_size / patch_md5 / built_at /
 * stock_md5, assets "__data" + "translation_cache.json"), so old app versions
 * keep working unchanged. Every other language is an entry of the optional
 * nested "locales" object (written by tools/translations/Publish-Locale.ps1):
 *
 * <pre>
 * "locales": {
 *   "es": {
 *     "name": "Español",
 *     "cache": "translation_cache.es.json", "cache_md5": "…", "built_at": "…",
 *     "patch": "__data.es", "patch_size": 1898964, "patch_md5": "…",   (optional)
 *     "stock_md5": "…"                                                 (optional)
 *   }
 * }
 * </pre>
 *
 * Only languages present in version.json are offered, so an unpublished
 * locale never surfaces in the app.
 */
final class PatchLanguage {

    static final String DEFAULT_CODE = "en";

    private static final Pattern SAFE_CODE = Pattern.compile("[A-Za-z0-9_-]{1,16}");
    private static final Pattern SAFE_ASSET = Pattern.compile("[A-Za-z0-9_][A-Za-z0-9._-]{0,63}");

    final String code;
    final String name;
    /** Release asset of the ready-made __data, or null (Auto-patch only). */
    final String patchAsset;
    final long patchSize;
    final String patchMd5;
    /** Release asset of the translation cache (used by Auto-patch). */
    final String cacheAsset;
    final String cacheMd5;
    final String builtAt;
    /** md5 of the stock bundle the ready-made __data was built from ("" = unknown). */
    final String stockMd5;
    /** False when the ready-made __data was built for an older game build. */
    final boolean patchCurrent;

    private PatchLanguage(String code, String name, String patchAsset, long patchSize,
                          String patchMd5, String cacheAsset, String cacheMd5,
                          String builtAt, String stockMd5, boolean patchCurrent) {
        this.code = code;
        this.name = name;
        this.patchAsset = patchAsset;
        this.patchSize = patchSize;
        this.patchMd5 = patchMd5;
        this.cacheAsset = cacheAsset;
        this.cacheMd5 = cacheMd5;
        this.builtAt = builtAt;
        this.stockMd5 = stockMd5;
        this.patchCurrent = patchCurrent;
    }

    boolean isDefault() {
        return DEFAULT_CODE.equals(code);
    }

    /** A verified, current ready-made __data can be downloaded for this language.
     *  English always can: Download re-reads version.json before fetching. */
    boolean downloadable() {
        if (isDefault()) return true;
        return patchAsset != null && !patchMd5.isEmpty() && patchCurrent;
    }

    /** Identity of the published translation cache; changes on every republish. */
    String cacheStamp() {
        String id = cacheMd5.isEmpty() ? patchMd5 : cacheMd5;
        if (builtAt.isEmpty() && id.isEmpty()) return null;
        return builtAt + "|" + id;
    }

    /** English from the top-level keys; works with any version.json ever shipped. */
    static PatchLanguage english(Map<String, Object> v) {
        return new PatchLanguage(DEFAULT_CODE, "English", "__data",
                parseLong(str(v, "patch_size")), str(v, "patch_md5"),
                "translation_cache.json", str(v, "cache_md5"),
                str(v, "built_at"), str(v, "stock_md5"), true);
    }

    /** English first, then every published locale in version.json order. */
    static List<PatchLanguage> fromVersion(Map<String, Object> v) {
        List<PatchLanguage> out = new ArrayList<>();
        if (v == null) return out;
        out.add(english(v));
        Object locs = v.get("locales");
        if (!(locs instanceof Map)) return out;
        String gameStock = str(v, "stock_md5");
        for (Map.Entry<?, ?> e : ((Map<?, ?>) locs).entrySet()) {
            String code = String.valueOf(e.getKey());
            if (DEFAULT_CODE.equals(code) || !SAFE_CODE.matcher(code).matches()
                    || !(e.getValue() instanceof Map)) continue;
            @SuppressWarnings("unchecked")
            Map<String, Object> m = (Map<String, Object>) e.getValue();
            // Codes and asset names become local file names and URL paths.
            String cache = str(m, "cache");
            if (!SAFE_ASSET.matcher(cache).matches()) continue;    // nothing usable published
            String patch = str(m, "patch");
            if (!SAFE_ASSET.matcher(patch).matches()) patch = "";
            String stock = str(m, "stock_md5");
            boolean current = gameStock.isEmpty() || stock.isEmpty()
                    || gameStock.equalsIgnoreCase(stock);
            String name = str(m, "name");
            out.add(new PatchLanguage(code, name.isEmpty() ? code : name,
                    patch.isEmpty() ? null : patch, parseLong(str(m, "patch_size")),
                    str(m, "patch_md5"), cache, str(m, "cache_md5"),
                    str(m, "built_at"), stock, current));
        }
        return out;
    }

    static PatchLanguage find(List<PatchLanguage> langs, String code) {
        for (PatchLanguage l : langs) if (l.code.equals(code)) return l;
        return null;
    }

    private static String str(Map<String, Object> m, String k) {
        Object o = m.get(k);
        return o == null || o instanceof Map ? "" : String.valueOf(o).trim();
    }

    private static long parseLong(String s) {
        try {
            return Long.parseLong(s);
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
