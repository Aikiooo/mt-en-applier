package com.mtpatch.enapply;

interface IUserService {
    void destroy() = 16777114; // Destroy method defined by Shizuku
    void exit() = 1;           // Exit method defined by user
    /** Run a shell command as the Shizuku (shell) uid; returns combined output. */
    String exec(String command) = 2;
}
