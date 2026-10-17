package com.mtpatch.enapply.core;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Fully on-device auto-patcher (port of build_full_en.py, minus UnityPy).
 *
 * After a game update drops a NEW language bundle, this:
 *   1. parses the new UnityFS (UnityFs),
 *   2. finds every known table by scanning the decompressed stream for the
 *      table NAME and validating the inline TextAsset frame + AES decrypt
 *      (avoids porting UnityPy's SerializedFile parser),
 *   3. decrypts each table, overlays the translation cache (exact JA-string
 *      match per cell) + id-based hand maps; brand-new cells stay Japanese,
 *   4. re-encrypts to the SAME ciphertext length (encrypt_fit), reverting the
 *      longest rows to JA when the budget is blown (fit_table semantics),
 *   5. rebuilds the bundle layout-preserving (UnityFs.rebuild).
 */
public final class AutoPatcher {

    public interface Log { void log(String s); }

    /** Work done so far, 0..100, with a short phase label for the UI. */
    public interface Progress { void at(int pct, String phase); }

    /** Below this share of Japanese text cells the source is a patched bundle,
     *  not the Japanese original: stock is ~99%, the published patches 0%. */
    public static final double MIN_JA_SHARE = 0.20;

    public static final class TableHit {
        final String name; final int off; final byte[] ct;
        TableHit(String name, int off, byte[] ct) { this.name = name; this.off = off; this.ct = ct; }
    }

    public static final class Result {
        public byte[] data;
        public int tablesFound, patched, fitAfterRevert, jaOnly, skipped, leftJaCells;
        /** Source text cells (with a letter or kana/kanji), and those in Japanese. */
        public int textCellsIn, jaCellsIn;
        public final List<String> lines = new ArrayList<>();

        /** Whether the source was the Japanese original. The cache matches
         *  Japanese text only, so patching anything else changes almost nothing. */
        public boolean sourceIsJapanese() {
            return textCellsIn > 0 && jaCellsIn >= MIN_JA_SHARE * textCellsIn;
        }
    }

    private AutoPatcher() {}

    static int indexOf(byte[] hay, byte[] needle, int from) {
        outer:
        for (int i = Math.max(0, from); i + needle.length <= hay.length; i++) {
            for (int j = 0; j < needle.length; j++)
                if (hay[i + j] != needle[j]) continue outer;
            return i;
        }
        return -1;
    }

    /** Python str.strip() equivalent: Java trim() misses U+3000 (ideographic space). */
    static String jaTrim(String s) {
        int a = 0, b = s.length();
        while (a < b && isPySpace(s.charAt(a))) a++;
        while (b > a && isPySpace(s.charAt(b - 1))) b--;
        return s.substring(a, b);
    }

    private static boolean isPySpace(char c) {
        return c <= ' ' || Character.isWhitespace(c);
    }

    private static boolean hasLetter(String s) {
        for (int i = 0; i < s.length(); i++)
            if (Character.isLetter(s.charAt(i))) return true;
        return false;
    }

    static boolean hasCjk(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x3400 && c <= 0x9FFF)) return true;
        }
        return false;
    }

    /**
     * Locate each known table in the decompressed stream: name bytes preceded by
     * a matching int32 name length, then an aligned int32 script length, then the
     * AES ciphertext — validated by actually decrypting. Exactly one valid
     * candidate required; otherwise the table is skipped (stays Japanese).
     */
    static List<TableHit> findTables(byte[] full, List<String> names,
                                     byte[] key, byte[] iv, Log log, Progress prog, int p0, int p1) {
        List<TableHit> out = new ArrayList<>();
        for (int n = 0; n < names.size(); n++) {
            String name = names.get(n);
            prog.at(p0 + (p1 - p0) * n / names.size(), "Finding tables");
            byte[] needle = name.getBytes(StandardCharsets.UTF_8);
            int from = 0;
            TableHit hit = null;
            boolean ambiguous = false;
            while (true) {
                int pos = indexOf(full, needle, from);
                if (pos < 0) break;
                from = pos + 1;
                if (pos < 4) continue;
                if (MasterCrypto.leInt(full, pos - 4) != needle.length) continue;
                int objStart = pos - 4;
                int p = 4 + needle.length;
                p += (4 - (p % 4)) % 4;              // object-relative align (python semantics)
                int abs = objStart + p;
                if (abs + 4 > full.length) continue;
                int slen = MasterCrypto.leInt(full, abs);
                if (slen <= 0 || slen % 16 != 0 || abs + 4 + slen > full.length) continue;
                byte[] ct = Arrays.copyOfRange(full, abs + 4, abs + 4 + slen);
                if (!MasterCrypto.validate(key, iv, ct)) continue;
                if (hit != null) { ambiguous = true; break; }
                hit = new TableHit(name, abs + 4, ct);
            }
            if (ambiguous) {
                log.log(name + ": ambiguous location, left Japanese");
            } else if (hit != null) {
                out.add(hit);
            } else {
                log.log(name + ": not found (new or renamed table), left Japanese");
            }
        }
        return out;
    }

    /** tsv_util.read_table: header width enforced, overflow tabs join the last column. */
    private static LinkedHashMap<String, String[]> parseRows(String[] lines, int cols) {
        LinkedHashMap<String, String[]> rows = new LinkedHashMap<>();
        int need = cols - 1;
        for (int i = 1; i < lines.length; i++) {
            String ln = lines[i];
            if (ln.trim().isEmpty()) continue;
            String[] parts = ln.split("\t", -1);
            String[] vals = new String[Math.max(need, parts.length - 1)];
            System.arraycopy(parts, 1, vals, 0, parts.length - 1);
            for (int j = parts.length - 1; j < need; j++) vals[j] = "";
            if (vals.length > need) {
                StringBuilder last = new StringBuilder(vals[need - 1]);
                for (int j = need; j < vals.length; j++) last.append('\t').append(vals[j]);
                String[] trimmed = new String[need];
                System.arraycopy(vals, 0, trimmed, 0, need - 1);
                trimmed[need - 1] = last.toString();
                vals = trimmed;
            }
            rows.put(parts[0], vals);
        }
        return rows;
    }

    private static String buildText(String header, LinkedHashMap<String, String[]> rows) {
        StringBuilder sb = new StringBuilder(header).append('\n');
        for (Map.Entry<String, String[]> e : rows.entrySet()) {
            sb.append(e.getKey());
            for (String v : e.getValue()) sb.append('\t').append(v);
            sb.append('\n');
        }
        return sb.toString();
    }

    /** Bytes this row adds to toPlain(buildText(...)): the text is normalized
     *  row by row, so a table's plaintext length is the sum over its rows. */
    private static int plainLen(String id, String[] vals) {
        StringBuilder sb = new StringBuilder(id);
        for (String v : vals) sb.append('\t').append(v);
        sb.append('\n');
        return sb.toString().replace("\r\n", "\n").replace("\r", "\n")
                .getBytes(StandardCharsets.UTF_8).length;
    }

    private static int byteLen(String[] vals) {
        int n = 0;
        for (String v : vals) n += v.getBytes(StandardCharsets.UTF_8).length + 1;
        return n;
    }

    /** Patch one table in fs.full; returns status note. */
    private static String patchTable(UnityFs.Bundle fs, TableHit h, byte[] key, byte[] iv,
                                     Map<String, String> cache,
                                     Map<String, Map<String, String>> hand, Result r) {
        String jaText;
        try {
            jaText = new String(MasterCrypto.decrypt(h.ct, key, iv), StandardCharsets.UTF_8);
        } catch (Throwable t) {
            r.skipped++;
            return "decrypt_fail";
        }
        String norm = jaText.replace("\r\n", "\n").replace("\r", "\n");
        String[] lines = norm.split("\n", -1);
        if (lines.length == 0 || !lines[0].startsWith("id\t")) {
            r.skipped++;
            return "bad_header";
        }
        String header = lines[0];
        int cols = header.split("\t", -1).length;
        LinkedHashMap<String, String[]> jaRows = parseRows(lines, cols);

        // overlay the translation cache per cell (exact trimmed JA-string match)
        LinkedHashMap<String, String[]> rows = new LinkedHashMap<>();
        for (Map.Entry<String, String[]> e : jaRows.entrySet()) {
            String[] jv = e.getValue();
            String[] vals = new String[jv.length];
            for (int i = 0; i < jv.length; i++) {
                if (hasLetter(jv[i])) r.textCellsIn++;
                if (hasCjk(jv[i])) r.jaCellsIn++;
                String en = cache.get(jaTrim(jv[i]));
                if (en != null && !en.isEmpty()) vals[i] = en;
                else { vals[i] = jv[i]; if (hasCjk(jv[i])) r.leftJaCells++; }
            }
            rows.put(e.getKey(), vals);
        }
        // id-based hand overrides (last column)
        Map<String, String> hh = hand.get(h.name);
        if (hh != null) {
            for (Map.Entry<String, String> e : hh.entrySet()) {
                String[] row = rows.get(e.getKey());
                if (row != null && row.length > 0) row[row.length - 1] = e.getValue();
            }
        }

        byte[] ct = MasterCrypto.encryptFit(MasterCrypto.toPlain(buildText(header, rows)),
                key, iv, h.ct.length);
        String note = "fit";
        if (ct == null) {
            // fit_table: revert longest EN row deltas toward JA until it fits
            List<int[]> deltas = new ArrayList<>();
            List<String> ids = new ArrayList<>(rows.keySet());
            for (int i = 0; i < ids.size(); i++) {
                String[] v = rows.get(ids.get(i));
                String[] jv = jaRows.get(ids.get(i));
                if (v != null && jv != null && !Arrays.equals(v, jv))
                    deltas.add(new int[]{byteLen(v) - byteLen(jv), i});
            }
            deltas.sort((a, b) -> Integer.compare(b[0], a[0]));
            // Same rows reverted as re-encrypting after each one, but sized by
            // arithmetic: it fits once the plaintext is at most ct length - 1.
            // (Re-encrypting each time took minutes on the story tables.)
            long plain = header.getBytes(StandardCharsets.UTF_8).length + 1;   // header line
            for (Map.Entry<String, String[]> e : rows.entrySet()) plain += plainLen(e.getKey(), e.getValue());
            for (int[] d : deltas) {
                String id = ids.get(d[1]);
                plain += plainLen(id, jaRows.get(id)) - plainLen(id, rows.get(id));
                rows.put(id, jaRows.get(id));
                if (plain <= h.ct.length - 1) {
                    ct = MasterCrypto.encryptFit(MasterCrypto.toPlain(buildText(header, rows)),
                            key, iv, h.ct.length);
                    if (ct != null) { note = "fit_after_revert"; r.fitAfterRevert++; break; }
                }
            }
            if (ct == null) {
                ct = MasterCrypto.encryptFit(MasterCrypto.toPlain(norm), key, iv, h.ct.length);
                note = "ja_only";
                r.jaOnly++;
            }
        }
        if (ct == null) {
            r.skipped++;
            return "oversize_even_ja";
        }
        System.arraycopy(ct, 0, fs.full, h.off, ct.length);
        r.patched++;
        return note;
    }

    /** Each table's row ids, in order. Ids are the same in every language, so two
     *  packs with equal ids hold the same game data (a patch fits that game build).
     *  Tables that aren't found are left out. */
    public static Map<String, List<String>> rowIds(byte[] bundle, byte[] key, byte[] iv,
                                                    List<String> tableNames, Progress prog) {
        UnityFs.Bundle fs = UnityFs.open(bundle);
        Map<String, List<String>> out = new LinkedHashMap<>();
        for (TableHit h : findTables(fs.full, tableNames, key, iv, s -> {}, prog, 0, 100)) {
            String text;
            try {
                text = new String(MasterCrypto.decrypt(h.ct, key, iv), StandardCharsets.UTF_8);
            } catch (Throwable t) {
                continue;
            }
            String[] lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n", -1);
            List<String> ids = new ArrayList<>(lines.length);
            for (int i = 1; i < lines.length; i++) {
                if (lines[i].trim().isEmpty()) continue;
                int tab = lines[i].indexOf('\t');
                ids.add(tab < 0 ? lines[i] : lines[i].substring(0, tab));
            }
            out.put(h.name, ids);
        }
        return out;
    }

    public static Result run(byte[] stock, byte[] key, byte[] iv,
                             Map<String, String> cache,
                             Map<String, Map<String, String>> hand,
                             List<String> tableNames, Log log) {
        return run(stock, key, iv, cache, hand, tableNames, log, (p, s) -> {});
    }

    public static Result run(byte[] stock, byte[] key, byte[] iv,
                             Map<String, String> cache,
                             Map<String, Map<String, String>> hand,
                             List<String> tableNames, Log log, Progress prog) {
        Result r = new Result();
        prog.at(0, "Unpacking the language pack");
        UnityFs.Bundle fs = UnityFs.open(stock);
        log.log("UnityFS: " + fs.blocks.length + " blocks, engine " + fs.hdr.uv
                + ", stream " + fs.full.length + " bytes");
        List<TableHit> hits = findTables(fs.full, tableNames, key, iv, log, prog, 10, 45);
        r.tablesFound = hits.size();
        if (hits.size() < 100)
            throw new IllegalStateException("only " + hits.size()
                    + " tables located — AES keys do not match this bundle?");
        for (int i = 0; i < hits.size(); i++) {
            TableHit h = hits.get(i);
            prog.at(45 + 45 * i / hits.size(), "Translating tables (" + (i + 1) + "/" + hits.size() + ")");
            String note = patchTable(fs, h, key, iv, cache, hand, r);
            if (!"fit".equals(note)) log.log(h.name + ": " + note);
        }
        prog.at(90, "Repacking the language pack");
        UnityFs.reslice(fs);
        r.data = UnityFs.rebuild(fs);
        prog.at(100, "Repacked");
        return r;
    }
}
