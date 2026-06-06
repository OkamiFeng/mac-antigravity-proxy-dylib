#define _DARWIN_C_SOURCE

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef SO_NOSIGPIPE
#define SO_NOSIGPIPE 0x1022
#endif

#define FAKE_NET_START 0xC6120001u
#define FAKE_NET_END   0xC613FFFEu
#define MAX_MAPS 4096
#define MAX_HOST 255

struct host_map {
  uint32_t ip_be;
  char host[MAX_HOST + 1];
};

static pthread_mutex_t config_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;
static int config_loaded;
static int log_enabled;
static int timeout_ms = 15000;
static char proxy_host[MAX_HOST + 1] = "127.0.0.1";
static int proxy_port = 7890;
static uint32_t next_fake_host_order = FAKE_NET_START;
static struct host_map maps[MAX_MAPS];
static size_t map_count;

struct interpose_entry {
  const void *replacement;
  const void *replacee;
};

static void log_msg(const char *fmt, ...) {
  if (!log_enabled) {
    return;
  }

  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[ag-proxy] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

static void load_real_symbols(void) {
}

static int direct_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  return (int)syscall(SYS_connect, fd, addr, len);
}

static void parse_proxy_url(const char *value) {
  const char *p = value;
  const char *scheme = strstr(p, "://");
  if (scheme) {
    p = scheme + 3;
  }

  const char *at = strrchr(p, '@');
  if (at) {
    p = at + 1;
  }

  char host_port[512];
  size_t len = strcspn(p, "/");
  if (len >= sizeof(host_port)) {
    len = sizeof(host_port) - 1;
  }
  memcpy(host_port, p, len);
  host_port[len] = '\0';

  char *colon = strrchr(host_port, ':');
  if (!colon || !colon[1]) {
    return;
  }

  *colon = '\0';
  int port = atoi(colon + 1);
  if (port <= 0 || port > 65535 || host_port[0] == '\0') {
    return;
  }

  strncpy(proxy_host, host_port, MAX_HOST);
  proxy_host[MAX_HOST] = '\0';
  proxy_port = port;
}

static void load_config(void) {
  pthread_mutex_lock(&config_lock);
  if (config_loaded) {
    pthread_mutex_unlock(&config_lock);
    return;
  }

  load_real_symbols();

  const char *proxy = getenv("AG_PROXY");
  if (!proxy || !proxy[0]) {
    proxy = getenv("ALL_PROXY");
  }
  if (!proxy || !proxy[0]) {
    proxy = getenv("all_proxy");
  }
  if (proxy && proxy[0]) {
    parse_proxy_url(proxy);
  }

  const char *log = getenv("AG_PROXY_LOG");
  log_enabled = log && (!strcmp(log, "1") || !strcasecmp(log, "true"));

  const char *timeout = getenv("AG_PROXY_TIMEOUT_MS");
  if (timeout && timeout[0]) {
    int parsed = atoi(timeout);
    if (parsed >= 1000 && parsed <= 120000) {
      timeout_ms = parsed;
    }
  }

  config_loaded = 1;
  log_msg("loaded proxy %s:%d", proxy_host, proxy_port);
  pthread_mutex_unlock(&config_lock);
}

static int is_localhost_name(const char *host) {
  if (!host) {
    return 0;
  }
  return !strcmp(host, "localhost") || !strcmp(host, "127.0.0.1") || !strcmp(host, "::1");
}

static int is_numeric_host(const char *host) {
  struct in_addr a4;
  struct in6_addr a6;
  return inet_pton(AF_INET, host, &a4) == 1 || inet_pton(AF_INET6, host, &a6) == 1;
}

static int is_fake_ip_be(uint32_t ip_be) {
  uint32_t ip = ntohl(ip_be);
  return ip >= FAKE_NET_START && ip <= FAKE_NET_END;
}

static const char *lookup_host_by_ip(uint32_t ip_be) {
  const char *result = NULL;
  pthread_mutex_lock(&map_lock);
  for (size_t i = 0; i < map_count; i++) {
    if (maps[i].ip_be == ip_be) {
      result = maps[i].host;
      break;
    }
  }
  pthread_mutex_unlock(&map_lock);
  return result;
}

static uint32_t fake_ip_for_host(const char *host) {
  uint32_t result = 0;

  pthread_mutex_lock(&map_lock);
  for (size_t i = 0; i < map_count; i++) {
    if (!strcmp(maps[i].host, host)) {
      result = maps[i].ip_be;
      break;
    }
  }

  if (!result && map_count < MAX_MAPS) {
    if (next_fake_host_order > FAKE_NET_END) {
      next_fake_host_order = FAKE_NET_START;
    }
    result = htonl(next_fake_host_order++);
    maps[map_count].ip_be = result;
    strncpy(maps[map_count].host, host, MAX_HOST);
    maps[map_count].host[MAX_HOST] = '\0';
    map_count++;
  }
  pthread_mutex_unlock(&map_lock);

  return result;
}

