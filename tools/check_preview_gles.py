"""Compile and run the preview's GLSL ES 3.00 shader on Mesa (EGL, GLES 3) and save a frame."""
import os, re, sys, ctypes, json, shutil, subprocess
# On a machine without apt (the Steam Frame's SteamOS) this runs in tools/box.sh's container: EGL
# there is software, here it would be the headset's GPU (tools/env.sh)
if not shutil.which('apt-get') and shutil.which('podman'):
    BOX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'box.sh')
    os.execv(BOX, [BOX, 'python3', os.path.abspath(sys.argv[0])] + sys.argv[1:])
os.environ['PYOPENGL_PLATFORM'] = 'egl'
os.environ.setdefault('EGL_PLATFORM', 'surfaceless')
import numpy as np
from OpenGL import EGL, GLES3 as gl
from PIL import Image

html = open(sys.argv[1]).read()
frag = re.search(r'<script id="frag" type="x-shader/x-fragment">(.*?)</script>', html, re.S).group(1)
vert = '#version 300 es\nin vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}'

dpy = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
EGL.eglInitialize(dpy, None, None)
cfg = EGL.EGLConfig(); n = EGL.EGLint()
EGL.eglChooseConfig(dpy, (EGL.EGLint * 7)(EGL.EGL_SURFACE_TYPE, EGL.EGL_PBUFFER_BIT, EGL.EGL_RENDERABLE_TYPE, EGL.EGL_OPENGL_ES3_BIT, EGL.EGL_NONE, 0, 0), ctypes.byref(cfg), 1, ctypes.byref(n))
W = H = 480
surf = EGL.eglCreatePbufferSurface(dpy, cfg, (EGL.EGLint * 5)(EGL.EGL_WIDTH, W, EGL.EGL_HEIGHT, H, EGL.EGL_NONE))
EGL.eglBindAPI(EGL.EGL_OPENGL_ES_API)
ctx = EGL.eglCreateContext(dpy, cfg, EGL.EGL_NO_CONTEXT, (EGL.EGLint * 3)(EGL.EGL_CONTEXT_CLIENT_VERSION, 3, EGL.EGL_NONE))
EGL.eglMakeCurrent(dpy, surf, surf, ctx)
gs = lambda e: ctypes.string_at(ctypes.cast(gl.glGetString(e), ctypes.c_void_p)).decode()
print(gs(gl.GL_VERSION), '|', gs(gl.GL_SHADING_LANGUAGE_VERSION))

def compile(kind, src):
    s = gl.glCreateShader(kind); gl.glShaderSource(s, src); gl.glCompileShader(s)
    if not gl.glGetShaderiv(s, gl.GL_COMPILE_STATUS):
        log = gl.glGetShaderInfoLog(s)
        raise SystemExit('COMPILE ERROR:\n' + (log.decode() if isinstance(log, bytes) else str(log)))
    return s
prog = gl.glCreateProgram()
gl.glAttachShader(prog, compile(gl.GL_VERTEX_SHADER, vert)); gl.glAttachShader(prog, compile(gl.GL_FRAGMENT_SHADER, frag))
gl.glLinkProgram(prog); assert gl.glGetProgramiv(prog, gl.GL_LINK_STATUS)
gl.glUseProgram(prog)
print('GLSL ES 3.00 shader compiled and linked')

# eye state from the page's own JS (walk d metres, offset o), view straight ahead
d, o = float(sys.argv[2]), float(sys.argv[3])
js = os.path.join(os.path.dirname(__file__), 'check_preview_geometry.js')
st = json.loads(subprocess.check_output(['node', '-e', f"""
const fs=require('fs');const html=fs.readFileSync({json.dumps(sys.argv[1])},'utf8');
const a=html.indexOf('// ---------------------------------------------------------------- geometry');const b=html.indexOf('// ---------------------------------------------------------------- GL');
const s=(new Function(html.slice(a,b)+'\\nreturn eyeState;'))()({d},{o});console.log(JSON.stringify(s));"""]))
f = st['frame']
comb = lambda c: [c[0] * f[0][j] + c[1] * f[1][j] + c[2] * f[2][j] for j in range(4)]
U = lambda nm: gl.glGetUniformLocation(prog, nm)
gl.glUniform1f(U('wh_a'), 3.0); gl.glUniform1f(U('wh_L'), 4.5)
gl.glUniform1f(U('uL0'), st['l']); gl.glUniform3f(U('uN0'), *st['n'])
gl.glUniform4f(U('uF'), *comb([0, -0.05, -1])); gl.glUniform4f(U('uRt'), *comb([1, 0, 0])); gl.glUniform4f(U('uUp'), *comb([0, 1, -0.05]))
t = np.tan(np.radians(47.5)); gl.glUniform2f(U('uTan'), t, t); gl.glUniform2f(U('uSize'), W, H)
buf = gl.glGenBuffers(1); gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buf)
quad = np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4'); gl.glBufferData(gl.GL_ARRAY_BUFFER, quad.nbytes, quad, gl.GL_STATIC_DRAW)
loc = gl.glGetAttribLocation(prog, 'p'); gl.glEnableVertexAttribArray(loc); gl.glVertexAttribPointer(loc, 2, gl.GL_FLOAT, False, 0, None)
gl.glViewport(0, 0, W, H); gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4)
px = np.zeros((H, W, 4), np.uint8); gl.glReadPixels(0, 0, W, H, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, px); px = px[::-1]
magenta = np.mean((px[..., 0] > 250) & (px[..., 1] < 5) & (px[..., 2] > 250))
print(f'mean colour {px[..., :3].mean(axis=(0, 1)).round(1)}, error-colour pixels {magenta * 100:.3f}%')
Image.fromarray(px[..., :3]).save(sys.argv[4])
