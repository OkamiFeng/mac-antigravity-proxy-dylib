#define _DARWIN_C_SOURCE

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int sig) {
  (void)sig;
  stop_requested = 1;
  if (child_pid > 0) {
    kill(-child_pid, SIGTERM);
  }
}

static void set_default_env(const char *key, const char *value) {
  if (!getenv(key) && value && value[0]) {
    setenv(key, value, 1);
  }
}

static void trim_newline(char *value) {
  size_t len = strlen(value);
  while (len > 0 && (value[len - 1] == '\n' || value[len - 1] == '\r')) {
    value[--len] = '\0';
  }
}

static void load_env_file(const char *path) {
  FILE *fp = fopen(path, "r");
  if (!fp) {
    return;
  }

  char line[4096];
  while (fgets(line, sizeof(line), fp)) {
    trim_newline(line);
    if (line[0] == '\0' || line[0] == '#') {
      continue;
    }

    char *eq = strchr(line, '=');
    if (!eq) {
      continue;
    }

    *eq = '\0';
    char *key = line;
    char *value = eq + 1;
    if (key[0] && value[0] && !getenv(key)) {
      setenv(key, value, 1);
    }
  }

  fclose(fp);
}

static int dirname_inplace(char *path) {
  char *slash = strrchr(path, '/');
  if (!slash) {
    return -1;
  }
  *slash = '\0';
  return 0;
}

static int count_windows_for_pid(pid_t pid) {
  char command[512];
  snprintf(command, sizeof(command),
           "osascript -e 'tell application \"System Events\" to count windows of (first process whose unix id is %ld)' 2>/dev/null",
           (long)pid);

  FILE *fp = popen(command, "r");
  if (!fp) {
    return -1;
  }

  char output[64];
  if (!fgets(output, sizeof(output), fp)) {
    pclose(fp);
    return -1;
  }

  int status = pclose(fp);
  if (status != 0) {
    return -1;
  }

  return atoi(output);
}

static void terminate_child_group(pid_t pid) {
  if (pid <= 0) {
    return;
  }

  kill(-pid, SIGTERM);
  for (int i = 0; i < 20; i++) {
    if (waitpid(pid, NULL, WNOHANG) == pid) {
      return;
    }
    usleep(100000);
  }
  kill(-pid, SIGKILL);
  (void)waitpid(pid, NULL, 0);
}

int main(int argc, char **argv) {
  char executable[PATH_MAX];
  uint32_t size = sizeof(executable);

  extern int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
  if (_NSGetExecutablePath(executable, &size) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: executable path is too long\n");
    return 1;
  }

  char macos_dir[PATH_MAX];
  strncpy(macos_dir, executable, sizeof(macos_dir) - 1);
  macos_dir[sizeof(macos_dir) - 1] = '\0';
  if (dirname_inplace(macos_dir) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: cannot resolve MacOS directory\n");
    return 1;
  }

  char contents_dir[PATH_MAX];
  strncpy(contents_dir, macos_dir, sizeof(contents_dir) - 1);
  contents_dir[sizeof(contents_dir) - 1] = '\0';
  if (dirname_inplace(contents_dir) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: cannot resolve Contents directory\n");
    return 1;
  }

  char resources_dir[PATH_MAX];
  snprintf(resources_dir, sizeof(resources_dir), "%s/Resources", contents_dir);

  char env_file[PATH_MAX];
  snprintf(env_file, sizeof(env_file), "%s/proxy.env", resources_dir);
  load_env_file(env_file);

  char real_executable[PATH_MAX];
  char nested_executable[PATH_MAX];
  snprintf(nested_executable, sizeof(nested_executable), "%s/Antigravity.app/Contents/MacOS/Antigravity", resources_dir);
  if (access(nested_executable, X_OK) == 0) {
    snprintf(real_executable, sizeof(real_executable), "%s", nested_executable);
  } else {
    snprintf(real_executable, sizeof(real_executable), "%s/Antigravity", macos_dir);
  }

  char dylib[PATH_MAX];
  snprintf(dylib, sizeof(dylib), "%s/libantigravity_proxy.dylib", resources_dir);

  setenv("DYLD_INSERT_LIBRARIES", dylib, 1);
  set_default_env("AG_PROXY", "socks5://127.0.0.1:7890");
  set_default_env("AG_PROXY_LOG", "1");
  set_default_env("AG_PROXY_TIMEOUT_MS", "15000");
  set_default_env("HTTP_PROXY", "http://127.0.0.1:7890");
  set_default_env("HTTPS_PROXY", "http://127.0.0.1:7890");
  set_default_env("ALL_PROXY", "http://127.0.0.1:7890");
  set_default_env("http_proxy", getenv("HTTP_PROXY"));
  set_default_env("https_proxy", getenv("HTTPS_PROXY"));
  set_default_env("all_proxy", getenv("ALL_PROXY"));
  set_default_env("NO_PROXY", "localhost,127.0.0.1,::1,*.local");
  set_default_env("no_proxy", getenv("NO_PROXY"));

  if (getenv("AG_PROXY_LAUNCHER_DRY_RUN")) {
    fprintf(stderr, "real_executable=%s\n", real_executable);
    fprintf(stderr, "DYLD_INSERT_LIBRARIES=%s\n", getenv("DYLD_INSERT_LIBRARIES"));
    fprintf(stderr, "AG_PROXY=%s\n", getenv("AG_PROXY"));
    fprintf(stderr, "HTTPS_PROXY=%s\n", getenv("HTTPS_PROXY"));
    return 0;
  }

  char **child_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (!child_argv) {
    fprintf(stderr, "AntigravityProxyLauncher: calloc failed\n");
    return 1;
  }

  child_argv[0] = real_executable;
  for (int i = 1; i < argc; i++) {
    child_argv[i] = argv[i];
  }
  child_argv[argc] = NULL;

  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);
  signal(SIGHUP, handle_signal);

  pid_t pid = fork();
  if (pid < 0) {
    fprintf(stderr, "AntigravityProxyLauncher: fork failed: %s\n", strerror(errno));
    return 1;
  }

  if (pid == 0) {
    setpgid(0, 0);
    execv(real_executable, child_argv);
    fprintf(stderr, "AntigravityProxyLauncher: execv %s failed: %s\n", real_executable, strerror(errno));
    _exit(127);
  }

  child_pid = pid;
  setpgid(pid, pid);

  int saw_window = 0;
  int zero_window_ticks = 0;

  while (!stop_requested) {
    int status;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
      return WIFEXITED(status) ? WEXITSTATUS(status) : 0;
    }
    if (done < 0 && errno != EINTR) {
      return 1;
    }

    int windows = count_windows_for_pid(pid);
    if (windows > 0) {
      saw_window = 1;
      zero_window_ticks = 0;
    } else if (windows == 0 && saw_window) {
      zero_window_ticks++;
      if (zero_window_ticks >= 3) {
        terminate_child_group(pid);
        return 0;
      }
    }

    sleep(2);
  }

  terminate_child_group(pid);
  return 0;
}