static int parse_service_port(const char *service) {
  if (!service || !service[0]) {
    return 0;
  }
  char *end = NULL;
  long value = strtol(service, &end, 10);
  if (end && *end == '\0' && value >= 0 && value <= 65535) {
    return (int)value;
  }
  if (!strcmp(service, "http")) {
    return 80;
  }
  if (!strcmp(service, "https")) {
    return 443;
  }
  return 0;
}

static int make_addrinfo_v4(const char *canon, uint32_t ip_be, int port, const struct addrinfo *hints, struct addrinfo **res) {
  struct addrinfo *ai = calloc(1, sizeof(*ai));
  struct sockaddr_in *sa = calloc(1, sizeof(*sa));
  if (!ai || !sa) {
    free(ai);
    free(sa);
    return EAI_MEMORY;
  }

  sa->sin_family = AF_INET;
  sa->sin_port = htons((uint16_t)port);
  sa->sin_addr.s_addr = ip_be;

  ai->ai_family = AF_INET;
  ai->ai_socktype = hints ? hints->ai_socktype : 0;
  ai->ai_protocol = hints ? hints->ai_protocol : 0;
  ai->ai_addrlen = sizeof(*sa);
  ai->ai_addr = (struct sockaddr *)sa;

  if (canon && hints && (hints->ai_flags & AI_CANONNAME)) {
    ai->ai_canonname = strdup(canon);
    if (!ai->ai_canonname) {
      free(sa);
      free(ai);
      return EAI_MEMORY;
    }
  }

  *res = ai;
  return 0;
}

static int make_addrinfo_v6(const char *canon, const struct in6_addr *ip, int port, const struct addrinfo *hints, struct addrinfo **res) {
  struct addrinfo *ai = calloc(1, sizeof(*ai));
  struct sockaddr_in6 *sa = calloc(1, sizeof(*sa));
  if (!ai || !sa) {
    free(ai);
    free(sa);
    return EAI_MEMORY;
  }

  sa->sin6_family = AF_INET6;
  sa->sin6_port = htons((uint16_t)port);
  memcpy(&sa->sin6_addr, ip, sizeof(*ip));

  ai->ai_family = AF_INET6;
  ai->ai_socktype = hints ? hints->ai_socktype : 0;
  ai->ai_protocol = hints ? hints->ai_protocol : 0;
  ai->ai_addrlen = sizeof(*sa);
  ai->ai_addr = (struct sockaddr *)sa;

  if (canon && hints && (hints->ai_flags & AI_CANONNAME)) {
    ai->ai_canonname = strdup(canon);
    if (!ai->ai_canonname) {
      free(sa);
      free(ai);
      return EAI_MEMORY;
    }
  }

  *res = ai;
  return 0;
}

static int make_fake_addrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  uint32_t ip_be = fake_ip_for_host(node);
  if (!ip_be) {
    return EAI_MEMORY;
  }

  int rc = make_addrinfo_v4(node, ip_be, parse_service_port(service), hints, res);
  if (rc != 0) {
    return rc;
  }

  struct in_addr fake;
  fake.s_addr = ip_be;
  log_msg("dns %s -> %s", node, inet_ntoa(fake));
  return 0;
}

static int make_direct_addrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  int family = hints ? hints->ai_family : AF_UNSPEC;
  int port = parse_service_port(service);
  int passive = hints && (hints->ai_flags & AI_PASSIVE);
  const char *name = node && node[0] ? node : NULL;

  struct in_addr a4;
  struct in6_addr a6;

  if (!name || !strcmp(name, "localhost")) {
    if (family == AF_INET6) {
      a6 = passive ? in6addr_any : in6addr_loopback;
      return make_addrinfo_v6(name, &a6, port, hints, res);
    }
    if (family == AF_UNSPEC || family == AF_INET) {
      a4.s_addr = htonl(passive ? INADDR_ANY : INADDR_LOOPBACK);
      return make_addrinfo_v4(name, a4.s_addr, port, hints, res);
    }
    return EAI_NONAME;
  }

  if (inet_pton(AF_INET, name, &a4) == 1) {
    if (family == AF_UNSPEC || family == AF_INET) {
      return make_addrinfo_v4(name, a4.s_addr, port, hints, res);
    }
    return EAI_NONAME;
  }

  if (inet_pton(AF_INET6, name, &a6) == 1) {
    if (family == AF_UNSPEC || family == AF_INET6) {
      return make_addrinfo_v6(name, &a6, port, hints, res);
    }
    return EAI_NONAME;
  }

  return EAI_NONAME;
}

