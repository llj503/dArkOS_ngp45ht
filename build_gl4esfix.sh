#!/bin/bash

# Build and install the gl4es render-target fix (gl4es-fix/). gl4es does not
# pass a program's GL_LINEAR down for textures it renders into, so they keep
# the GLES default GL_NEAREST_MIPMAP_LINEAR; without mipmaps such a texture is
# incomplete and libmali reads it as black (Don't Starve: the light map, so a
# black world). The library forwards every gl* of libMali and gives such a
# texture GL_LINEAR. PortMaster ports get it through LIBGL_GLES, which only
# gl4es reads (portmaster-e2big.sh adds that to mod_dArkOS.txt).
# See docs/KNOWN-ISSUES.md.
install_package 64 binutils
sudo rm -rf Arkbuild/tmp/gl4es-fix
sudo cp -r gl4es-fix Arkbuild/tmp/
call_chroot "cd /tmp/gl4es-fix && sh build.sh"
if [ -f Arkbuild/tmp/gl4es-fix/libGLESv2.so.2 ]; then
  sudo mkdir -p Arkbuild/usr/lib/aarch64-linux-gnu/gl4es-fix
  sudo install -m 644 Arkbuild/tmp/gl4es-fix/libGLESv2.so.2 Arkbuild/usr/lib/aarch64-linux-gnu/gl4es-fix/
  sudo ln -sf libGLESv2.so.2 Arkbuild/usr/lib/aarch64-linux-gnu/gl4es-fix/libGLESv2.so
else
  echo "WARNING: the gl4es render-target fix did not build; gl4es ports may render black."
fi
sudo rm -rf Arkbuild/tmp/gl4es-fix
