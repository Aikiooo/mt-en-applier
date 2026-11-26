package com.mtpatch.enapply;

import com.mtpatch.enapply.core.AutoPatcher;
import com.mtpatch.enapply.core.JsonMap;

import org.junit.Test;

import java.util.List;
import java.util.Map;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class EditionAndLanguageTest {

    private static final String SAMPLE_VERSION = "{\n"
            + "  \"patch_size\": 1913628,\n"
            + "  \"patch_md5\": \"8b2077d00c25cc69a0637f620a850ce0\",\n"
            + "  \"stock_md5\": \"ed02cff72ee185b5639a1ce0b4529409\",\n"
            + "  \"cache_md5\": \"ae90e974ee8d7545c9775a0cd2995ba9\",\n"
            + "  \"built_at\": \"2026-11-19T09:13:02\",\n"
            + "  \"meta_key_off\": \"0xbc51f8\",\n"
            + "  \"meta_iv_off\": \"0xbc7c78\",\n"
            + "  \"prefabs\": \"android-prefabs-en.zip\",\n"
            + "  \"prefabs_md5\": \"72d3ae9b1cf09a75e06e5323490f7e4d\",\n"
            + "  \"prefabs_size\": 36087858,\n"
            + "  \"images\": \"android-images-en.zip\",\n"
            + "  \"images_md5\": \"47894c843180e3c77e81e795f14be3d7\",\n"
            + "  \"images_size\": 18016798,\n"
            + "  \"locales\": {\n"
            + "    \"fr\": {\n"
            + "      \"name\": \"Français\",\n"
            + "      \"cache\": \"translation_cache.fr.json\",\n"
            + "      \"cache_md5\": \"242909104a9b55cacbaf5758a4b118ca\",\n"
            + "      \"built_at\": \"2026-11-19T09:52:14\"\n"
            + "    }\n"
            + "  },\n"
            + "  \"tw\": {\n"
            + "    \"game_version\": \"1.1.3 / 2026-11-24\",\n"
            + "    \"stock_md5\": \"541b16bbcb1bfe3fcf973eb57670ba01\",\n"
            + "    \"stock_size\": 1544064,\n"
            + "    \"lang_guid\": \"513353b6ad174a743e3dbc22a70182c7\",\n"
            + "    \"meta_key_off\": \"0xc8c5e8\",\n"
            + "    \"meta_iv_off\": \"0xc914c0\",\n"
            + "    \"patch\": \"__data.tw\",\n"
            + "    \"patch_size\": 1544064,\n"
            + "    \"patch_md5\": \"69a088528530fb049299ae1c2f49ac18\",\n"
            + "    \"cache\": \"translation_cache.tw.en.json\",\n"
            + "    \"cache_md5\": \"3bb54380bbe1c770696d6b097dde60d5\",\n"
            + "    \"built_at\": \"2026-11-25T18:54:00\",\n"
            + "    \"prefabs\": \"android-prefabs-tw-en.zip\",\n"
            + "    \"prefabs_md5\": \"517fc268256c8001979b09ed2883a328\",\n"
            + "    \"prefabs_size\": 35459970,\n"
            + "    \"images\": \"android-images-tw-en.zip\",\n"
            + "    \"images_md5\": \"601e61c3cf9041c438d34414f57a4429\",\n"
            + "    \"images_size\": 13680067,\n"
            + "    \"locales\": {\n"
            + "      \"fr\": {\n"
            + "        \"name\": \"Français\",\n"
            + "        \"label\": \"French\",\n"
            + "        \"patch\": \"__data.tw.fr\",\n"
            + "        \"patch_size\": 1697979,\n"
            + "        \"patch_md5\": \"ea3141412701e1db85314f199fc1ccff\",\n"
            + "        \"stock_md5\": \"541b16bbcb1bfe3fcf973eb57670ba01\",\n"
            + "        \"cache\": \"translation_cache.tw.fr.json\",\n"
            + "        \"cache_md5\": \"a9052d880f3eca3c49ca7cc5665639e7\",\n"
            + "        \"built_at\": \"2026-11-25T18:54:00\",\n"
            + "        \"prefabs\": \"android-prefabs-tw-fr.zip\",\n"
            + "        \"prefabs_md5\": \"6415ff8d3a0c2649d98d03d47e0987a2\",\n"
            + "        \"prefabs_size\": 35486754,\n"
            + "        \"images\": \"android-images-tw-fr.zip\",\n"
            + "        \"images_md5\": \"46ed8c4468b25b390eccfd2cefec6ff3\",\n"
            + "        \"images_size\": 13664423\n"
            + "      }\n"
            + "    }\n"
            + "  }\n"
            + "}";

    @Test
    public void jpParsingUnchangedByTwBlock() {
        Map<String, Object> v = JsonMap.parseObject(SAMPLE_VERSION);
        List<PatchLanguage> jp = PatchLanguage.fromVersion(v);
        assertEquals(2, jp.size());
        PatchLanguage en = jp.get(0);
        assertEquals("en", en.code);
        assertEquals("__data", en.patchAsset);
        assertEquals("translation_cache.json", en.cacheAsset);
        assertEquals(1913628L, en.patchSize);
        assertEquals("android-prefabs-en.zip", en.prefabsAsset);
        assertEquals("android-images-en.zip", en.imagesAsset);
        PatchLanguage fr = jp.get(1);
        assertEquals("fr", fr.code);
        assertNull(fr.patchAsset);
        assertFalse(fr.downloadable());
    }

    @Test
    public void twParsingReadsNestedBlock() {
        Map<String, Object> v = JsonMap.parseObject(SAMPLE_VERSION);
        List<PatchLanguage> tw = PatchLanguage.fromVersionForEdition(v, GameEdition.TW);
        assertEquals(2, tw.size());

        PatchLanguage en = tw.get(0);
        assertEquals("en", en.code);
        assertEquals("__data.tw", en.patchAsset);
        assertEquals(1544064L, en.patchSize);
        assertEquals("69a088528530fb049299ae1c2f49ac18", en.patchMd5);
        assertEquals("translation_cache.tw.en.json", en.cacheAsset);
        assertEquals("541b16bbcb1bfe3fcf973eb57670ba01", en.stockMd5);
        assertTrue(en.downloadable());
        assertTrue(en.hasPrefabs());
        assertTrue(en.hasImages());
        assertEquals("android-prefabs-tw-en.zip", en.prefabsAsset);
        assertEquals("android-images-tw-en.zip", en.imagesAsset);

        PatchLanguage fr = tw.get(1);
        assertEquals("fr", fr.code);
        assertEquals("Français", fr.name);
        assertEquals("__data.tw.fr", fr.patchAsset);
        assertEquals(1697979L, fr.patchSize);
        assertEquals("ea3141412701e1db85314f199fc1ccff", fr.patchMd5);
        assertEquals("translation_cache.tw.fr.json", fr.cacheAsset);
        assertTrue(fr.downloadable());
        assertTrue(fr.hasPrefabs());
        assertTrue(fr.hasImages());
        assertEquals("android-prefabs-tw-fr.zip", fr.prefabsAsset);
        assertEquals("android-images-tw-fr.zip", fr.imagesAsset);
    }

    @Test
    public void gameEditionScopingAndGuidOverride() {
        assertEquals("lang", GameEdition.JP.prefKey("lang"));
        assertEquals("tw_lang", GameEdition.TW.prefKey("lang"));
        assertEquals("__data", GameEdition.JP.fileName("__data"));
        assertEquals("tw___data", GameEdition.TW.fileName("__data"));
        assertEquals("original_ja.__data", GameEdition.JP.originalFileName);
        assertEquals("original_tw.__data", GameEdition.TW.originalFileName);

        Map<String, Object> v = JsonMap.parseObject(SAMPLE_VERSION);
        assertEquals("513353b6ad174a743e3dbc22a70182c7", GameEdition.TW.langGuidFrom(v));
        assertNotNull(GameEdition.TW.versionBlock(v));
        assertTrue(GameEdition.TW.cacheGlob(GameEdition.TW.langGuidFrom(v))
                .contains("/sdcard/Android/data/com.cayenne.mtr/files/UnityCache/Shared/513353b6ad174a743e3dbc22a70182c7/*/__data"));
        // Malformed guid falls back to default
        assertEquals(GameEdition.TW.defaultLangGuid, GameEdition.TW.safeGuid("../bad"));
    }

    @Test
    public void autoPatcherResultSourceAlias() {
        AutoPatcher.Result r = new AutoPatcher.Result();
        r.textCellsIn = 100;
        r.jaCellsIn = 99;
        assertTrue(r.sourceIsStockCjk());
        assertTrue(r.sourceIsJapanese());
        r.jaCellsIn = 5;
        assertFalse(r.sourceIsStockCjk());
        assertFalse(r.sourceIsJapanese());
    }

    @Test
    public void rootResultParsing() {
        assertTrue(RootShell.isRootResult("exit=0\nuid=0(root) gid=0(root)\n"));
        assertFalse(RootShell.isRootResult("exit=1\nuid=0(root)\n"));
        assertFalse(RootShell.isRootResult("exit=0\nuid=2000(shell)\n"));
        assertFalse(RootShell.isRootResult("exec_error=java.io.IOException: Cannot run program \"su\""));
        assertFalse(RootShell.isRootResult(null));

        assertEquals(RootShell.Status.GRANTED,
                RootShell.classifyProbe(true, "exit=0\nuid=0(root)\n", null));
        assertEquals(RootShell.Status.DENIED,
                RootShell.classifyProbe(true, "exit=13\n[stderr]\nPermission denied\n", null));
        assertEquals(RootShell.Status.DENIED,
                RootShell.classifyProbe(false, "exit=1\n", null));
        assertEquals(RootShell.Status.UNAVAILABLE,
                RootShell.classifyProbe(false, "exec_error=java.io.IOException: No such file", null));
    }
}
