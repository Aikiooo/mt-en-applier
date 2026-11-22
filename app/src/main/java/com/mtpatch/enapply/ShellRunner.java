package com.mtpatch.enapply;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

import rikka.shizuku.Shizuku;
import rikka.shizuku.ShizukuRemoteProcess;

/**
 * One-shot shell via Shizuku.newProcess (private in the client API v13, so
 * reflection). Needs only the LIVE Shizuku server binder — no bindUserService.
 * This is the fallback for devices where the Shizuku server dies while
 * spawning a UserService (Android 12+ phantom-process killer / OEM killers).
 */
public final class ShellRunner {

    private static final long EXEC_TIMEOUT_SECONDS = 60L;

    private static Method sNewProcess;

    private ShellRunner() {}

    private static Method method() throws Exception {
        if (sNewProcess == null) {
            sNewProcess = Shizuku.class.getDeclaredMethod("newProcess",
                    String[].class, String[].class, String.class);
            sNewProcess.setAccessible(true);
        }
        return sNewProcess;
    }

    public static boolean available() {
        try {
            method();
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /** Same output contract as UserService.exec: "exit=N\n" + stdout + "[stderr]\n...". */
    public static String exec(String command) {
        Process p = null;
        try {
            p = (Process) method().invoke(null,
                    new Object[]{new String[]{"sh", "-c", command}, null, null});
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
            Thread tOut = drainThread(p.getInputStream(), outBuf, "sh-exec-out");
            Thread tErr = drainThread(p.getErrorStream(), errBuf, "sh-exec-err");
            boolean finished = (p instanceof ShizukuRemoteProcess)
                    ? ((ShizukuRemoteProcess) p).waitForTimeout(timeout, unit)
                    : p.waitFor(timeout, unit);
            if (!finished) {
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
