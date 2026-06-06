#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *host = argc > 1 ? argv[1] : "example.com";
  const char *port = argc > 2 ? argv[2] : "443";

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *res = NULL;
  int rc = getaddrinfo(host, port, &hints, &res);
  if (rc != 0) {
    fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(rc));
    return 2;
  }

  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0) {
    perror("socket");
    freeaddrinfo(res);
    return 3;
  }

  if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
    fprintf(stderr, "connect: %s\n", strerror(errno));
    close(fd);
    freeaddrinfo(res);
    return 4;
  }

  puts("connected");
  close(fd);
  freeaddrinfo(res);
  return 0;
}
