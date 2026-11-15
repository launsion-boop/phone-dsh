// SPDX-License-Identifier: MIT
// Test guest: writes a file sequentially, then seeks back and patches it,
// without fsync, the way a linker back-fills its output.
//   fd-patch <path>   ->  "AAbbAAAA" then appended "cc" after seeking to END
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return 3;
  if (write(fd, "AAAAAAAA", 8) != 8) return 4;
  if (lseek(fd, 2, SEEK_SET) != 2) return 5;
  if (write(fd, "bb", 2) != 2) return 6;
  if (lseek(fd, 0, SEEK_END) != 8) return 7;
  if (write(fd, "cc", 2) != 2) return 8;
  if (lseek(fd, 12, SEEK_SET) != 12) return 9;
  if (write(fd, "d", 1) != 1) return 10;
  return close(fd) == 0 ? 0 : 11;
}
