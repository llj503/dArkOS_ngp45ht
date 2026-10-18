// ngp_wifi_gui.c — NGP45HT 网络设置（图形版，SDL2 + KMSDRM）
//
// dArkOS 的 ES 里没有 ROCKNIX/AURKNIX 那种内建网络菜单，所以照面板调节的做法
// 自己画一个同风格的界面：
//   WiFi 开关 / 当前连接(SSID + IP) / 附近网络列表(信号 + 是否加密) / SSH 开关
// 连加密网络时弹出屏幕键盘输入密码。
//
// 渲染与输入做法跟 ngp_panel_gui.c 完全一致：SDL2 出图，evdev 读手柄
// （SDLK 键盘也支持，方便远程调试）。
//
// 用法：ngp-wifi-gui            退出码 2 = 拿不到显示（调用方回退到 Wifi.sh 的 dialog 版）

#define _GNU_SOURCE
#include <SDL2/SDL.h>

/* 这台机器只装了 SDL2_ttf 运行库，没有头文件，手写原型 */
typedef struct _TTF_Font TTF_Font;
typedef struct SDL_Surface SDL_Surface;
extern int TTF_Init(void);
extern int TTF_SizeUTF8(TTF_Font *font, const char *text, int *w, int *h);
extern void TTF_Quit(void);
extern TTF_Font *TTF_OpenFont(const char *file, int ptsize);
extern void TTF_CloseFont(TTF_Font *font);
extern SDL_Surface *TTF_RenderUTF8_Blended(TTF_Font *font, const char *text, SDL_Color fg);

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SCR_W 1024
#define SCR_H 768

#define JOYDEV "/dev/input/by-path/platform-play_joystick-event-joystick"
#define FONT_CJK "/usr/bin/emulationstation/resources/DroidSansFallbackFull.ttf"
#define FONT_UI "/usr/bin/emulationstation/resources/OpenSans-CondBold.ttf"

static const SDL_Color C_BG      = { 14, 52, 70, 255 };
static const SDL_Color C_HEADER  = { 9, 38, 52, 255 };
static const SDL_Color C_SEL     = { 41, 168, 216, 255 };
static const SDL_Color C_SEL_TXT = { 255, 255, 255, 255 };
static const SDL_Color C_TEXT    = { 235, 245, 249, 255 };
static const SDL_Color C_DIM     = { 150, 180, 194, 255 };
static const SDL_Color C_OK      = { 120, 220, 160, 255 };
static const SDL_Color C_WARN    = { 240, 180, 120, 255 };
static const SDL_Color C_BARDIM  = { 30, 74, 94, 255 };

#define MAX_AP 24

typedef struct {
	char ssid[80];
	int signal;
	int sec;
} AP;

static AP g_ap[MAX_AP];
static int g_nap = 0;
static int g_wifi_on = 1;
static int g_ssh_on = 0;
static char g_cur_ssid[80] = "";
static char g_cur_ip[48] = "";

/* 可选行：0 = WiFi 开关；1..n = AP；n+1 = SSH 开关 */
static int g_sel = 0;          /* 行号 */
static int g_top = 0;          /* 列表滚动起点 */
static char g_status[128] = "";

/* 键盘模式 */
static int g_kbd = 0;
static char g_pw[80] = "";
static int g_pw_len = 0;
static int g_kbd_x = 0, g_kbd_y = 0;
static int g_shift = 0;
static char g_target_ssid[80] = "";

static const char *KB_ROWS[5] = {
	"1234567890",
	"qwertyuiop",
	"asdfghjkl-",
	"zxcvbnm._",
	"@#$%&*+=",
};
#define KB_NROW 5
#define KB_LASTROW 5   /* 动作行 */

/* ---------- 执行命令 ---------- */
static void run_wait(char *const argv[])
{
	pid_t p = fork();
	if (p == 0) {
		int dn = open("/dev/null", O_WRONLY);
		if (dn >= 0) { dup2(dn, 1); }
		execvp(argv[0], argv);
		_exit(127);
	}
	if (p > 0) waitpid(p, NULL, 0);
}

