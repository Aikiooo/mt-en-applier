package com.mtpatch.enapply;

import java.io.File;
import java.util.concurrent.TimeUnit;

/**
 * Direct root shell via {@code su}, bypassing Shizuku on rooted devices.
 *
 * Uses {@code su --mount-master -c} when supported (Magisk) so the shell can
 * always see other apps' {@code /sdcard/Android/data/} directories even when
 * mount-namespace isolation is enabled; falls back to plain {@code su -c} for
 * KernelSU / APatch / SuperSU.
 *
 * Output contract matches {@link UserService#exec} and {@link ShellRunner#exec}:
 * {@code "exit=N\n" + stdout + "[stderr]\n" + stderr} (or {@code "exec_error=..."}).
 */
public final class RootShell {

    public enum Status {
        /** {@code su} succeeded and returned {@code uid=0}. */
        GRANTED,
        /** A {@code su} binary is present / executed, but superuser rights were denied. */
        DENIED,
        /** Device does not appear rooted (no {@code su} binary found). */
        UNAVAILABLE
    }

    private static final long PROBE_TIMEOUT_SECONDS = 15L;
    private static final long EXEC_TIMEOUT_SECONDS = 60L;

    private static final String[] SU_PATHS = {
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/su/bin/su",
            "/vendor/bin/su",
            "/product/bin/su",
            "/apex/com.android.runtime/bin/su",
            "/data/local/xbin/su",
            "/data/local/bin/su"
    };

    private static volatile boolean sMountMaster = false;

    private RootShell() {}

    /** Fast check for a {@code su} binary in standard directories or {@code $PATH}. */
    public static boolean isSuPresent() {
        for (String p : SU_PATHS) {
            if (new File(p).exists()) return true;
        }
        String pathEnv = System.getenv("PATH");
        if (pathEnv != null) {
            for (String dir : pathEnv.split(":")) {
                if (!dir.isEmpty() && new File(dir, "su").exists()) return true;
            }
        }
        return false;
    }

    /** Probe root access, distinguishing granted, denied (root present), and unavailable.
     *  Never call on the UI thread (may prompt Magisk/KernelSU or block briefly). */
    public static Status probeStatus() {
        boolean present = isSuPresent();
        String r1 = run(new String[]{"su", "--mount-master", "-c", "id"}, PROBE_TIMEOUT_SECONDS);
        if (isRootResult(r1)) {
            sMountMaster = true;
            return Status.GRANTED;
        }
        // Only try plain `su -c` if `--mount-master` actually failed to run or wasn't recognized.
        // If Magisk already denied `su --mount-master`, avoid triggering a second prompt.
        String r2 = null;
        if (r1 == null || !r1.startsWith("exit=") || r1.contains("unrecognized")
                || r1.contains("invalid option") || r1.contains("Usage:") || r1.contains("usage:")) {
            r2 = run(new String[]{"su", "-c", "id"}, PROBE_TIMEOUT_SECONDS);
            if (isRootResult(r2)) {
                sMountMaster = false;
                return Status.GRANTED;
            }
        }
        return classifyProbe(present, r1, r2);
    }

    /** Backward-compatible boolean probe. */
    public static boolean probe() {
        return probeStatus() == Status.GRANTED;
    }

    static Status classifyProbe(boolean suPresent, String r1, String r2) {
        if (isRootResult(r1) || isRootResult(r2)) return Status.GRANTED;
        if (suPresent || ranBinary(r1) || ranBinary(r2)) return Status.DENIED;
        return Status.UNAVAILABLE;
    }

    private static boolean ranBinary(String raw) {
        return raw != null && raw.startsWith("exit=");
    }

    static boolean isRootResult(String raw) {
        return raw != null && raw.startsWith("exit=0\n") && raw.contains("uid=0");
    }

    public static String exec(String command) {
        String[] argv = sMountMaster
                ? new String[]{"su", "--mount-master", "-c", command}
                : new String[]{"su", "-c", command};
        return run(argv, EXEC_TIMEOUT_SECONDS);
    }

    private static String run(String[] argv, long timeoutSeconds) {
        Process p = null;
        try {
            p = new ProcessBuilder(argv).start();
            return ShellRunner.runProcess(p, timeoutSeconds, TimeUnit.SECONDS);
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
}
