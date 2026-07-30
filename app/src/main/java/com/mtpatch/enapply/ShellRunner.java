package com.mtpatch.enapply;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.lang.reflect.Method;

import rikka.shizuku.Shizuku;

/**
 * One-shot shell via Shizuku.newProcess (private in the client API v13, so
 * reflection). Needs only the LIVE Shizuku server binder — no bindUserService.
 * This is the fallback for devices where the Shizuku server dies while
 * spawning a UserService (Android 12+ phantom-process killer / OEM killers).
 */
public final class ShellRunner {

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
        StringBuilder sb = new StringBuilder();
        Process p = null;
        try {
            p = (Process) method().invoke(null,
                    new Object[]{new String[]{"sh", "-c", command}, null, null});
            String out = readAll(p.getInputStream());
            String err = readAll(p.getErrorStream());
            int code = p.waitFor();
            sb.append("exit=").append(code).append('\n');
            if (!out.isEmpty()) sb.append(out);
            if (!err.isEmpty()) sb.append("[stderr]\n").append(err);
        } catch (Throwable t) {
            sb.append("exec_error=").append(t);
        } finally {
            if (p != null) p.destroy();
        }
        return sb.toString();
    }

    private static String readAll(InputStream in) throws Exception {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(in))) {
            String line;
            while ((line = br.readLine()) != null) sb.append(line).append('\n');
        }
        return sb.toString();
    }
}