/* 取一行命令输出（不带换行） */
static void run_capture(const char *cmd, char *out, size_t n)
{
	out[0] = 0;
	FILE *f = popen(cmd, "r");
	if (!f) return;
	size_t k = 0;
	int c;
	while ((c = fgetc(f)) != EOF && k + 1 < n) {
		if (c == '\n') break;
		out[k++] = (char)c;
	}
	out[k] = 0;
	pclose(f);
	while (k && (out[k-1] == '\n' || out[k-1] == '\r' || out[k-1] == ' ')) out[--k] = 0;
}

/* ---------- 数据读取 ---------- */
static void refresh_status(void)
{
	char buf[256];

	run_capture("LC_ALL=C nmcli -t -f WIFI g 2>/dev/null", buf, sizeof buf);
	g_wifi_on = (strncmp(buf, "enabled", 7) == 0);

	run_capture("LC_ALL=C systemctl is-enabled ssh 2>/dev/null", buf, sizeof buf);
	g_ssh_on = (strncmp(buf, "enabled", 7) == 0);

	g_cur_ssid[0] = g_cur_ip[0] = 0;
	/* 不要用 --separator（这版 nmcli 不认）；SSID 里可能有 ':'，
	   所以用 sed 剥掉结尾的 ":wlan0" 比按字段切更稳 */
	run_capture("LC_ALL=C nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | "
	            "sed -n 's/:wlan0$//p' | head -1", buf, sizeof buf);
	snprintf(g_cur_ssid, sizeof g_cur_ssid, "%s", buf);

	run_capture("ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1", buf, sizeof buf);
	snprintf(g_cur_ip, sizeof g_cur_ip, "%s", buf);
}

static void scan_aps(void)
{
	snprintf(g_status, sizeof g_status, "正在扫描…");
	g_nap = 0;
	/* 这台机器的 nmcli 不认 --separator，而且 SSID 里的 ':' 会被转义成 "\:"，
	   所以从右侧解析：最后一个 ':' 后面是 SECURITY，倒数第二个是 SIGNAL，剩下是 SSID。 */
	FILE *f = popen("LC_ALL=C nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan yes 2>/dev/null",
	                "r");
	if (!f) { snprintf(g_status, sizeof g_status, "nmcli 调用失败"); return; }
	char line[512];
	char seen[MAX_AP][80];
	int nseen = 0;
	while (fgets(line, sizeof line, f) && g_nap < MAX_AP) {
		char *nl = strchr(line, '\n');
		if (nl) *nl = 0;
		if (!line[0]) continue;
		char *last = strrchr(line, ':');
		if (!last) continue;
		*last = 0;
		char *prev = strrchr(line, ':');
		if (!prev) continue;
		*prev = 0;
		int sig = atoi(prev + 1);
		int sec = (last[1] && strcmp(last + 1, "--") != 0);

		/* 反转义 SSID 里的 \: 等 */
		char ssid[80];
		int j = 0;
		for (int i = 0; line[i] && j < (int)sizeof ssid - 1; i++) {
			if (line[i] == '\\' && line[i + 1]) ssid[j++] = line[++i];
			else ssid[j++] = line[i];
		}
		ssid[j] = 0;
		if (!ssid[0]) continue;          /* 隐藏网络 */

		int dup = 0;
		for (int i = 0; i < nseen; i++)
			if (strcmp(seen[i], ssid) == 0) { dup = 1; break; }
		if (dup) continue;
		snprintf(seen[nseen++], sizeof seen[0], "%s", ssid);
		snprintf(g_ap[g_nap].ssid, sizeof g_ap[0].ssid, "%s", ssid);
		g_ap[g_nap].signal = sig;
		g_ap[g_nap].sec = sec;
		g_nap++;
	}
	pclose(f);
	snprintf(g_status, sizeof g_status, g_nap ? "" : "没扫到网络");
}

static int row_count(void) { return g_nap + 2; }

static int is_wifi_row(int r) { return r == 0; }
static int is_ssh_row(int r) { return r == row_count() - 1; }

/* ---------- 动作 ---------- */
static void do_wifi_toggle(void)
{
	if (g_wifi_on) {
		char *a[] = { "sudo", "nmcli", "radio", "wifi", "off", NULL };
		run_wait(a);
	} else {
		char *a[] = { "sudo", "nmcli", "radio", "wifi", "on", NULL };
		run_wait(a);
	}
	refresh_status();
}

static void do_ssh_toggle(void)
{
	if (g_ssh_on) {
		char *a[] = { "sudo", "systemctl", "disable", "--now", "ssh.service", NULL };
		run_wait(a);
	} else {
		char *a[] = { "sudo", "systemctl", "enable", "--now", "ssh.service", NULL };
		run_wait(a);
	}
	refresh_status();
}

