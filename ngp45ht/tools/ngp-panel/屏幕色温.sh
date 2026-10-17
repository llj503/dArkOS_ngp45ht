#!/bin/bash
# 屏幕色温.sh — NGP45HT 面板色温 / 画面调节
#
# /opt/ngp-panel/paneladj.sh 的对话框前端（paneladj 移植自 ROCKNIX）。
# 本文件放入 /opt/system/ 后，EmulationStation 的系统菜单会列出它，
# 与 Wifi.sh / LED Settings.sh 同等对待。
#
# 中文显示依赖两个字体：
#   控制台：/usr/share/consolefonts/Unifont-CJK-panel.psf.gz
#           （512 字形位的中文 PSF2，本脚本运行期间加载，退出后恢复拉丁字体）
#   ES 菜单：/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf
#           （ES 自带的缺字回退字体，系统镜像自带）
#
# 四个控件是 VOP2 BCSH 后处理器（0-100，50 = 中性）：
#   brightness  亮度/伽马偏移（下限 5，防止调黑）
#   contrast    对比度
#   saturation  饱和度（0 = 灰度）
#   hue         色相旋转 -30..+30 度

PANELDIR=/opt/ngp-panel
PANELADJ=$PANELDIR/paneladj.sh
CJKFONT=/usr/share/consolefonts/Unifont-CJK-panel.psf.gz
LATINFONT=/usr/share/consolefonts/Lat7-Terminus20x10.psf.gz

sudo chmod 666 /dev/tty1
reset
printf "\e[?25l" > /dev/tty1          # 隐藏光标
dialog --clear

height=20
width=46

export TERM=linux
export XDG_RUNTIME_DIR=/run/user/$UID/

# 加载中文字体（控制台单字体上限 512 字形位，故只收录本界面用到的字符）
sudo setfont "$CJKFONT" 2>/dev/null

# --- 手柄 -> 键盘，供 dialog 导航（与 Wifi.sh 相同）----------------------
sudo chmod 666 /dev/uinput
export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
pgrep -f gptokeyb | sudo xargs -r kill -9
pgrep -f osk.py   | sudo xargs -r kill -9
/opt/inttools/gptokeyb -1 "屏幕色温.sh" -c "/opt/inttools/keys.gptk" > /dev/null 2>&1 &

printf "\033c" > /dev/tty1

# --- 当前值，每次重绘读一次（有配置文件时不启 python，开销可忽略）------
BRIGHTNESS=50 CONTRAST=50 SATURATION=50 HUE=50
read_vals() {
  local out
  out="$($PANELADJ values 2>/dev/null)"
  [ -n "$out" ] && eval "$out"
  case "$BRIGHTNESS" in ''|*[!0-9]*) BRIGHTNESS=50 ;; esac
  case "$CONTRAST" in ''|*[!0-9]*) CONTRAST=50 ;; esac
  case "$SATURATION" in ''|*[!0-9]*) SATURATION=50 ;; esac
  case "$HUE" in ''|*[!0-9]*) HUE=50 ;; esac
}

backtitle() {
  echo "屏幕色温：亮度 $BRIGHTNESS  对比度 $CONTRAST  饱和度 $SATURATION  色相 $HUE（50 = 默认）"
}

ExitMenu() {
  printf "\033c" > /dev/tty1
  pgrep -f gptokeyb | sudo xargs -r kill -9
  sudo setfont "$LATINFONT" 2>/dev/null
  exit 0
}

value_label() { # $1=属性 $2=数值 -> 简短提示
  case "$1" in
    brightness)
      [ "$2" = 5 ] && echo "最暗"; [ "$2" = 50 ] && echo "默认"; [ "$2" = 100 ] && echo "最亮" ;;
    contrast)
      [ "$2" = 0 ] && echo "无对比度"; [ "$2" = 50 ] && echo "默认"; [ "$2" = 100 ] && echo "最大" ;;
    saturation)
      [ "$2" = 0 ] && echo "灰度"; [ "$2" = 50 ] && echo "默认"; [ "$2" = 100 ] && echo "最大" ;;
    hue)
      [ "$2" = 0 ] && echo "负 30 度"; [ "$2" = 50 ] && echo "默认"; [ "$2" = 100 ] && echo "正 30 度" ;;
  esac
}

prop_title() {
  case "$1" in
    brightness) echo "亮度（伽马）" ;;
    contrast)   echo "对比度" ;;
    saturation) echo "饱和度" ;;
    hue)        echo "色相（色彩旋转）" ;;
  esac
}

PropMenu() { # $1 = 属性
  local prop="$1" lo cur choice v d title
  case "$prop" in
    brightness) lo=5 ;;
    *)          lo=0 ;;
  esac
  title="$(prop_title "$prop")"
  while true; do
    read_vals
    case "$prop" in
      brightness) cur="$BRIGHTNESS" ;;
      contrast)   cur="$CONTRAST" ;;
      saturation) cur="$SATURATION" ;;
      hue)        cur="$HUE" ;;
    esac
    local opts=("p1" "增加 1（当前 $cur）" "m1" "减少 1（当前 $cur）")
    for v in $(seq "$lo" 5 100); do
      d="$(value_label "$prop" "$v")"
      opts+=("$v" "$v${d:+ - $d}")
    done
    choice=$(dialog --clear --no-collapse --cancel-label "返回" \
      --backtitle "$(backtitle)" \
      --title "$title（当前：$cur）" \
      --menu "选择数值" $height $width 15 \
      "${opts[@]}" 2>&1 > /dev/tty1) || return
    case "$choice" in
      p1) $PANELADJ "$prop" up ;;
      m1) $PANELADJ "$prop" down ;;
      *)  $PANELADJ "$prop" "$choice" ;;
    esac
  done
}

ResetDefaults() {
  $PANELADJ brightness 50
  $PANELADJ contrast 50
  $PANELADJ saturation 50
  $PANELADJ hue 50
  read_vals
  dialog --clear --no-collapse --backtitle "$(backtitle)" \
    --title "恢复默认" --msgbox "\n四项均已恢复为 50（驱动默认）。\n" 8 40 2>&1 > /dev/tty1
}

MainMenu() {
  local choice
  while true; do
    read_vals
    choice=$(dialog --clear --no-collapse --cancel-label "退出" \
      --backtitle "$(backtitle)" \
      --title "屏幕色温 / 画面调节" \
      --menu "调节面板后处理（50 = 默认）" $height $width 12 \
      1 "亮度（伽马）       [ $BRIGHTNESS ]" \
      2 "对比度             [ $CONTRAST ]" \
      3 "饱和度             [ $SATURATION ]" \
      4 "色相（色彩旋转）   [ $HUE ]" \
      5 "全部恢复默认（50）" \
      6 "退出" \
      2>&1 > /dev/tty1) || ExitMenu
    case "$choice" in
      1) PropMenu brightness ;;
      2) PropMenu contrast ;;
      3) PropMenu saturation ;;
      4) PropMenu hue ;;
      5) ResetDefaults ;;
      6) ExitMenu ;;
      *) ExitMenu ;;
    esac
  done
}

trap ExitMenu EXIT
MainMenu
