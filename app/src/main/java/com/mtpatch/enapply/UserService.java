package com.mtpatch.enapply;

import androidx.annotation.Keep;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;

/**
 * Runs inside a Shizuku-spawned process with the shell (ADB) uid, so its
 * Runtime.exec calls can read/write the game's Android/data folder.
 */
public class UserService extends IUserService.Stub {

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
        StringBuilder sb = new StringBuilder();
        Process p = null;
        try {
            p = Runtime.getRuntime().exec(new String[]{"sh", "-c", command});
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