static int set_blocking(int fd, int *old_flags) {
  *old_flags = fcntl(fd, F_GETFL, 0);
  if (*old_flags < 0) {
    return -1;
  }
  if ((*old_flags & O_NONBLOCK) == 0) {
    return 0;
  }
  return fcntl(fd, F_SETFL, *old_flags & ~O_NONBLOCK);
}

static void restore_flags(int fd, int old_flags) {
  if (old_flags >= 0) {
    (void)fcntl(fd, F_SETFL, old_flags);
  }
}

static void set_socket_timeout(int fd) {
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  int yes = 1;
  (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
}

static ssize_t send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t sent = 0;
  while (sent < len) {
    ssize_t n = send(fd, p + sent, len - sent, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    sent += (size_t)n;
  }
  return (ssize_t)sent;
}

static ssize_t recv_all(int fd, void *buf, size_t len) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t n = recv(fd, p + got, len - got, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    got += (size_t)n;
  }
  return (ssize_t)got;
}

static int connect_to_proxy(int fd) {
  struct sockaddr_storage storage;
  memset(&storage, 0, sizeof(storage));

  socklen_t len;
  struct sockaddr_in *sin = (struct sockaddr_in *)&storage;
  struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&storage;

  if (inet_pton(AF_INET, proxy_host, &sin->sin_addr) == 1) {
    sin->sin_family = AF_INET;
    sin->sin_port = htons((uint16_t)proxy_port);
    len = sizeof(*sin);
  } else if (inet_pton(AF_INET6, proxy_host, &sin6->sin6_addr) == 1) {
    sin6->sin6_family = AF_INET6;
    sin6->sin6_port = htons((uint16_t)proxy_port);
    len = sizeof(*sin6);
  } else {
    log_msg("proxy host must be a numeric IP address: %s", proxy_host);
    errno = EINVAL;
    return -1;
  }

  log_msg("connecting to proxy %s:%d", proxy_host, proxy_port);
  if (direct_connect(fd, (struct sockaddr *)&storage, len) == 0) {
    log_msg("connected to proxy");
    return 0;
  }
  return -1;
}

static int socks5_read_reply_tail(int fd, uint8_t atyp) {
  uint8_t skip[256];
  size_t len;

  if (atyp == 0x01) {
    len = 4 + 2;
  } else if (atyp == 0x04) {
    len = 16 + 2;
  } else if (atyp == 0x03) {
    uint8_t name_len;
    if (recv_all(fd, &name_len, 1) != 1) {
      return -1;
    }
    len = (size_t)name_len + 2;
  } else {
    errno = EPROTO;
    return -1;
  }

  return recv_all(fd, skip, len) == (ssize_t)len ? 0 : -1;
}

static int socks5_connect_domain(int fd, const char *host, uint16_t port) {
  size_t host_len = strlen(host);
  if (host_len == 0 || host_len > 255) {
    errno = EINVAL;
    return -1;
  }

  uint8_t hello[] = {0x05, 0x01, 0x00};
  uint8_t hello_reply[2];
  if (send_all(fd, hello, sizeof(hello)) != (ssize_t)sizeof(hello) ||
      recv_all(fd, hello_reply, sizeof(hello_reply)) != (ssize_t)sizeof(hello_reply)) {
    return -1;
  }
  if (hello_reply[0] != 0x05 || hello_reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  uint8_t req[4 + 1 + 255 + 2];
  size_t pos = 0;
  req[pos++] = 0x05;
  req[pos++] = 0x01;
  req[pos++] = 0x00;
  req[pos++] = 0x03;
  req[pos++] = (uint8_t)host_len;
  memcpy(req + pos, host, host_len);
  pos += host_len;
  req[pos++] = (uint8_t)(port >> 8);
  req[pos++] = (uint8_t)(port & 0xff);

  uint8_t reply[4];
  if (send_all(fd, req, pos) != (ssize_t)pos || recv_all(fd, reply, sizeof(reply)) != (ssize_t)sizeof(reply)) {
    return -1;
  }
  if (reply[0] != 0x05 || reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  return socks5_read_reply_tail(fd, reply[3]);
}

static int socks5_connect_ip(int fd, const struct sockaddr *addr) {
  uint16_t port;
  uint8_t req[4 + 16 + 2];
  size_t pos = 0;

  req[pos++] = 0x05;
  req[pos++] = 0x01;
  req[pos++] = 0x00;

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    port = ntohs(sin->sin_port);
    req[pos++] = 0x01;
    memcpy(req + pos, &sin->sin_addr, 4);
    pos += 4;
  } else if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    port = ntohs(sin6->sin6_port);
    req[pos++] = 0x04;
    memcpy(req + pos, &sin6->sin6_addr, 16);
    pos += 16;
  } else {
    errno = EAFNOSUPPORT;
    return -1;
  }

  uint8_t hello[] = {0x05, 0x01, 0x00};
  uint8_t hello_reply[2];
  if (send_all(fd, hello, sizeof(hello)) != (ssize_t)sizeof(hello) ||
      recv_all(fd, hello_reply, sizeof(hello_reply)) != (ssize_t)sizeof(hello_reply)) {
    return -1;
  }
  if (hello_reply[0] != 0x05 || hello_reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  req[pos++] = (uint8_t)(port >> 8);
  req[pos++] = (uint8_t)(port & 0xff);

  uint8_t reply[4];
  if (send_all(fd, req, pos) != (ssize_t)pos || recv_all(fd, reply, sizeof(reply)) != (ssize_t)sizeof(reply)) {
    return -1;
  }
  if (reply[0] != 0x05 || reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  return socks5_read_reply_tail(fd, reply[3]);
}

static int target_is_proxy(const struct sockaddr *addr) {
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    if (ntohs(sin->sin_port) != proxy_port) {
      return 0;
    }
    uint32_t ip = ntohl(sin->sin_addr.s_addr);
    return ip == 0x7F000001u;
  }
  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    static const struct in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
    return ntohs(sin6->sin6_port) == proxy_port && !memcmp(&sin6->sin6_addr, &loopback, sizeof(loopback));
  }
  return 0;
}

