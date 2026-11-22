package com.mtpatch.enapply;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Tiny HTTPS fetcher with manual redirect handling (GitHub 302s to a CDN). */
public final class Downloader {

    public interface Log { void log(String s); }

    static final int MAX_STRING_BYTES = 8 * 1024 * 1024;

    private Downloader() {}

    public static String fetchString(String url, Log log) throws Exception {
        byte[] data = fetch(url, null, log);
        return new String(data, StandardCharsets.UTF_8);
    }

    public static void fetchToFile(String url, File dest, Log log) throws Exception {
        fetch(url, dest, log);
    }

    static URL requireHttps(URL u) {
        if (!"https".equalsIgnoreCase(u.getProtocol())) {
            throw new IllegalStateException("refusing non-HTTPS URL: " + u);
        }
        return u;
    }

    static URL resolveRedirect(URL base, String loc) throws Exception {
        if (loc == null) throw new IllegalStateException("redirect without Location");
        return requireHttps(new URL(base, loc));
    }

    static byte[] readBounded(InputStream in, long contentLength, int maxBytes) throws IOException {
        if (contentLength > maxBytes) {
            throw new IOException("response too large: " + contentLength + " bytes (max " + maxBytes + ")");
        }
        ByteArrayOutputStream bos = new ByteArrayOutputStream(
                contentLength > 0 ? (int) Math.min(contentLength, 1 << 20) : 1 << 16);
        byte[] buf = new byte[1 << 16];
        int total = 0;
        int r;
        while ((r = in.read(buf)) > 0) {
            total += r;
            if (total > maxBytes) {
                throw new IOException("response exceeded " + maxBytes + " bytes");
            }
            bos.write(buf, 0, r);
        }
        return bos.toByteArray();
    }

    static long writeToFileAtomic(InputStream in, File dest) throws IOException {
        File tmp = new File(dest.getParentFile(), dest.getName() + ".tmp");
        boolean moved = false;
        try {
            long n = 0;
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                byte[] buf = new byte[1 << 16];
                int r;
                while ((r = in.read(buf)) > 0) {
                    out.write(buf, 0, r);
                    n += r;
                }
            }
            if (!tmp.renameTo(dest)) {
                java.nio.file.Files.move(tmp.toPath(), dest.toPath(),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            }
            moved = true;
            return n;
        } finally {
            if (!moved && tmp.exists()) {
                tmp.delete();
            }
        }
    }

    private static byte[] fetch(String url, File dest, Log log) throws Exception {
        URL current = requireHttps(new URL(url));
        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection c = (HttpURLConnection) current.openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(20000);
            c.setReadTimeout(60000);
            c.setRequestProperty("User-Agent", "mt-en-applier");
            int code = c.getResponseCode();
            if (code >= 300 && code < 400) {
                String loc = c.getHeaderField("Location");
                c.disconnect();
                current = resolveRedirect(current, loc);
                continue;
            }
            if (code != 200) {
                c.disconnect();
                throw new IllegalStateException("HTTP " + code + " for " + current);
            }
            long total = c.getContentLengthLong();
            try (InputStream in = c.getInputStream()) {
                if (dest != null) {
                    long n = writeToFileAtomic(in, dest);
                    if (log != null) log.log("downloaded " + n + " bytes");
                    return null;
                }
                return readBounded(in, total, MAX_STRING_BYTES);
            } finally {
                c.disconnect();
            }
        }
        throw new IllegalStateException("too many redirects for " + url);
    }
}
