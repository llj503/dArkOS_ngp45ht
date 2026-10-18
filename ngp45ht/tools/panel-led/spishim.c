// 截获 ioctl(SPI_IOC_MESSAGE) 里真正发给 spidev 的字节，逆向 ws2812-common 的编码
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/ioctl.h>

static int (*real_ioctl)(int, unsigned long, ...) = 0;

__attribute__((constructor)) static void hello(void)
{
	int lg = open("/tmp/spi.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (lg >= 0) { write(lg, "shim loaded\n", 12); close(lg); }
}

struct xfer {
	uint64_t tx_buf, rx_buf;
	uint32_t len, speed_hz, delay_usecs;
	uint8_t bits_per_word, cs_change, tx_nbits, rx_nbits, word_delay, pad;
};

static void dump(const char *tag, int fd, unsigned long req, void *arg)
{
	int lg = open("/tmp/spi.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (lg < 0) return;
	char hdr[128];
	int L = snprintf(hdr, sizeof hdr, "%s fd=%d req=0x%lx ", tag, fd, req);
	real_ioctl(lg, TIOCGWINSZ, 0);   /* no-op 防止被优化掉 */
	write(lg, hdr, L);
	if ((req & 0xffff) == 0x6b00 /* SPI_IOC_MESSAGE(N) */ && arg) {
		unsigned nmsg = (req >> 16) & 0x3fff;
		if (!nmsg) nmsg = 1;
		for (unsigned mi = 0; mi < nmsg && mi < 4; mi++) {
		struct xfer *x = (struct xfer *)arg + mi;
		char b[256];
		int n = snprintf(b, sizeof b, "len=%u speed=%u bits=%u tx=%llx ",
		                 x->len, x->speed_hz, x->bits_per_word,
		                 (unsigned long long)x->tx_buf);
		write(lg, b, n);
		if (x->tx_buf) {
			const unsigned char *p = (const unsigned char *)(uintptr_t)x->tx_buf;
			static const char *hex = "0123456789abcdef";
			size_t shown = x->len < 48 ? x->len : 48;
			char line[3 * 64];
			for (size_t i = 0; i < shown; i++) {
				line[3*i] = hex[p[i] >> 4];
				line[3*i+1] = hex[p[i] & 15];
				line[3*i+2] = ' ';
			}
			write(lg, line, 3 * shown);
		}
		}
	}
	write(lg, "\n", 1);
	close(lg);
}

int ioctl(int fd, unsigned long req, ...)
{
	if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");
	va_list ap;
	va_start(ap, req);
	void *arg = va_arg(ap, void *);
	va_end(ap);
	if (fd > 2 && (req & 0xffff) == 0x6b00) dump("MSG", fd, req, arg);
	return real_ioctl(fd, req, arg);
}
