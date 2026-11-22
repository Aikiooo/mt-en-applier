package com.mtpatch.enapply;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public class DownloaderTest {

    @Rule
    public TemporaryFolder temp = new TemporaryFolder();

    @Test
    public void rejectsHttpInitialUrlAndRedirects() throws Exception {
        URL httpsBase = new URL("https://github.com/Aikiooo/mt-en-applier/releases/download/patch-latest/version.json");
        assertEquals("https", Downloader.requireHttps(httpsBase).getProtocol());
        assertEquals("https://objects.githubusercontent.com/file",
                Downloader.resolveRedirect(httpsBase, "https://objects.githubusercontent.com/file").toString());
        assertEquals("https://github.com/other/path",
                Downloader.resolveRedirect(httpsBase, "/other/path").toString());

        try {
            Downloader.fetchString("http://example.com/version.json", null);
            fail("expected non-HTTPS initial URL to fail");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("non-HTTPS"));
        }

        try {
            Downloader.resolveRedirect(httpsBase, "http://insecure.example.com/payload");
            fail("expected HTTPS->HTTP redirect downgrade to fail");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("non-HTTPS"));
        }

        try {
            Downloader.resolveRedirect(httpsBase, null);
            fail("expected null Location to fail");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("Location"));
        }
    }

    @Test
    public void readBoundedEnforcesMaxBytes() throws Exception {
        byte[] small = "hello world".getBytes(StandardCharsets.UTF_8);
        assertArrayEquals(small, Downloader.readBounded(new ByteArrayInputStream(small), small.length, 64));

        // Declared Content-Length exceeds limit
        try {
            Downloader.readBounded(new ByteArrayInputStream(small), 65, 64);
            fail("expected content-length rejection");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().contains("too large"));
        }

        // Unknown Content-Length (-1) streaming past limit
        byte[] big = new byte[128];
        try {
            Downloader.readBounded(new ByteArrayInputStream(big), -1, 64);
            fail("expected streaming size rejection");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().contains("exceeded"));
        }
    }

    @Test
    public void writeToFileAtomicCleansUpTmpOnFailure() throws Exception {
        File dir = temp.newFolder();
        File dest = new File(dir, "payload.bin");
        File tmp = new File(dir, "payload.bin.tmp");

        byte[] ok = "verified-content".getBytes(StandardCharsets.UTF_8);
        long written = Downloader.writeToFileAtomic(new ByteArrayInputStream(ok), dest);
        assertEquals(ok.length, written);
        assertTrue(dest.exists());
        assertFalse(tmp.exists());
        assertArrayEquals(ok, Files.readAllBytes(dest.toPath()));

        // Stream fails halfway: .tmp must be deleted and existing dest untouched
        File dest2 = new File(dir, "broken.bin");
        File tmp2 = new File(dir, "broken.bin.tmp");
        InputStream failing = new InputStream() {
            int calls = 0;
            @Override
            public int read() throws IOException {
                if (calls++ < 5) return 'A';
                throw new IOException("simulated network reset");
            }
            @Override
            public int read(byte[] b, int off, int len) throws IOException {
                if (calls++ == 0) {
                    b[off] = 'A';
                    return 1;
                }
                throw new IOException("simulated network reset");
            }
        };
        try {
            Downloader.writeToFileAtomic(failing, dest2);
            fail("expected IOException");
        } catch (IOException expected) {
            assertTrue(expected.getMessage().contains("simulated network reset"));
        }
        assertFalse("tmp file must be cleaned up after exception", tmp2.exists());
        assertFalse("dest must not be created after failed write", dest2.exists());
    }
}
