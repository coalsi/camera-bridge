// Linux's epoll API (<sys/epoll.h>), which Swift's Glibc module does not import: the socket reactor of PlatformLinux.
#include <sys/epoll.h>
