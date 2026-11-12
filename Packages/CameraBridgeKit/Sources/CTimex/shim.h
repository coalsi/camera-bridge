// Linux's clock state (<sys/timex.h>: adjtimex, the STA_* flags), which Swift's Glibc module does not import: whether the kernel says the
// clock is synchronized, for the NVR's age rule (PlatformLinux's KernelClock).
#include <sys/timex.h>
