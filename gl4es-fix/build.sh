#!/bin/sh
# build.sh: build the gl4es render-target fix, libGLESv2.so.2 (run on aarch64,
# or in an aarch64 chroot) - python3, nm and gcc needed, and libMali.so.
set -e
cd "$(dirname "$0")"
python3 mkfix.py glfix.c
${CC:-gcc} -O2 -shared -fPIC -w -o libGLESv2.so.2 glfix.c -ldl
rm -f glfix.c
echo "built: $(ls -l libGLESv2.so.2)"