static int target_is_loopback(const struct sockaddr *addr) {
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    uint32_t ip = ntohl(sin->sin_addr.s_addr);
    return (ip & 0xFF000000u) == 0x7F000000u;
  }
  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    static const struct in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
    return !memcmp(&sin6->sin6_addr, &loopback, sizeof(loopback));
  }
  return 0;
}

static int socket_is_stream(int fd) {
  int type = 0;
  socklen_t len = sizeof(type);
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) {
    return 0;
  }
  return type == SOCK_STREAM;
}

static int proxy_connect(int fd, const struct sockaddr *addr) {
  int old_flags = -1;
  int saved_errno;
  uint16_t port = 0;
  const char *fake_host = NULL;

  if (!socket_is_stream(fd)) {
    errno = EPROTOTYPE;
    return -1;
  }

  log_msg("connect hook fd=%d family=%d", fd, addr->sa_family);

  if (set_blocking(fd, &old_flags) != 0) {
    return -1;
  }
  set_socket_timeout(fd);

  if (connect_to_proxy(fd) != 0) {
    saved_errno = errno;
    restore_flags(fd, old_flags);
    errno = saved_errno;
    return -1;
  }

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    port = ntohs(sin->sin_port);
    if (is_fake_ip_be(sin->sin_addr.s_addr)) {
      fake_host = lookup_host_by_ip(sin->sin_addr.s_addr);
    }
  }

  int rc;
  if (fake_host) {
    log_msg("connect %s:%u via %s:%d", fake_host, port, proxy_host, proxy_port);
    rc = socks5_connect_domain(fd, fake_host, port);
  } else {
    log_msg("connect ip via %s:%d", proxy_host, proxy_port);
    rc = socks5_connect_ip(fd, addr);
  }

  saved_errno = errno;
  restore_flags(fd, old_flags);
  errno = saved_errno;
  return rc;
}

static int ag_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  load_config();

  if (!addr || (addr->sa_family != AF_INET && addr->sa_family != AF_INET6) || target_is_proxy(addr) || target_is_loopback(addr)) {
    return direct_connect(fd, addr, len);
  }
  if (!socket_is_stream(fd)) {
    return direct_connect(fd, addr, len);
  }

  int rc = proxy_connect(fd, addr);
  if (rc == 0) {
    return 0;
  }

  log_msg("proxy connect failed: %s", strerror(errno));
  return rc;
}

static int ag_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  load_config();

  if (!res) {
    return EAI_FAIL;
  }
  *res = NULL;

  if (!node || !node[0] || is_localhost_name(node) || is_numeric_host(node)) {
    return make_direct_addrinfo(node, service, hints, res);
  }
  if (!strcmp(node, proxy_host)) {
    return make_direct_addrinfo(node, service, hints, res);
  }

  return make_fake_addrinfo(node, service, hints, res);
}

static void ag_freeaddrinfo(struct addrinfo *res) {
  load_config();

  while (res) {
    struct addrinfo *next = res->ai_next;
    free(res->ai_canonname);
    free(res->ai_addr);
    free(res);
    res = next;
  }
}

__attribute__((used)) static struct interpose_entry interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        {(const void *)ag_connect, (const void *)connect},
        {(const void *)ag_getaddrinfo, (const void *)getaddrinfo},
        {(const void *)ag_freeaddrinfo, (const void *)freeaddrinfo},
};
