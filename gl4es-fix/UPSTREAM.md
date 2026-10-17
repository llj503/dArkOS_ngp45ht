# Draft: report for ptitSeb/gl4es

Not posted. This is the text for an issue at https://github.com/ptitSeb/gl4es/issues.

---

**Title:** Render-target textures keep `GL_NEAREST_MIPMAP_LINEAR` on the GLES side, so they sample black (Don't Starve, libmali)

**Setup**
- Device: AISLPC RG52 Mini (Rockchip RK3562, Mali-G52).
- Driver: libmali `g29p1-12eac0`, used as GLES2.
- OS: dArkOS (Debian trixie).
- gl4es 1.1.7, shipped by the PortMaster port.
- The game: *Don't Starve* (Linux x86_64), run on box64.
- Environment: `LIBGL_ES=2`, `LIBGL_GL=21`, `LIBGL_FB=4` with `LIBGL_DRMCARD=/dev/dri/card0`. The same happens with `LIBGL_FB=2`.

**What happens.** The HUD draws, but the world is black. The game multiplies
the world by a light map, rendered into a 427x240 RGBA texture attached to an
FBO and cleared to the daylight colour. On the GLES side that texture keeps the
default min filter `GL_NEAREST_MIPMAP_LINEAR`. It has only level 0, so it is
incomplete, and sampling it returns black.

**Trace.** I put a forwarding `libGLESv2` under gl4es (`LIBGL_GLES=`) and logged
the GLES calls gl4es makes.
- For each of the game's 13 render targets, gl4es makes the same calls:
  `glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA or GL_RGB, w, h, 0, ..., GL_UNSIGNED_BYTE, NULL)`,
  then `glFramebufferTexture2D`.
- `glCheckFramebufferStatus` returns `GL_FRAMEBUFFER_COMPLETE` for all of them.
- No `glTexParameteri(GL_TEXTURE_MIN_FILTER, ...)` reaches GLES for these
  textures after `glTexImage2D`.
- Querying the GLES side right after `glTexImage2D` gives `GL_TEXTURE_MIN_FILTER`
  = `0x2702` (`GL_NEAREST_MIPMAP_LINEAR`) for all 13.

**Workaround.** The forwarding library calls `glTexParameteri(..., GL_LINEAR)`
after a `glTexImage2D` of level 0 without data, when the min filter is a mipmap
one. With it the world renders, with lighting, colour grading and shadows.

**Where I would look.** I have not built gl4es to confirm this.
- In `blitTexture()` (`framebuffers.c`, the non-`created` branch), gl4es calls
  `gl4es_glTexParameteri()` and then writes `tex->actual.min_filter` and
  `tex->actual.mag_filter` itself. If that `gl4es_glTexParameteri` only records
  the change and leaves it to `realize_1texture()`, `actual` now says the GLES
  side has `filter`, while it still has the default. Later
  `realize_1texture()` sees `actual == sampler` and sends nothing.
- In `gl4es_glFramebufferTexture2D()`, the "force no mipmap for texture
  attached to fbo" path adjusts `sampler.min_filter` only when `hardext.npot < 2`.
  With full NPOT, nothing makes a mipmap filter on an attached texture
  non-mipmap.

**Also seen, separately.** In the same game, several fragment shaders fail on
libmali with "S0020: Array subscript too big". They declare
`uniform sampler2D SAMPLER[SAMPLERCOUNT];` with
`#define SAMPLERCOUNT (2 + BLUR_SAMPLER_COUNT + BLOOM_SAMPLER_COUNT)`, and the
two counts are themselves macros. The array came out as 2 elements. Replacing
`SAMPLERCOUNT` with the number fixes it, so the size of a uniform array given
by nested macros seems to be evaluated wrongly somewhere in the shader
conversion.