static void connect_ssid(const char *ssid, const char *pw)
{
	char b[64];
	if (pw && pw[0]) {
		char *a[] = { "sudo", "nmcli", "dev", "wifi", "connect", (char *)ssid,
		              "password", (char *)pw, NULL };
		run_wait(a);
	} else {
		char *a[] = { "sudo", "nmcli", "dev", "wifi", "connect", (char *)ssid, NULL };
		run_wait(a);
	}
	(void)b;
	refresh_status();
	snprintf(g_status, sizeof g_status,
	         g_cur_ssid[0] ? "已连接" : "连接失败（密码或信号？）");
}

/* ---------- 文本（CJK + 拉丁 分段） ---------- */
static int is_cjk(unsigned cp) { return cp >= 0x2E80; }

static const char *utf8_next(const char *s, unsigned *cp)
{
	const unsigned char *u = (const unsigned char *)s;
	if (u[0] < 0x80) { *cp = u[0]; return s + 1; }
	if ((u[0] & 0xE0) == 0xC0 && u[1]) { *cp = ((u[0] & 0x1F) << 6) | (u[1] & 0x3F); return s + 2; }
	if ((u[0] & 0xF0) == 0xE0 && u[1] && u[2]) {
		*cp = ((u[0] & 0x0F) << 12) | ((u[1] & 0x3F) << 6) | (u[2] & 0x3F); return s + 3;
	}
	if ((u[0] & 0xF8) == 0xF0 && u[1] && u[2] && u[3]) {
		*cp = ((u[0] & 0x07) << 18) | ((u[1] & 0x3F) << 12) | ((u[2] & 0x3F) << 6) | (u[3] & 0x3F);
		return s + 4;
	}
	*cp = u[0];
	return s + 1;
}

static void text_mixed(SDL_Renderer *r, TTF_Font *fCJK, TTF_Font *fLat,
                       const char *s, int x, int y, SDL_Color c, int centered)
{
	int total = 0;
	for (const char *q = s; *q; ) {
		unsigned cp; const char *run = q;
		q = utf8_next(q, &cp);
		int cjk = is_cjk(cp);
		const char *end = q;
		while (*end) { unsigned c2; const char *nx = utf8_next(end, &c2); if (is_cjk(c2) != cjk) break; end = nx; }
		char buf[512]; size_t n = (size_t)(end - run);
		if (n >= sizeof buf) n = sizeof buf - 1;
		memcpy(buf, run, n); buf[n] = 0;
		int w = 0, h = 0;
		TTF_SizeUTF8(cjk ? fCJK : fLat, buf, &w, &h);
		total += w;
		q = end;
	}
	int px = centered ? x - total / 2 : x;
	for (const char *q = s; *q; ) {
		unsigned cp; const char *run = q;
		q = utf8_next(q, &cp);
		int cjk = is_cjk(cp);
		const char *end = q;
		while (*end) { unsigned c2; const char *nx = utf8_next(end, &c2); if (is_cjk(c2) != cjk) break; end = nx; }
		char buf[512]; size_t n = (size_t)(end - run);
		if (n >= sizeof buf) n = sizeof buf - 1;
		memcpy(buf, run, n); buf[n] = 0;
		SDL_Surface *sf = TTF_RenderUTF8_Blended(cjk ? fCJK : fLat, buf, c);
		if (sf) {
			SDL_Texture *tx = SDL_CreateTextureFromSurface(r, sf);
			if (tx) {
				SDL_Rect dst = { px, y, sf->w, sf->h };
				SDL_RenderCopy(r, tx, NULL, &dst);
				SDL_DestroyTexture(tx);
			}
			px += sf->w;
			SDL_FreeSurface(sf);
		}
		q = end;
	}
}

static void fill(SDL_Renderer *r, int x, int y, int w, int h, SDL_Color c)
{
	SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
	SDL_Rect rc = { x, y, w, h };
	SDL_RenderFillRect(r, &rc);
}

/* ---------- 绘制：列表 ---------- */
#define ROW_H 58
#define LIST_Y 210
#define LIST_ROWS 7

