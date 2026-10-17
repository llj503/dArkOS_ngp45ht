#!/bin/sh
# build.sh: build libVkLayer_DARKOS_rotate.so (run on aarch64, or in an
# aarch64 chroot) - glslangValidator and the Vulkan headers needed.
set -e
cd "$(dirname "$0")"
glslangValidator -V --vn rotate_vert_spv -o rotate_vert.h rotate.vert > /dev/null
glslangValidator -V --vn rotate_frag_spv -o rotate_frag.h rotate.frag > /dev/null
cat rotate_vert.h rotate_frag.h > rotate_spv.h
${CC:-gcc} -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared -fvisibility=hidden \
    -o libVkLayer_DARKOS_rotate.so darkos_rotate_layer.c -lpthread
rm -f rotate_vert.h rotate_frag.h
echo "built: $(ls -l libVkLayer_DARKOS_rotate.so)"
