// ngp_panel_gui.c — NGP45HT 面板与灯光调节（图形版，SDL2 + KMSDRM）
//
// 为什么不进 ES 菜单：dArkOS 的 ES 是 ArkOS fork，二进制里没有任何
// paneladj / ledcontrol / GuiAnalogSticksLedControls 的菜单实现（0 处匹配），
// 所以「在 ES 里长得一样」只能换 ES 二进制。折中方案是自己用 SDL2 画一个
// 同款界面：同样的深色底、青色选中条、同一套字体（ES 资源里的 DroidSans +
// OpenSans），视觉上和 ES 的菜单几乎一致。
//
// 渲染：SDL2（KMSDRM 驱动，直接吃 /dev/dri/card0）。
// 输入：直接读 evdev（/dev/input/by-path/platform-play_joystick-event-joystick），
//       因为 SDL 的 joystick 映射表里没有这台机器的 GUID，键值会对不上。
//
// 用法：
//   ngp_panel_gui [--only brightness|contrast|saturation|hue|led|stick]
//
// 退出码：0 正常；2 SDL 初始化失败（调用方应回退到 panelui.py 文本界面）。

#define _GNU_SOURCE
#include <SDL2/SDL.h>
/* 这台机器只装了 SDL2_ttf 的运行库，没有 SDL2/SDL_ttf.h（ES 自己也是 dlopen 用的）。
   所以这里手写原型，编译时直接链 libSDL2_ttf-2.0.so.0。 */
typedef struct _TTF_Font TTF_Font;
extern int TTF_Init(void);
extern int TTF_SizeUTF8(TTF_Font *font, const char *text, int *w, int *h);
extern void TTF_Quit(void);
extern TTF_Font *TTF_OpenFont(const char *file, int ptsize);
extern void TTF_CloseFont(TTF_Font *font);
extern SDL_Surface *TTF_RenderUTF8_Blended(TTF_Font *font, const char *text, SDL_Color fg);
/* 这个版本的 libSDL2_ttf 不导出 TTF_GetError（老版本是宏），所以统一用 SDL_GetError() */

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <math.h>
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

#define CONF "/opt/ngp-panel/panel.conf"
#define LEDCONF "/opt/ngp-panel/led.conf"
#define PANELADJ "/opt/ngp-panel/paneladj.sh"
#define LEDCTL "/usr/bin/ledcontrol"
#define STICKCTL "/usr/bin/analog_sticks_ledcontrol_single"
#define JOYDEV "/dev/input/by-path/platform-play_joystick-event-joystick"

#define FONT_CJK "/usr/bin/emulationstation/resources/DroidSansFallbackFull.ttf"
#define FONT_UI "/usr/bin/emulationstation/resources/OpenSans-CondBold.ttf"

/* 配色取自 es-theme-minimal-arkos 的实际像素 */
static const SDL_Color C_BG      = { 14, 52, 70, 255 };
static const SDL_Color C_HEADER  = { 9, 38, 52, 255 };
static const SDL_Color C_SEL     = { 41, 168, 216, 255 };
static const SDL_Color C_SEL_TXT = { 255, 255, 255, 255 };
static const SDL_Color C_TEXT    = { 235, 245, 249, 255 };
static const SDL_Color C_DIM     = { 150, 180, 194, 255 };
static const SDL_Color C_BARBG   = { 30, 74, 94, 255 };
static const SDL_Color C_BARFG   = { 41, 168, 216, 255 };

typedef struct {
	const char *key;      /* panel.conf / 命令用的键 */
	const char *title;    /* 显示名 */
	int kind;             /* 0=数值 1=状态灯 2=摇杆灯 */
} Item;

static const Item ITEMS[] = {
	{ "brightness", "亮度",   0 },
	{ "contrast",   "对比度", 0 },
	{ "saturation", "饱和度", 0 },
	{ "hue",        "色相",   0 },
	{ "led",        "状态灯", 1 },
	{ "stick",      "摇杆灯", 2 },
};
#define N_ITEM ((int)(sizeof(ITEMS) / sizeof(ITEMS[0])))

