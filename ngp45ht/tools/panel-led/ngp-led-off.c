// ngp-led-off.c — 把摇杆灯（WS2812 over SPI0）真正关掉
//
// 背景：`ws2812-common OFF` 只打印 "leds exit.." 然后退出，**根本不写 SPI**，
// 所以灯会保持最后一帧（用户实测"调到关，灯依然亮着"）。
//
// 编码（用 LD_PRELOAD 截 ioctl(SPI_IOC_MESSAGE) 实测出来的）：
//   速度 8 MHz，每个 WS2812 位 = 1 个 SPI 字节
//     0 -> 0xC0  (高 2/8 位)
//     1 -> 0xFC  (高 6/8 位)
//   纯红色的一次传输：c0*8(G=0x00) fc*8(R=0xFF) c0*8(B=0x00) …，总长 192 字节 = 8 颗灯
// 所以"全黑"就是连续写 0xC0。多发一些没有副作用（多余位对应不存在的灯）。
//
// 用法：ngp-led-off [spidev]       默认 /dev/spidev0.0

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/spi/spidev.h>

#define SPEED_HZ 8000000
#define NBYTES   1024          /* 8 颗灯只要 192，多发无害 */

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/spidev0.0";
	int fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror("open spidev");
		return 1;
	}

	uint8_t mode = SPI_MODE_0, bits = 8;
	uint32_t speed = SPEED_HZ;
	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 ||
	    ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
	    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) {
		perror("spidev setup");
		close(fd);
		return 1;
	}

	static uint8_t buf[NBYTES];
	memset(buf, 0xC0, sizeof buf);   /* 0xC0 == WS2812 bit 0 */

	struct spi_ioc_transfer tr;
	memset(&tr, 0, sizeof tr);
	tr.tx_buf = (unsigned long)buf;
	tr.len = sizeof buf;
	tr.speed_hz = SPEED_HZ;
	tr.bits_per_word = 8;
	tr.delay_usecs = 300;            /* 给 WS2812 一个 latch 时间 */

	if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0) {
		perror("spi transfer");
		close(fd);
		return 1;
	}
	close(fd);
	return 0;
}
