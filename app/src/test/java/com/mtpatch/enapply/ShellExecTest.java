package com.mtpatch.enapply;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.util.concurrent.TimeUnit;

public class ShellExecTest {

    /** Cross-platform helper subprocess invoked by the tests below. */
    public static final class Child {
        public static void main(String[] args) throws Exception {
            String mode = args.length > 0 ? args[0] : "normal";
            if ("normal".equals(mode)) {
                System.out.println("hello-out");
                System.err.println("hello-err");
                System.exit(0);
            } else if ("flood".equals(mode)) {
                // Write >128 KB to stderr BEFORE stdout to trigger classic pipe-buffer deadlock
                // if stderr is not drained concurrently with stdout.
                String chunk = "0123456789abcdef".repeat(64); // 1 KB line
                for (int i = 0; i < 160; i++) {
                    System.err.println("E" + i + ":" + chunk);
                }
                for (int i = 0; i < 160; i++) {
                    System.out.println("O" + i + ":" + chunk);
                }
                System.exit(0);
            } else if ("sleep".equals(mode)) {
                Thread.sleep(30_000);
            }
        }
    }

    private static Process spawnChild(String mode) throws Exception {
        String javaBin = new File(new File(System.getProperty("java.home"), "bin"),
                System.getProperty("os.name").toLowerCase().contains("win") ? "java.exe" : "java")
                .getAbsolutePath();
        String cp = System.getProperty("java.class.path");
        return new ProcessBuilder(javaBin, "-cp", cp, Child.class.getName(), mode).start();
    }

    @Test
    public void userServiceCapturesStdoutAndStderr() throws Exception {
        Process p = spawnChild("normal");
        String res = UserService.runProcess(p, 15, TimeUnit.SECONDS);
        assertTrue(res, res.startsWith("exit=0\n"));
        assertTrue(res, res.contains("hello-out\n"));
        assertTrue(res, res.contains("[stderr]\nhello-err\n"));
    }

    @Test
    public void shellRunnerCapturesStdoutAndStderr() throws Exception {
        Process p = spawnChild("normal");
        String res = ShellRunner.runProcess(p, 15, TimeUnit.SECONDS);
        assertTrue(res, res.startsWith("exit=0\n"));
        assertTrue(res, res.contains("hello-out\n"));
        assertTrue(res, res.contains("[stderr]\nhello-err\n"));
    }

    @Test
    public void concurrentDrainPreventsStderrDeadlock() throws Exception {
        Process p1 = spawnChild("flood");
        String r1 = UserService.runProcess(p1, 15, TimeUnit.SECONDS);
        assertTrue(r1.startsWith("exit=0\n"));
        assertTrue(r1.contains("O159:"));
        assertTrue(r1.contains("[stderr]\n"));
        assertTrue(r1.contains("E159:"));

        Process p2 = spawnChild("flood");
        String r2 = ShellRunner.runProcess(p2, 15, TimeUnit.SECONDS);
        assertTrue(r2.startsWith("exit=0\n"));
        assertTrue(r2.contains("O159:"));
        assertTrue(r2.contains("[stderr]\n"));
        assertTrue(r2.contains("E159:"));
    }

    @Test
    public void timeoutDestroysHangingProcess() throws Exception {
        long t0 = System.nanoTime();
        Process p1 = spawnChild("sleep");
        String r1 = UserService.runProcess(p1, 1, TimeUnit.SECONDS);
        long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
        assertTrue(r1, r1.startsWith("exec_error=timeout"));
        assertFalse("hanging process should be killed", p1.isAlive());
        assertTrue("timeout took too long: " + elapsedMs + "ms", elapsedMs < 10_000);

        Process p2 = spawnChild("sleep");
        String r2 = ShellRunner.runProcess(p2, 1, TimeUnit.SECONDS);
        assertTrue(r2, r2.startsWith("exec_error=timeout"));
        assertFalse("hanging process should be killed", p2.isAlive());
    }
}