static const char *LED_COLORS[] = { "off", "red", "blue", "purple" };
static const char *LED_LABELS[] = { "关", "红", "蓝", "紫" };

static const char *STICK_MODES[] = {
	"OFF", "Scrolling", "Breathing", "Breathing_Red", "Breathing_Green",
	"Breathing_Blue", "Breathing_Blue_Red", "Breathing_Green_Blue",
	"Breathing_Red_Green", "Breathing_Red_Green_Blue", "Red_Green_Blue",
	"Blue_Red", "Blue", "Green_Blue", "Green", "Red_Green", "Red",
};
static const char *STICK_LABELS[] = {
	"关", "流水", "呼吸", "呼吸红", "呼吸绿", "呼吸蓝", "呼吸蓝红",
	"呼吸绿蓝", "呼吸红绿", "呼吸三色", "三色循环", "蓝红", "蓝", "绿蓝",
	"绿", "红绿", "红",
};
#define N_LED 4
#define N_STICK ((int)(sizeof(STICK_MODES) / sizeof(STICK_MODES[0])))

static int g_val[4] = { 50, 50, 50, 50 };   /* brightness/contrast/sat/hue */
static int g_led = 2;                        /* index into LED_COLORS */
static int g_stick = 0;
static int g_sel = 0;
static int g_only = -1;                      /* -1 = 全部项目 */

static int prop_min(int i) { return i == 0 ? 5 : 0; }   /* 亮度下限 5 */

/* ---------- 配置读写 ---------- */
static int conf_geti(const char *key, int def)
{
	FILE *f = fopen(CONF, "r");
	char line[256];
	int v = def;
	if (!f) return def;
	while (fgets(line, sizeof line, f)) {
		char *eq = strchr(line, '=');
		if (!eq) continue;
		*eq = 0;
		if (strcmp(line, key) == 0) {
			v = atoi(eq + 1);
			break;
		}
	}
	fclose(f);
	return v;
}

static void conf_gets_from(const char *path, const char *key, char *out, size_t n, const char *def)
{
	FILE *f = fopen(path, "r");
	char line[256];
	snprintf(out, n, "%s", def);
	if (!f) return;
	while (fgets(line, sizeof line, f)) {
		char *eq = strchr(line, '=');
		if (!eq) continue;
		*eq = 0;
		if (strcmp(line, key) == 0) {
			char *v = eq + 1;
			size_t L = strlen(v);
			while (L && (v[L-1] == '\n' || v[L-1] == '\r')) v[--L] = 0;
			snprintf(out, n, "%s", v);
			break;
		}
	}
	fclose(f);
}

static void load_conf(void)
{
	for (int i = 0; i < 4; i++) {
		int v = conf_geti(ITEMS[i].key, 50);
		if (v < prop_min(i)) v = prop_min(i);
		if (v > 100) v = 100;
		g_val[i] = v;
	}
	{
		char buf[64];
		conf_gets_from(LEDCONF, "led_color", buf, sizeof buf, "blue");
		for (int i = 0; i < N_LED; i++)
			if (strcmp(buf, LED_COLORS[i]) == 0) g_led = i;
		conf_gets_from(LEDCONF, "stick_mode", buf, sizeof buf, "OFF");
		for (int i = 0; i < N_STICK; i++)
			if (strcmp(buf, STICK_MODES[i]) == 0) g_stick = i;
	}
}

/* ---------- 执行外部命令（不等待，避免界面卡顿） ---------- */
static void run_async(char *const argv[])
{
	pid_t pid = fork();
	if (pid == 0) {
		int dn = open("/dev/null", O_WRONLY);
		if (dn >= 0) { dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); }
		execvp(argv[0], argv);
		_exit(127);
	}
	/* 不 wait，交给 init 收尸；父进程继续渲染 */
}

