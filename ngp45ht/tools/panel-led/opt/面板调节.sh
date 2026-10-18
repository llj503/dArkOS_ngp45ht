#!/bin/bash
# 选项 → 面板调节：直接打开「面板与灯光调节」总览界面（6 项，上下切换 + 左右调节）
#
# 不要再建同名目录或拆成多个条目 —— 那会多出一层子菜单/一堆子项。
# 界面由 /opt/ngp-panel/ngp-panel-gui 绘制（SDL2 + KMSDRM），
# 拿不到显示时 panel-item.sh 会自动回退到控制台版。
exec /opt/ngp-panel/panel-item.sh
