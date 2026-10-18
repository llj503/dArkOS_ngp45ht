#!/bin/bash
# rename-menu-zh.sh — 把 /opt/system 里的英文菜单项改成简体中文，并去掉多余的 LED Settings
#
# ES 的「选项」是把 /opt/system 下的每个 .sh 列成一条（文件名去掉扩展名就是显示名），
# 所以"汉化"= 改文件名。注意两个坑：
#   1. 有的脚本里用 `gptokeyb -1 "<自己的文件名>"` 做退出检测，改名后必须同步改内部字符串，
#      否则 gptokeyb 认不出进程、手柄映射会失灵。
#   2. 已经汉化过的不要重复改（幂等）：新名字存在就跳过。
#
# 幂等，可反复执行。

set -u
cd /opt/system || exit 1

say() { printf '%s\n' "$*"; }

rename_one() { # rename_one <旧名> <新名>
	local old=$1 new=$2
	if [ ! -e "$old" ]; then
		[ -e "$new" ] && say "  skip  $old（已是 $new）" || say "  ----  $old 不存在"
		return 0
	fi
	# 同步脚本内部对自己文件名的引用（gptokeyb -1 "旧名" 等）
	if grep -q "$(basename "$old")" "$old" 2>/dev/null; then
		sed -i "s|$(basename "$old")|$new|g" "$old"
		say "  patch 内部引用 $(basename "$old") -> $new"
	fi
	mv -f "$old" "$new"
	say "  rename $old -> $new"
}

say "== 汉化 选项 菜单 =="
rename_one "351Files.sh"                "351文件.sh"
rename_one "Bluetooth.sh"               "蓝牙.sh"
rename_one "Change Password.sh"         "修改密码.sh"
rename_one "Disable Remote Services.sh" "关闭远程服务.sh"
rename_one "Enable Remote Services.sh"  "开启远程服务.sh"
rename_one "File Manager.sh"            "文件管理器.sh"
rename_one "Network Info.sh"            "网络信息.sh"
rename_one "PS1 - Delete m3u files.sh"  "PS1-删除m3u.sh"
rename_one "PS1 - Generate m3u files.sh" "PS1-生成m3u.sh"
rename_one "Remove ._ Files.sh"         "清理._文件.sh"
rename_one "System Info.sh"             "系统信息.sh"
rename_one "Update.sh"                  "系统更新.sh"
rename_one "USB Drive Mount.sh"         "挂载U盘.sh"
rename_one "USB Drive Unmount.sh"       "卸载U盘.sh"

say "== 去掉 LED Settings（面板调节 已覆盖同样功能） =="
if [ -e "LED Settings.sh" ]; then
	mv -f "LED Settings.sh" "LED Settings.sh.bak-ngp"
	say "  disabled LED Settings.sh -> LED Settings.sh.bak-ngp"
else
	say "  ----  已经处理过"
fi

say "== 结果 =="
ls -1 *.sh 2>/dev/null

say "== 去掉 网络信息（网络设置 已覆盖） =="
if [ -e "网络信息.sh" ]; then
	mv -f "网络信息.sh" "网络信息.sh.bak-ngp"
	say "  disabled 网络信息.sh -> 网络信息.sh.bak-ngp"
else
	say "  ----  已经处理过"
fi

say "== Tools 目录汉化（保留 Tools 符号链接，PortMaster/切卡脚本仍按老路径找得到） =="
if [ -d "Tools" ] && [ ! -L "Tools" ]; then
	mv -f "Tools" "工具"
	ln -sfn "工具" "Tools"
	say "  Tools -> 工具（并建 Tools 符号链接）"
else
	say "  ----  已经处理过"
fi

say "== 最终 =="
ls -la | awk '$NF ~ /\.sh$/ {print $NF}'