static void apply_item(int idx)
{
	char v[16];
	switch (idx) {
	case 0: case 1: case 2: case 3: {
		snprintf(v, sizeof v, "%d", g_val[idx]);
		char *argv[] = { (char *)PANELADJ, (char *)ITEMS[idx].key, v, NULL };
		run_async(argv);
		break;
	}
	case 4: {
		char *argv[] = { (char *)LEDCTL, (char *)LED_COLORS[g_led], NULL };
		run_async(argv);
		break;
	}
	case 5: {
		char *argv[] = { (char *)STICKCTL, (char *)STICK_MODES[g_stick], NULL };
		run_async(argv);
		break;
	}
	}
}

static void step_item(int dir)
{
	int i = g_sel;
	if (i < 4) {
		int lo = prop_min(i);
		int v = g_val[i] + dir;
		if (v < lo) v = lo;
		if (v > 100) v = 100;
		if (v == g_val[i]) return;
		g_val[i] = v;
	} else if (i == 4) {
		g_led = (g_led + dir + N_LED) % N_LED;
	} else {
		g_stick = (g_stick + dir + N_STICK) % N_STICK;
	}
	apply_item(i);
}

static void reset_item(int i)
{
	if (i < 4) { g_val[i] = 50; }
	else if (i == 4) { g_led = 2; }
	else { g_stick = 0; }
	apply_item(i);
}

/* ---------- 绘制 ---------- */
static void fill(SDL_Renderer *r, int x, int y, int w, int h, SDL_Color c)
{
	SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
	SDL_Rect rc = { x, y, w, h };
	SDL_RenderFillRect(r, &rc);
}

/* DroidSansFallbackFull.ttf 是纯 CJK 回退字体，**没有拉丁字形**（ES 靠 OpenSans 补），
   所以这里按码点分段：CJK 用 CJK 字体、其余用 OpenSans，逐段测量再逐段绘制。 */
static int is_cjk(unsigned cp)
{
	return cp >= 0x2E80;
}

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

