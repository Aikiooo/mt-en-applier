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
 *     "stock_md5": "…",                                                (optional)
 *     "images": "android-images-es.zip", "images_md5": "…",            (optional)
 *     "images_size": 17332846,
 *     "prefabs": "android-prefabs-es.zip", "prefabs_md5": "…",          (optional)
 *     "prefabs_size": 41000000
 *   }
 * }
 * </pre>
 *
 * English's images and prefabs use the same keys at the top level.
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
    /** Release asset of the translated Android images (zip), or null. */
    final String imagesAsset;
    final String imagesMd5;
    final long imagesSize;
    /** Release asset of the translated UI prefab text (zip), or null. */
    final String prefabsAsset;
    final String prefabsMd5;
    final long prefabsSize;

    private PatchLanguage(String code, String name, String patchAsset, long patchSize,
                          String patchMd5, String cacheAsset, String cacheMd5,
                          String builtAt, String stockMd5, boolean patchCurrent,
                          String imagesAsset, String imagesMd5, long imagesSize,
                          String prefabsAsset, String prefabsMd5, long prefabsSize) {
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
        this.imagesAsset = imagesAsset;
        this.imagesMd5 = imagesMd5;
        this.imagesSize = imagesSize;
        this.prefabsAsset = prefabsAsset;
        this.prefabsMd5 = prefabsMd5;
        this.prefabsSize = prefabsSize;
    }

    /** Translated images are published for this language. */
    boolean hasImages() {
        return imagesAsset != null && !imagesMd5.isEmpty();
    }

    /** Translated menu text (UI prefabs) is published for this language. */
    boolean hasPrefabs() {
        return prefabsAsset != null && !prefabsMd5.isEmpty();
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
        return english(v, GameEdition.JP);
    }

    /** English entry for a specific game edition (top-level for JP, "tw" block for TW). */
    static PatchLanguage english(Map<String, Object> block, GameEdition ed) {
        Map<String, Object> m = block != null ? block : new java.util.HashMap<>();
        String patch = safeAsset(str(m, "patch"));
        if (patch == null) patch = ed.defaultPatchAsset;
        String cache = safeAsset(str(m, "cache"));
        if (cache == null) cache = ed.defaultCacheAsset;
        return new PatchLanguage(DEFAULT_CODE, "English", patch,
                parseLong(str(m, "patch_size")), str(m, "patch_md5"),
                cache, str(m, "cache_md5"),
                str(m, "built_at"), str(m, "stock_md5"), true,
                safeAsset(str(m, "images")), str(m, "images_md5"), parseLong(str(m, "images_size")),
                safeAsset(str(m, "prefabs")), str(m, "prefabs_md5"), parseLong(str(m, "prefabs_size")));
    }

    /** English first, then every published locale in version.json order (JP top-level). */
    static List<PatchLanguage> fromVersion(Map<String, Object> v) {
        return fromVersionForEdition(v, GameEdition.JP);
    }

    /** English first, then every published locale for the given game edition. */
    static List<PatchLanguage> fromVersionForEdition(Map<String, Object> v, GameEdition ed) {
        List<PatchLanguage> out = new ArrayList<>();
        if (v == null) return out;
        Map<String, Object> block = ed.versionBlock(v);
        if (block == null) return out;
        out.add(english(block, ed));
        Object locs = block.get("locales");
        if (!(locs instanceof Map)) return out;
        String gameStock = str(block, "stock_md5");
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
                    str(m, "built_at"), stock, current,
                    safeAsset(str(m, "images")), str(m, "images_md5"), parseLong(str(m, "images_size")),
                    safeAsset(str(m, "prefabs")), str(m, "prefabs_md5"), parseLong(str(m, "prefabs_size"))));
        }
        return out;
    }

    static PatchLanguage find(List<PatchLanguage> langs, String code) {
        for (PatchLanguage l : langs) if (l.code.equals(code)) return l;
        return null;
    }

    private static String safeAsset(String a) {
        return SAFE_ASSET.matcher(a).matches() ? a : null;
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
