#!/usr/bin/python3
# mkfix.py: build glfix.c - a libGLESv2 for gl4es (LIBGL_GLES) that forwards
# every gl* of libMali, and gives a render-target texture (glTexImage2D of
# level 0 without data) GL_LINEAR if it is left with a mipmap min filter.
#
# Why: gl4es does not pass the game's GL_LINEAR down for textures it renders
# into, so they keep the GLES default GL_NEAREST_MIPMAP_LINEAR. Without
# mipmaps such a texture is incomplete, and libmali on the RK3562 reads it as
# black: Don't Starve's light map, so the world was black.
#
#   python3 mkfix.py glfix.c && gcc -O2 -shared -fPIC -w -o libGLESv2.so.2 glfix.c -ldl
#
# The forwarders are generated from the libMali of the image, so the library
# always matches its driver; gl4es loads it as LIBGL_GLES=<this file>.
import subprocess, sys
REAL = "/usr/lib/aarch64-linux-gnu/libMali.so"
names = sorted({l.split()[-1] for l in subprocess.run(
    ["nm", "-D", "--defined-only", REAL], capture_output=True, text=True).stdout.splitlines()
    if l.split()[-1].startswith("gl") and l.split()[-1][2:3].isupper()})
o = ['#define _GNU_SOURCE', '#include <dlfcn.h>',
     'typedef unsigned int GLenum; typedef int GLint, GLsizei;']
o += ["static void *real_%s __attribute__((used));" % n for n in names]
o.append("__attribute__((constructor)) static void init(void) {")
o.append('  void *h = dlopen("%s", RTLD_NOW | RTLD_GLOBAL);' % REAL)
o += ['  real_%s = dlsym(h, "%s");' % (n, n) for n in names]
o.append("}")
for n in names:
    if n != "glTexImage2D":
        o.append('__attribute__((naked)) void %s(void) { __asm__("adrp x16, real_%s\\n ldr x16, [x16, :lo12:real_%s]\\n br x16"); }' % (n, n, n))
o.append('''void glTexImage2D(GLenum t, GLint lvl, GLint ifmt, GLsizei w, GLsizei h, GLint b, GLenum fmt, GLenum type, const void *p)
{
	((void (*)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *))real_glTexImage2D)(t, lvl, ifmt, w, h, b, fmt, type, p);
	if (lvl == 0 && !p && t == 0x0DE1) {	/* GL_TEXTURE_2D */
		GLint mf = 0;
		((void (*)(GLenum, GLenum, GLint *))real_glGetTexParameteriv)(t, 0x2801, &mf);	/* MIN_FILTER */
		if (mf != 0x2600 && mf != 0x2601)	/* not NEAREST/LINEAR */
			((void (*)(GLenum, GLenum, GLint))real_glTexParameteri)(t, 0x2801, 0x2601);
	}
}''')
open(sys.argv[1], "w").write("\n".join(o) + "\n")
print(len(names), "functions")