static void text_mixed(SDL_Renderer *r, TTF_Font *fCJK, TTF_Font *fLatin,
                       const char *s, int x, int y, SDL_Color c, int centered)
{
	/* 先量总宽 */
	int total = 0;
	{
		const char *q = s;
		while (*q) {
			unsigned cp;
			const char *start = q;
			q = utf8_next(q, &cp);
			/* 收集同类连续段 */
			int cjk = is_cjk(cp);
			const char *run = start;
			const char *end = q;
			while (*end) {
				unsigned cp2;
				const char *nx = utf8_next(end, &cp2);
				if (is_cjk(cp2) != cjk) break;
				end = nx;
			}
			char buf[512];
			size_t n = (size_t)(end - run);
			if (n >= sizeof buf) n = sizeof buf - 1;
			memcpy(buf, run, n); buf[n] = 0;
			int w = 0, h = 0;
			TTF_SizeUTF8(cjk ? fCJK : fLatin, buf, &w, &h);
			total += w;
			q = end;
		}
	}

	int px = centered ? x - total / 2 : x;
	const char *q = s;
	while (*q) {
		unsigned cp;
		const char *start = q;
		q = utf8_next(q, &cp);
		int cjk = is_cjk(cp);
		const char *run = start;
		const char *end = q;
		while (*end) {
			unsigned cp2;
			const char *nx = utf8_next(end, &cp2);
			if (is_cjk(cp2) != cjk) break;
			end = nx;
		}
		char buf[512];
		size_t n = (size_t)(end - run);
		if (n >= sizeof buf) n = sizeof buf - 1;
		memcpy(buf, run, n); buf[n] = 0;

		SDL_Surface *sf = TTF_RenderUTF8_Blended(cjk ? fCJK : fLatin, buf, c);
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

static void draw(SDL_Renderer *r, TTF_Font *fTitle, TTF_Font *fRow, TTF_Font *fLat)
{
	fill(r, 0, 0, SCR_W, SCR_H, C_BG);
	fill(r, 0, 0, SCR_W, 92, C_HEADER);
	text_mixed(r, fTitle, fLat, "面板与灯光调节", SCR_W / 2, 26, C_TEXT, 1);

	const int x0 = 150, w0 = SCR_W - 300, rh = 72, y0 = 150;

	for (int i = 0; i < N_ITEM; i++) {
		if (g_only >= 0 && i != g_only) continue;
		int y = (g_only >= 0) ? (SCR_H - rh) / 2 : (y0 + i * rh);
		int sel = (i == g_sel);
		if (sel) fill(r, x0, y, w0, rh - 8, C_SEL);

		SDL_Color fg = sel ? C_SEL_TXT : C_TEXT;
		text_mixed(r, fRow, fLat, ITEMS[i].title, x0 + 28, y + 14, fg, 0);

		char val[64];
		if (i < 4) {
			/* 数值条 */
			int bx = x0 + 300, bw = 320, bh = 18, by = y + 21;
			/* 轨道恒为深色；选中行的高亮条是青色，若填充也用青色就看不见了，
			   所以选中行把填充画成白色 */
			fill(r, bx, by, bw, bh, C_BARBG);
			int lo = prop_min(i);
			int fill_w = (int)((g_val[i] - lo) * (bw - 4) / (100.0 - lo));
			if (fill_w < 0) fill_w = 0;
			fill(r, bx + 2, by + 3, fill_w, bh - 6, sel ? C_SEL_TXT : C_BARFG);
			snprintf(val, sizeof val, "%d", g_val[i]);
			text_mixed(r, fRow, fLat, val, bx + bw + 30, y + 10, fg, 0);
		} else if (i == 4) {
			snprintf(val, sizeof val, "< %s >", LED_LABELS[g_led]);
			text_mixed(r, fRow, fLat, val, x0 + 300, y + 14, fg, 0);
		} else {
			snprintf(val, sizeof val, "< %s >", STICK_LABELS[g_stick]);
			text_mixed(r, fRow, fLat, val, x0 + 300, y + 14, fg, 0);
		}
	}

	/* 底部提示 */
	int hy = SCR_H - 78;
	fill(r, 0, hy, SCR_W, 78, C_HEADER);
	text_mixed(r, fRow, fLat, g_only >= 0 ? "左右=调节   B=返回" : "上下=切换项目   左右=调节   A/B=保存退出   SELECT=本项默认",
	       SCR_W / 2, hy + 22, C_DIM, 1);
}

/* ---------- 输入 ---------- */
static int open_joy(void)
{
	int fd = open(JOYDEV, O_RDONLY | O_NONBLOCK);
	return fd;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--only") == 0 && i + 1 < argc) {
			const char *k = argv[i + 1];
			for (int j = 0; j < N_ITEM; j++)
				if (strcmp(k, ITEMS[j].key) == 0) g_only = j;
		}
	}
	if (g_only >= 0) g_sel = g_only;

	load_conf();

	SDL_SetHint(SDL_HINT_VIDEODRIVER, "KMSDRM");
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 2;
	}
	if (TTF_Init() != 0) {
		fprintf(stderr, "TTF_Init: %s\n", SDL_GetError());
		SDL_Quit();
		return 2;
	}

	SDL_Window *win = SDL_CreateWindow("ngp-panel",
		SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, SCR_W, SCR_H,
		SDL_WINDOW_SHOWN);
	if (!win) {
		fprintf(stderr, "CreateWindow: %s\n", SDL_GetError());
		return 2;
	}
	SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
	if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	if (!ren) {
		fprintf(stderr, "CreateRenderer: %s\n", SDL_GetError());
		return 2;
	}

	TTF_Font *fTitle = TTF_OpenFont(FONT_CJK, 40);
	TTF_Font *fRow = TTF_OpenFont(FONT_CJK, 30);
	TTF_Font *fLat = TTF_OpenFont(FONT_UI, 30);
	if (!fTitle || !fRow || !fLat) {
		fprintf(stderr, "TTF_OpenFont: %s\n", SDL_GetError());
		return 2;
	}

	SDL_ShowCursor(SDL_DISABLE);

	int jfd = open_joy();
	double ax = 0, ay = 0;            /* 归一化 */
	double hold_l = 0, hold_r = 0, hold_u = 0, hold_d = 0;
	const double DEAD = 0.55, FIRST = 0.35, NEXT = 0.10, NAV = 0.28;

	struct timespec last;
	clock_gettime(CLOCK_MONOTONIC, &last);

	int running = 1;
	while (running) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT) running = 0;
			else if (e.type == SDL_KEYDOWN) {
				switch (e.key.keysym.sym) {
				case SDLK_ESCAPE: case SDLK_RETURN: running = 0; break;
				case SDLK_UP: if (g_only < 0) { g_sel = (g_sel + N_ITEM - 1) % N_ITEM; } break;
				case SDLK_DOWN: if (g_only < 0) { g_sel = (g_sel + 1) % N_ITEM; } break;
				case SDLK_LEFT: step_item(-1); break;
				case SDLK_RIGHT: step_item(1); break;
				case SDLK_r: reset_item(g_sel); break;
				default: break;
				}
			}
		}

		if (jfd >= 0) {
			fd_set rf;
			struct timeval tv = { 0, 0 };
			FD_ZERO(&rf); FD_SET(jfd, &rf);
			if (select(jfd + 1, &rf, NULL, NULL, &tv) > 0) {
				struct input_event ev;
				while (read(jfd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
					if (ev.type == EV_ABS && ev.code == ABS_X)
						ax = ev.value / 32767.0;
					else if (ev.type == EV_ABS && ev.code == ABS_Y)
						ay = ev.value / 32767.0;
					else if (ev.type == EV_KEY && ev.value == 1) {
						if (ev.code == BTN_DPAD_UP && g_only < 0)
							g_sel = (g_sel + N_ITEM - 1) % N_ITEM;
						else if (ev.code == BTN_DPAD_DOWN && g_only < 0)
							g_sel = (g_sel + 1) % N_ITEM;
						else if (ev.code == BTN_DPAD_LEFT) step_item(-1);
						else if (ev.code == BTN_DPAD_RIGHT) step_item(1);
						else if (ev.code == BTN_SELECT) reset_item(g_sel);
						else if (ev.code == BTN_SOUTH || ev.code == BTN_EAST ||
						         ev.code == BTN_START) running = 0;
					}
				}
			}
		}

		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		double dt = (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) / 1e9;
		last = now;

		/* 摇杆左右：连续调节 */
		for (int s = -1; s <= 1; s += 2) {
			int active = (s < 0) ? (ax < -DEAD) : (ax > DEAD);
			double *h = (s < 0) ? &hold_l : &hold_r;
			if (active) {
				if (*h == 0) { step_item(s); *h = 1e-4; }
				else {
					*h += dt;
					if (*h > FIRST) { step_item(s); *h = FIRST - NEXT; }
				}
			} else *h = 0;
		}
		/* 摇杆上下：切项目 */
		for (int s = -1; s <= 1; s += 2) {
			int active = (s < 0) ? (ay < -DEAD) : (ay > DEAD);
			double *h = (s < 0) ? &hold_u : &hold_d;
			if (active && g_only < 0) {
				if (*h == 0) { g_sel = (g_sel + (s < 0 ? N_ITEM - 1 : 1)) % N_ITEM; *h = 1e-4; }
				else {
					*h += dt;
					if (*h > NAV) { g_sel = (g_sel + (s < 0 ? N_ITEM - 1 : 1)) % N_ITEM; *h = 1e-4; }
				}
			} else *h = 0;
		}

		draw(ren, fTitle, fRow, fLat);
		SDL_RenderPresent(ren);
		SDL_Delay(16);
	}

	if (jfd >= 0) close(jfd);
	TTF_CloseFont(fTitle);
	TTF_CloseFont(fLat);
	TTF_CloseFont(fRow);
	SDL_DestroyRenderer(ren);
	SDL_DestroyWindow(win);
	TTF_Quit();
	SDL_Quit();
	return 0;
}
