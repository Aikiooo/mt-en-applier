package com.mtpatch.enapply;

import androidx.annotation.Keep;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

/**
 * Runs inside a Shizuku-spawned process with the shell (ADB) uid, so its
 * Runtime.exec calls can read/write the game's Android/data folder.
 */
public class UserService extends IUserService.Stub {

    private static final long EXEC_TIMEOUT_SECONDS = 60L;

    public UserService() {
    }

    @Keep
    public UserService(android.content.Context context) {
    }

    @Override
    public void destroy() {
        System.exit(0);
    }

    @Override
    public void exit() {
        destroy();
    }

    @Override
    public String exec(String command) {
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[]{"sh", "-c", command});
            return runProcess(p, EXEC_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (Throwable t) {
            if (p != null) {
                try {
                    p.destroyForcibly();
                } catch (Throwable ignored) {
                }
            }
            return "exec_error=" + t;
        }
    }

    static String runProcess(Process p, long timeout, TimeUnit unit) {
        StringBuilder sb = new StringBuilder();
        try {
            StringBuffer outBuf = new StringBuffer();
            StringBuffer errBuf = new StringBuffer();
            Thread tOut = drainThread(p.getInputStream(), outBuf, "user-exec-out");
            Thread tErr = drainThread(p.getErrorStream(), errBuf, "user-exec-err");
            if (!p.waitFor(timeout, unit)) {
                p.destroyForcibly();
                tOut.join(2000);
                tErr.join(2000);
                return "exec_error=timeout after " + timeout + " "
                        + unit.toString().toLowerCase(java.util.Locale.US);
            }
            tOut.join(5000);
            tErr.join(5000);
            int code = p.exitValue();
            sb.append("exit=").append(code).append('\n');
            if (outBuf.length() > 0) sb.append(outBuf);
            if (errBuf.length() > 0) sb.append("[stderr]\n").append(errBuf);
        } catch (Throwable t) {
            sb.append("exec_error=").append(t);
        } finally {
            if (p != null) {
                try {
                    p.destroyForcibly();
                } catch (Throwable ignored) {
                }
            }
        }
        return sb.toString();
    }

    private static Thread drainThread(InputStream in, StringBuffer buf, String name) {
        Thread t = new Thread(() -> {
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(in, StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) buf.append(line).append('\n');
            } catch (Throwable ignored) {
            }
        }, name);
        t.setDaemon(true);
        t.start();
        return t;
    }
}
