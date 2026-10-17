package com.mtpatch.enapply.core;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Desktop test harness for the on-device auto-patcher (NOT used by the app UI).
 * Runs the exact code the phone runs, against local files:
 *
 *   java com.mtpatch.enapply.core.AutoPatchMain <stock __data> <keys.json>
 *                                               <translation_cache.json>
 *                                               <tables.txt> <out __data>
 */
public final class AutoPatchMain {

    public static void main(String[] args) throws Exception {
        if (args.length == 5 && args[0].equals("--same-rows")) {
            // --same-rows <pack A> <pack B> <keys.json> <tables.txt>
            Map<String, String> keys = JsonMap.parseFlat(Files.readString(Path.of(args[3])));
            List<String> names = Files.readAllLines(Paths.get(args[4]));
            long t0 = System.currentTimeMillis();
            Map<String, List<String>> a = AutoPatcher.rowIds(Files.readAllBytes(Paths.get(args[1])),
                    hex(keys.get("key_hex")), hex(keys.get("iv_hex")), names, (p, s) -> {});
            long t1 = System.currentTimeMillis();
            Map<String, List<String>> b = AutoPatcher.rowIds(Files.readAllBytes(Paths.get(args[2])),
                    hex(keys.get("key_hex")), hex(keys.get("iv_hex")), names, (p, s) -> {});
            long t2 = System.currentTimeMillis();
            int diff = 0;
            for (String t : a.keySet()) {
                if (!a.get(t).equals(b.get(t))) {
                    diff++;
                    List<String> only = new java.util.ArrayList<>(a.get(t));
                    if (b.get(t) != null) only.removeAll(b.get(t));
                    System.out.println(t + ": " + a.get(t).size() + " vs "
                            + (b.get(t) == null ? "missing" : b.get(t).size()) + " rows, new in A: "
                            + only.subList(0, Math.min(5, only.size())));
                }
            }
            System.out.println(a.size() + "/" + b.size() + " tables, " + diff + " differ; "
                    + (t1 - t0) + " ms + " + (t2 - t1) + " ms");
            return;
        }
        if (args.length != 5) {
            System.err.println("usage: AutoPatchMain <stock> <keys.json> <cache.json> <tables.txt> <out>");
            System.exit(2);
        }
        byte[] stock = Files.readAllBytes(Paths.get(args[0]));
        Map<String, String> keys = JsonMap.parseFlat(
                Files.readString(Path.of(args[1])));
        byte[] key = hex(keys.get("key_hex"));
        byte[] iv = hex(keys.get("iv_hex"));

        Map<String, Object> payload = JsonMap.parseObject(
                Files.readString(Path.of(args[2])));
        @SuppressWarnings("unchecked")
        Map<String, Object> cacheRaw = (Map<String, Object>) payload.get("cache");
        Map<String, String> cache = new LinkedHashMap<>(cacheRaw.size());
        for (Map.Entry<String, Object> e : cacheRaw.entrySet())
            cache.put(e.getKey(), String.valueOf(e.getValue()));
        Map<String, Map<String, String>> hand = new LinkedHashMap<>();
        Object handObj = payload.get("hand");
        if (handObj instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> hm = (Map<String, Object>) handObj;
            for (Map.Entry<String, Object> e : hm.entrySet()) {
                @SuppressWarnings("unchecked")
                Map<String, Object> inner = (Map<String, Object>) e.getValue();
                Map<String, String> dst = new LinkedHashMap<>();
                for (Map.Entry<String, Object> e2 : inner.entrySet())
                    dst.put(e2.getKey(), String.valueOf(e2.getValue()));
                hand.put(e.getKey(), dst);
            }
        }
        List<String> names = Files.readAllLines(Paths.get(args[3]));

        long t0 = System.currentTimeMillis();
        AutoPatcher.Result r = AutoPatcher.run(stock, key, iv, cache, hand, names,
                System.out::println);
        long ms = System.currentTimeMillis() - t0;

        Files.write(Paths.get(args[4]), r.data);
        System.out.println("== SUMMARY ==");
        System.out.println("tables found : " + r.tablesFound + "/" + names.size());
        System.out.println("patched      : " + r.patched
                + " (fit_after_revert=" + r.fitAfterRevert + ", ja_only=" + r.jaOnly
                + ", skipped=" + r.skipped + ")");
        System.out.println("cells left JA: " + r.leftJaCells);
        System.out.println("source JA    : " + r.jaCellsIn + "/" + r.textCellsIn + " text cells"
                + (r.sourceIsJapanese() ? " (Japanese original)" : " (NOT Japanese: already patched?)"));
        System.out.println("out          : " + args[4] + " (" + r.data.length + " bytes, md5 "
                + MasterCrypto.md5Hex(r.data) + ") in " + ms + " ms");
    }

    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++)
            out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return out;
    }
}