static void draw_list(SDL_Renderer *r, TTF_Font *fT, TTF_Font *fR, TTF_Font *fLat)
{
	fill(r, 0, 0, SCR_W, SCR_H, C_BG);
	fill(r, 0, 0, SCR_W, 92, C_HEADER);
	text_mixed(r, fT, fLat, "网络设置", SCR_W / 2, 26, C_TEXT, 1);

	char buf[256];

	/* 第一行：WiFi 开关 */
	{
		int sel = (g_sel == 0);
		if (sel) fill(r, 90, 118, SCR_W - 180, ROW_H - 8, C_SEL);
		SDL_Color fg = sel ? C_SEL_TXT : C_TEXT;
		text_mixed(r, fR, fLat, "WiFi", 118, 132, fg, 0);
		snprintf(buf, sizeof buf, g_wifi_on ? "< 开 >" : "< 关 >");
		text_mixed(r, fR, fLat, buf, 360, 132, g_wifi_on ? (sel ? C_SEL_TXT : C_OK)
		                                                : (sel ? C_SEL_TXT : C_WARN), 0);
		if (g_cur_ssid[0]) {
			snprintf(buf, sizeof buf, "%s  %s", g_cur_ssid, g_cur_ip);
		} else {
			snprintf(buf, sizeof buf, "未连接");
		}
		text_mixed(r, fR, fLat, buf, 560, 132, sel ? C_SEL_TXT : C_DIM, 0);
	}

	/* 中间：AP 列表 */
	fill(r, 90, 186, SCR_W - 180, 2, C_DIM);
	text_mixed(r, fR, fLat, "可用网络", 118, 196, C_DIM, 0);
	if (g_status[0]) text_mixed(r, fR, fLat, g_status, 300, 196, C_WARN, 0);

	for (int i = 0; i < LIST_ROWS; i++) {
		int idx = g_top + i;
		if (idx >= g_nap) break;
		int y = LIST_Y + i * ROW_H;
		int sel = (g_sel == idx + 1);
		if (sel) fill(r, 90, y, SCR_W - 180, ROW_H - 8, C_SEL);
		SDL_Color fg = sel ? C_SEL_TXT : C_TEXT;

		snprintf(buf, sizeof buf, "%s", g_ap[idx].ssid);
		text_mixed(r, fR, fLat, buf, 118, y + 12, fg, 0);

		/* 信号格 */
		int bars = (g_ap[idx].signal + 20) / 25;
		if (bars > 4) bars = 4;
		for (int b = 0; b < 4; b++) {
			int bh = 6 + b * 5;
			fill(r, 700 + b * 12, y + 32 - bh, 8, bh,
			     (b < bars) ? (sel ? C_SEL_TXT : C_OK) : C_BARDIM);
		}
		snprintf(buf, sizeof buf, "%d", g_ap[idx].signal);
		text_mixed(r, fR, fLat, buf, 760, y + 12, sel ? C_SEL_TXT : C_DIM, 0);

		text_mixed(r, fR, fLat, g_ap[idx].sec ? "锁" : "开",
		           820, y + 12, sel ? C_SEL_TXT : C_DIM, 0);
		if (g_cur_ssid[0] && strcmp(g_cur_ssid, g_ap[idx].ssid) == 0)
			text_mixed(r, fR, fLat, "已连接", 870, y + 12, sel ? C_SEL_TXT : C_OK, 0);
	}

	/* 最后一行：SSH —— 紧跟在可用网络后面，而不是固定在第 LIST_ROWS 行
	   （没扫到网络时旧位置会掉到页脚外面去） */
	{
		int shown = g_nap < LIST_ROWS ? g_nap : LIST_ROWS;
		int y = LIST_Y + shown * ROW_H + 10;
		int sel = (g_sel == row_count() - 1);
		if (sel) fill(r, 90, y, SCR_W - 180, ROW_H - 8, C_SEL);
		SDL_Color fg = sel ? C_SEL_TXT : C_TEXT;
		text_mixed(r, fR, fLat, "SSH", 118, y + 14, fg, 0);
		snprintf(buf, sizeof buf, g_ssh_on ? "< 开 >" : "< 关 >");
		text_mixed(r, fR, fLat, buf, 360, y + 14,
		           g_ssh_on ? (sel ? C_SEL_TXT : C_OK) : (sel ? C_SEL_TXT : C_WARN), 0);
	}

	/* 底部提示 */
	int hy = SCR_H - 66;
	fill(r, 0, hy, SCR_W, 66, C_HEADER);
	text_mixed(r, fR, fLat, "上下=选择   左右=开关   A=连接/重扫   B=退出",
	           SCR_W / 2, hy + 18, C_DIM, 1);
}

