#include <asm/termbits.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

int main(void)
{
    int fd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (fd < 0) {
        fprintf(stderr, "open /dev/ptmx failed: %s\n", strerror(errno));
        return 1;
    }

    struct termios2 tio;
    memset(&tio, 0, sizeof(tio));
    errno = 0;
    int rc = ioctl(fd, TCGETS2, &tio);
    int saved_errno = errno;
    close(fd);

    if (rc == 0) {
        printf("TCGETS2 ioctl: rc=0, c_ispeed=%u c_ospeed=%u\n",
               tio.c_ispeed, tio.c_ospeed);
        printf("SUCCESS: TCGETS2 emulated (rc=0)\n");
        return 0;
    }

    printf("TCGETS2 ioctl: rc=%d errno=%d (%s)\n", rc, saved_errno, strerror(saved_errno));
    printf("FAILURE: TCGETS2 not emulated (rc=%d, errno=%d)\n", rc, saved_errno);
    return 1;
}
