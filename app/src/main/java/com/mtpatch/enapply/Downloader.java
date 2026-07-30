package com.mtpatch.enapply;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Tiny HTTP(S) fetcher with manual redirect handling (GitHub 302s to a CDN). */
public final class Downloader {

    public interface Log { void log(String s); }

    private Downloader() {}

    public static String fetchString(String url, Log log) throws Exception {
        byte[] data = fetch(url, null, log);
        return new String(data, StandardCharsets.UTF_8);
    }

    public static void fetchToFile(String url, File dest, Log log) throws Exception {
        fetch(url, dest, log);
    }

    private static byte[] fetch(String url, File dest, Log log) throws Exception {
        String current = url;
        for (int hop = 0; hop < 5; hop++) {
            HttpURLConnection c = (HttpURLConnection) new URL(current).openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(20000);
            c.setReadTimeout(60000);
            c.setRequestProperty("User-Agent", "mt-en-applier");
            int code = c.getResponseCode();
            if (code >= 300 && code < 400) {
                String loc = c.getHeaderField("Location");
                c.disconnect();
                if (loc == null) throw new IllegalStateException("redirect without Location");
                current = new URL(new URL(current), loc).toString();
                continue;
            }
            if (code != 200) {
                c.disconnect();
                throw new IllegalStateException("HTTP " + code + " for " + current);
            }
            long total = c.getContentLengthLong();
            try (InputStream in = c.getInputStream()) {
                if (dest != null) {
                    File tmp = new File(dest.getParentFile(), dest.getName() + ".tmp");
                    long n = 0;
                    try (FileOutputStream out = new FileOutputStream(tmp)) {
                        byte[] buf = new byte[1 << 16];
                        int r;
                        while ((r = in.read(buf)) > 0) { out.write(buf, 0, r); n += r; }
                    }
                    if (!tmp.renameTo(dest)) {
                        java.nio.file.Files.move(tmp.toPath(), dest.toPath(),
                                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    }
                    log.log("downloaded " + n + " bytes");
                    return null;
                }
                java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream(
                        total > 0 ? (int) Math.min(total, 1 << 22) : 1 << 16);
                byte[] buf = new byte[1 << 16];
                int r;
                while ((r = in.read(buf)) > 0) bos.write(buf, 0, r);
                return bos.toByteArray();
            } finally {
                c.disconnect();
            }
        }
        throw new IllegalStateException("too many redirects for " + url);
    }
}