/* ---------- 绘制：键盘 ---------- */
static void draw_kbd(SDL_Renderer *r, TTF_Font *fT, TTF_Font *fR, TTF_Font *fLat)
{
	fill(r, 0, 0, SCR_W, SCR_H, C_BG);
	fill(r, 0, 0, SCR_W, 92, C_HEADER);
	char t[160];
	snprintf(t, sizeof t, "输入密码：%s", g_target_ssid);
	text_mixed(r, fT, fLat, t, SCR_W / 2, 26, C_TEXT, 1);

	/* 已输入 */
	fill(r, 120, 110, SCR_W - 240, 64, C_HEADER);
	char dots[96];
	int dn = g_pw_len < (int)sizeof(dots) - 1 ? g_pw_len : (int)sizeof(dots) - 1;
	memset(dots, '*', dn);
	dots[dn] = 0;
	text_mixed(r, fR, fLat, dots, 140, 124, C_TEXT, 0);

	/* 键盘网格 */
	int kx0 = 120, ky0 = 200, cw = 76, chh = 66, gap = 6;
	for (int y = 0; y < KB_NROW; y++) {
		const char *row = KB_ROWS[y];
		int n = (int)strlen(row);
		for (int x = 0; x < n; x++) {
			int px = kx0 + x * (cw + gap), py = ky0 + y * (chh + gap);
			int sel = (g_kbd_y == y && g_kbd_x == x);
			fill(r, px, py, cw, chh, sel ? C_SEL : C_HEADER);
			char k[2] = { row[x], 0 };
			if (g_shift && k[0] >= 'a' && k[0] <= 'z') k[0] = (char)(k[0] - 32);
			text_mixed(r, fR, fLat, k, px + cw / 2, py + 16,
			           sel ? C_SEL_TXT : C_TEXT, 1);
		}
	}
	/* 动作行 */
	{
		int py = ky0 + KB_NROW * (chh + gap) + 10;
		const char *labels[3] = { "大写", "删除", "完成" };
		for (int i = 0; i < 3; i++) {
			int px = kx0 + i * 240;
			int sel = (g_kbd_y == KB_LASTROW && g_kbd_x == i);
			fill(r, px, py, 220, chh, sel ? C_SEL : C_HEADER);
			text_mixed(r, fR, fLat, labels[i], px + 110, py + 16,
			           sel ? C_SEL_TXT : C_TEXT, 1);
		}
	}

	int hy = SCR_H - 66;
	fill(r, 0, hy, SCR_W, 66, C_HEADER);
	text_mixed(r, fR, fLat, "A=输入   B=退格   START=完成   SELECT=取消",
	           SCR_W / 2, hy + 18, C_DIM, 1);
}

/* ---------- 输入 ---------- */
static int open_joy(void) { return open(JOYDEV, O_RDONLY | O_NONBLOCK); }

static void kbd_key_insert(char c)
{
	if (g_pw_len + 1 < (int)sizeof g_pw) {
		g_pw[g_pw_len++] = c;
		g_pw[g_pw_len] = 0;
	}
}

static void kbd_press(void)
{
	if (g_kbd_y == KB_LASTROW) {
		if (g_kbd_x == 0) g_shift = !g_shift;
		else if (g_kbd_x == 1) { if (g_pw_len) g_pw[--g_pw_len] = 0; }
		else g_kbd = 2;       /* 完成 */
		return;
	}
	const char *row = KB_ROWS[g_kbd_y];
	int n = (int)strlen(row);
	if (g_kbd_x < n) {
		char c = row[g_kbd_x];
		if (g_shift && c >= 'a' && c <= 'z') c = (char)(c - 32);
		kbd_key_insert(c);
	}
}

static void kbd_move(int dx, int dy)
{
	if (dy == 0) {
		int n = (g_kbd_y == KB_LASTROW) ? 3 : (int)strlen(KB_ROWS[g_kbd_y]);
		g_kbd_x = (g_kbd_x + dx + n) % n;
	} else {
		if (g_kbd_y == KB_LASTROW && dy > 0) g_kbd_y = 0;
		else if (g_kbd_y == 0 && dy < 0) g_kbd_y = KB_LASTROW;
		else g_kbd_y += dy;
		int n = (g_kbd_y == KB_LASTROW) ? 3 : (int)strlen(KB_ROWS[g_kbd_y]);
		if (g_kbd_x >= n) g_kbd_x = n - 1;
	}
}

