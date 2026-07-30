package com.mtpatch.enapply.core;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Minimal JSON parser for the shapes we ship: objects of strings/numbers/bools,
 * optionally nested one extra level ({"cache":{...}, "hand":{...}}). No arrays.
 * Values are returned as Strings; nested objects as Map&lt;String,Object&gt;.
 */
public final class JsonMap {

    private final String s;
    private int p;

    private JsonMap(String s) { this.s = s; }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> parseObject(String json) {
        JsonMap j = new JsonMap(json);
        j.ws();
        Map<String, Object> out = (Map<String, Object>) j.value();
        j.ws();
        return out;
    }

    public static Map<String, String> parseFlat(String json) {
        Map<String, Object> o = parseObject(json);
        Map<String, String> out = new LinkedHashMap<>(o.size());
        for (Map.Entry<String, Object> e : o.entrySet()) out.put(e.getKey(), String.valueOf(e.getValue()));
        return out;
    }

    private void ws() {
        while (p < s.length()) {
            char c = s.charAt(p);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p++;
            else break;
        }
    }

    private Object value() {
        ws();
        if (p >= s.length()) throw new IllegalArgumentException("eof");
        char c = s.charAt(p);
        if (c == '{') return object();
        if (c == '"') return string();
        if (c == 't') { expect("true"); return "true"; }
        if (c == 'f') { expect("false"); return "false"; }
        if (c == 'n') { expect("null"); return null; }
        // number
        int start = p;
        while (p < s.length() && "-+0123456789.eE".indexOf(s.charAt(p)) >= 0) p++;
        return s.substring(start, p);
    }

    private void expect(String lit) {
        if (!s.startsWith(lit, p)) throw new IllegalArgumentException("expected " + lit + " @" + p);
        p += lit.length();
    }

    private Map<String, Object> object() {
        Map<String, Object> map = new LinkedHashMap<>();
        p++; // {
        ws();
        if (p < s.length() && s.charAt(p) == '}') { p++; return map; }
        while (true) {
            ws();
            String k = string();
            ws();
            if (p >= s.length() || s.charAt(p) != ':') throw new IllegalArgumentException("expected : @" + p);
            p++;
            map.put(k, value());
            ws();
            if (p >= s.length()) throw new IllegalArgumentException("eof in object");
            char c = s.charAt(p);
            if (c == ',') { p++; continue; }
            if (c == '}') { p++; return map; }
            throw new IllegalArgumentException("expected , or } @" + p);
        }
    }

    private String string() {
        if (p >= s.length() || s.charAt(p) != '"') throw new IllegalArgumentException("expected string @" + p);
        p++;
        StringBuilder sb = new StringBuilder();
        while (p < s.length()) {
            char c = s.charAt(p++);
            if (c == '"') return sb.toString();
            if (c == '\\') {
                if (p >= s.length()) break;
                char e = s.charAt(p++);
                switch (e) {
                    case '"': sb.append('"'); break;
                    case '\\': sb.append('\\'); break;
                    case '/': sb.append('/'); break;
                    case 'b': sb.append('\b'); break;
                    case 'f': sb.append('\f'); break;
                    case 'n': sb.append('\n'); break;
                    case 'r': sb.append('\r'); break;
                    case 't': sb.append('\t'); break;
                    case 'u':
                        sb.append((char) Integer.parseInt(s.substring(p, p + 4), 16));
                        p += 4;
                        break;
                    default: sb.append(e);
                }
            } else {
                sb.append(c);
            }
        }
        throw new IllegalArgumentException("unterminated string");
    }
}