int main(int argc, char **argv)
{
	(void)argc; (void)argv;

	SDL_SetHint(SDL_HINT_VIDEODRIVER, "KMSDRM");
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 2;
	}
	if (TTF_Init() != 0) { SDL_Quit(); return 2; }

	SDL_Window *win = SDL_CreateWindow("ngp-wifi", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
	                                   SCR_W, SCR_H, SDL_WINDOW_SHOWN);
	if (!win) return 2;
	SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
	if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	if (!ren) return 2;

	TTF_Font *fT = TTF_OpenFont(FONT_CJK, 40);
	TTF_Font *fR = TTF_OpenFont(FONT_CJK, 28);
	TTF_Font *fLat = TTF_OpenFont(FONT_UI, 28);
	if (!fT || !fR || !fLat) return 2;
	SDL_ShowCursor(SDL_DISABLE);

	refresh_status();
	scan_aps();

	int jfd = open_joy();
	int running = 1;
	double ax = 0, ay = 0;
	double hl = 0, hr = 0, hu = 0, hd = 0;
	const double DEAD = 0.55, REP = 0.10, NAV = 0.25;
	struct timespec last; clock_gettime(CLOCK_MONOTONIC, &last);

	while (running) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT) running = 0;
			else if (e.type == SDL_KEYDOWN) {
				int k = e.key.keysym.sym;
				if (g_kbd == 1) {
					if (k == SDLK_ESCAPE) { g_kbd = 0; }
					else if (k == SDLK_BACKSPACE) { if (g_pw_len) g_pw[--g_pw_len] = 0; }
					else if (k == SDLK_RETURN) { g_kbd = 2; }
					else if (k >= 32 && k < 127) kbd_key_insert((char)k);
					else if (k == SDLK_LEFT) kbd_move(-1, 0);
					else if (k == SDLK_RIGHT) kbd_move(1, 0);
					else if (k == SDLK_UP) kbd_move(0, -1);
					else if (k == SDLK_DOWN) kbd_move(0, 1);
					else if (k == SDLK_SPACE) kbd_press();
				} else {
					if (k == SDLK_ESCAPE) running = 0;
					else if (k == SDLK_UP) { g_sel = (g_sel + row_count() - 1) % row_count(); }
					else if (k == SDLK_DOWN) { g_sel = (g_sel + 1) % row_count(); }
					else if (k == SDLK_LEFT || k == SDLK_RIGHT) {
						if (is_wifi_row(g_sel)) do_wifi_toggle();
						else if (is_ssh_row(g_sel)) do_ssh_toggle();
					} else if (k == SDLK_RETURN || k == SDLK_SPACE) {
						if (is_wifi_row(g_sel)) do_wifi_toggle();
						else if (is_ssh_row(g_sel)) do_ssh_toggle();
						else if (g_sel >= 1 && g_sel <= g_nap) {
							int i = g_sel - 1;
							if (g_ap[i].sec) {
								snprintf(g_target_ssid, sizeof g_target_ssid, "%s", g_ap[i].ssid);
								g_pw[0] = 0; g_pw_len = 0; g_kbd = 1;
								g_kbd_x = g_kbd_y = 0; g_shift = 0;
							} else connect_ssid(g_ap[i].ssid, "");
						}
					} else if (k == SDLK_r) { scan_aps(); }
				}
			}
		}

		if (jfd >= 0) {
			fd_set rf; struct timeval tv = { 0, 0 };
			FD_ZERO(&rf); FD_SET(jfd, &rf);
			if (select(jfd + 1, &rf, NULL, NULL, &tv) > 0) {
				struct input_event ev;
				while (read(jfd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
					if (ev.type == EV_ABS && ev.code == ABS_X) ax = ev.value / 32767.0;
					else if (ev.type == EV_ABS && ev.code == ABS_Y) ay = ev.value / 32767.0;
					else if (ev.type == EV_KEY && ev.value == 1) {
						int up = (ev.code == BTN_DPAD_UP), dn = (ev.code == BTN_DPAD_DOWN);
						int lf = (ev.code == BTN_DPAD_LEFT), rt = (ev.code == BTN_DPAD_RIGHT);
						if (ev.code == BTN_SOUTH) running = 0;              /* B = 退出 */
						else if (g_kbd == 1) {
							if (ev.code == BTN_EAST) kbd_press();            /* A = 输入 */
							else if (ev.code == BTN_C) { if (g_pw_len) g_pw[--g_pw_len] = 0; }   /* X = 退格 */
							else if (ev.code == BTN_START) g_kbd = 2;        /* START = 完成 */
							else if (ev.code == BTN_SELECT) g_kbd = 0;       /* SELECT = 取消 */
							else if (up) kbd_move(0, -1);
							else if (dn) kbd_move(0, 1);
							else if (lf) kbd_move(-1, 0);
							else if (rt) kbd_move(1, 0);
						} else {
							if (up) g_sel = (g_sel + row_count() - 1) % row_count();
							else if (dn) g_sel = (g_sel + 1) % row_count();
							else if (lf || rt) {
								if (is_wifi_row(g_sel)) do_wifi_toggle();
								else if (is_ssh_row(g_sel)) do_ssh_toggle();
							} else if (ev.code == BTN_EAST) {                 /* A */
								if (is_wifi_row(g_sel)) { do_wifi_toggle(); scan_aps(); }
								else if (is_ssh_row(g_sel)) do_ssh_toggle();
								else if (g_sel >= 1 && g_sel <= g_nap) {
									int i = g_sel - 1;
									if (g_ap[i].sec) {
										snprintf(g_target_ssid, sizeof g_target_ssid, "%s", g_ap[i].ssid);
										g_pw[0] = 0; g_pw_len = 0; g_kbd = 1;
										g_kbd_x = g_kbd_y = 0; g_shift = 0;
									} else connect_ssid(g_ap[i].ssid, "");
								}
							} else if (ev.code == BTN_NORTH) scan_aps();
						}
					}
				}
			}
		}

		/* 摇杆 */
		struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
		double dt = (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) / 1e9;
		last = now;
		for (int s = -1; s <= 1; s += 2) {
			int act = (s < 0) ? (ay < -DEAD) : (ay > DEAD);
			double *h = (s < 0) ? &hu : &hd;
			if (act) {
				if (*h == 0) {
					if (g_kbd == 1) kbd_move(0, s);
					else g_sel = (g_sel + (s < 0 ? row_count() - 1 : 1)) % row_count();
					*h = 1e-4;
				} else { *h += dt; if (*h > NAV) { 
					if (g_kbd == 1) kbd_move(0, s);
					else g_sel = (g_sel + (s < 0 ? row_count() - 1 : 1)) % row_count();
					*h = 1e-4; } }
			} else *h = 0;
			int act2 = (s < 0) ? (ax < -DEAD) : (ax > DEAD);
			double *h2 = (s < 0) ? &hl : &hr;
			if (act2) {
				if (*h2 == 0) {
					if (g_kbd == 1) kbd_move(s, 0);
					else if (is_wifi_row(g_sel)) do_wifi_toggle();
					else if (is_ssh_row(g_sel)) do_ssh_toggle();
					*h2 = 1e-4;
				} else { *h2 += dt; if (*h2 > REP) { *h2 = 1e-4; } }
			} else *h2 = 0;
		}

		/* 列表滚动跟随 */
		if (g_sel >= 1 && g_sel <= g_nap) {
			int idx = g_sel - 1;
			if (idx < g_top) g_top = idx;
			if (idx >= g_top + LIST_ROWS) g_top = idx - LIST_ROWS + 1;
		}

		if (g_kbd == 2) {
			/* 完成：连接 */
			g_kbd = 0;
			connect_ssid(g_target_ssid, g_pw);
		}

		if (g_kbd == 1) draw_kbd(ren, fT, fR, fLat);
		else draw_list(ren, fT, fR, fLat);
		SDL_RenderPresent(ren);
		SDL_Delay(16);
	}

	if (jfd >= 0) close(jfd);
	TTF_CloseFont(fT); TTF_CloseFont(fR); TTF_CloseFont(fLat);
	SDL_DestroyRenderer(ren);
	SDL_DestroyWindow(win);
	TTF_Quit();
	SDL_Quit();
	return 0;
}
