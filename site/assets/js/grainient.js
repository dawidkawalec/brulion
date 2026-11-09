/* Grainient: the animated grain gradient of Brulion, in the "Ciemny" palette of the app
   (GlassTokens.Grainient.dark: deep ink #1D1D17, Bielik brown #424237, rhubarb ember #C46D58,
   contrast 1.5, the owner's 10 % dim). Port of the captylo.com manager to plain JS.

   Shader: React Bits "Grainient", Copyright (c) 2026 David Haz, MIT + Commons Clause License
   Condition v1.0. It is not covered by Brulion's GPLv3 and may not be sold or redistributed on its
   own; see NOTICE.md.

   Every element with [data-grainient] is a field; its first child <canvas class="grainient"> shows
   the picture. ONE shared WebGL2 context renders each field into an offscreen canvas and the frame
   is copied into the field's 2D canvas (phones keep only a few WebGL contexts alive). Only fields
   near the viewport render; phones render at 1x and about 30 fps; Reduce Motion and hidden tabs
   hold the frame. Options per field: data-seed (time offset), data-zoom, data-cx, data-cy. Without
   WebGL2 the CSS gradient of the field stays. */
(function () {
  'use strict'

  var VERT = '#version 300 es\nin vec2 position;void main(){gl_Position=vec4(position,0.0,1.0);}'
  var FRAG = [
    '#version 300 es',
    'precision highp float;',
    'uniform vec2 iResolution;uniform float iTime;uniform float uTimeSpeed;uniform float uColorBalance;uniform float uWarpStrength;uniform float uWarpFrequency;uniform float uWarpSpeed;uniform float uWarpAmplitude;uniform float uBlendAngle;uniform float uBlendSoftness;uniform float uRotationAmount;uniform float uNoiseScale;uniform float uGrainAmount;uniform float uGrainScale;uniform float uContrast;uniform float uGamma;uniform float uSaturation;uniform vec2 uCenterOffset;uniform float uZoom;uniform vec3 uColor1;uniform vec3 uColor2;uniform vec3 uColor3;uniform float uDim;',
    'out vec4 fragColor;',
    '#define S(a,b,t) smoothstep(a,b,t)',
    'mat2 Rot(float a){float s=sin(a),c=cos(a);return mat2(c,-s,s,c);}',
    'vec2 hash(vec2 p){p=vec2(dot(p,vec2(2127.1,81.17)),dot(p,vec2(1269.5,283.37)));return fract(sin(p)*43758.5453);}',
    'float noise(vec2 p){vec2 i=floor(p),f=fract(p),u=f*f*(3.0-2.0*f);float n=mix(mix(dot(-1.0+2.0*hash(i+vec2(0.0,0.0)),f-vec2(0.0,0.0)),dot(-1.0+2.0*hash(i+vec2(1.0,0.0)),f-vec2(1.0,0.0)),u.x),mix(dot(-1.0+2.0*hash(i+vec2(0.0,1.0)),f-vec2(0.0,1.0)),dot(-1.0+2.0*hash(i+vec2(1.0,1.0)),f-vec2(1.0,1.0)),u.x),u.y);return 0.5+0.5*n;}',
    'void main(){',
    '  vec2 C=gl_FragCoord.xy;float t=iTime*uTimeSpeed;vec2 uv=C/iResolution.xy;float ratio=iResolution.x/iResolution.y;',
    '  vec2 tuv=uv-0.5+uCenterOffset;tuv/=max(uZoom,0.001);',
    '  float degree=noise(vec2(t*0.1,tuv.x*tuv.y)*uNoiseScale);',
    '  tuv.y*=1.0/ratio;tuv*=Rot(radians((degree-0.5)*uRotationAmount+180.0));tuv.y*=ratio;',
    '  float ws=max(uWarpStrength,0.001);float amplitude=uWarpAmplitude/ws;float warpTime=t*uWarpSpeed;',
    '  tuv.x+=sin(tuv.y*uWarpFrequency+warpTime)/amplitude;tuv.y+=sin(tuv.x*(uWarpFrequency*1.5)+warpTime)/(amplitude*0.5);',
    '  float b=uColorBalance;float s=max(uBlendSoftness,0.0);',
    '  float blendX=(tuv*Rot(radians(uBlendAngle))).x;',
    '  float edge0=-0.3-b-s;float edge1=0.2-b+s;float v0=0.5-b+s;float v1=-0.3-b-s;',
    '  vec3 layer1=mix(uColor3,uColor2,S(edge0,edge1,blendX));',
    '  vec3 layer2=mix(uColor2,uColor1,S(edge0,edge1,blendX));',
    '  vec3 col=mix(layer1,layer2,S(v0,v1,tuv.y));',
    '  vec2 grainUv=uv*max(uGrainScale,0.001);',
    '  float grain=fract(sin(dot(grainUv,vec2(12.9898,78.233)))*43758.5453);',
    '  col+=(grain-0.5)*uGrainAmount;',
    '  col=(col-0.5)*uContrast+0.5;',
    '  float luma=dot(col,vec3(0.2126,0.7152,0.0722));col=mix(vec3(luma),col,uSaturation);',
    '  col=pow(max(col,0.0),vec3(1.0/max(uGamma,0.001)));',
    '  col*=1.0-uDim;',
    '  fragColor=vec4(clamp(col,0.0,1.0),1.0);',
    '}'
  ].join('\n')

  var BASE = {
    timeSpeed: 1.05, colorBalance: 0, warpStrength: 1, warpFrequency: 5.4, warpSpeed: 1.5,
    warpAmplitude: 50, blendAngle: -2, blendSoftness: 0.08, rotationAmount: 500, noiseScale: 1.65,
    grainAmount: 0.09, grainScale: 2, contrast: 1.5, gamma: 1, saturation: 1, zoom: 0.95, dim: 0.1
  }
  var C1 = hex('#1D1D17')
  var C2 = hex('#424237')
  var C3 = hex('#C46D58')
  var UNIFORMS = ['iResolution', 'iTime', 'uTimeSpeed', 'uColorBalance', 'uWarpStrength', 'uWarpFrequency',
    'uWarpSpeed', 'uWarpAmplitude', 'uBlendAngle', 'uBlendSoftness', 'uRotationAmount', 'uNoiseScale',
    'uGrainAmount', 'uGrainScale', 'uContrast', 'uGamma', 'uSaturation', 'uCenterOffset', 'uZoom',
    'uColor1', 'uColor2', 'uColor3', 'uDim']

  /* A large field at retina density would shade millions of pixels per frame for a soft
     gradient; the cap keeps each one light without visible loss. */
  var MAX_PIXELS = 2000000

  var glCanvas = document.createElement('canvas')
  var gl = null
  var loc = {}
  var views = []
  var calm = window.matchMedia('(prefers-reduced-motion: reduce)')
  var phone = window.matchMedia('(max-width: 760px), (pointer: coarse)')
  var held = 0
  var last = 0
  var lastDraw = 0

  function hex(h) {
    var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(h)
    return m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255] : [1, 1, 1]
  }

  function setup() {
    var ctx = glCanvas.getContext('webgl2', {
      antialias: false, alpha: false, premultipliedAlpha: false, depth: false, stencil: false,
      powerPreference: 'low-power'
    })
    if (!ctx) return false
    function compile(type, src) {
      var s = ctx.createShader(type)
      ctx.shaderSource(s, src)
      ctx.compileShader(s)
      return s
    }
    var pr = ctx.createProgram()
    ctx.attachShader(pr, compile(ctx.VERTEX_SHADER, VERT))
    ctx.attachShader(pr, compile(ctx.FRAGMENT_SHADER, FRAG))
    ctx.bindAttribLocation(pr, 0, 'position')
    ctx.linkProgram(pr)
    if (!ctx.getProgramParameter(pr, ctx.LINK_STATUS)) return false
    ctx.useProgram(pr)
    ctx.bindBuffer(ctx.ARRAY_BUFFER, ctx.createBuffer())
    ctx.bufferData(ctx.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), ctx.STATIC_DRAW)
    ctx.enableVertexAttribArray(0)
    ctx.vertexAttribPointer(0, 2, ctx.FLOAT, false, 0, 0)
    UNIFORMS.forEach(function (n) { loc[n] = ctx.getUniformLocation(pr, n) })
    gl = ctx
    // Uniforms shared by every field.
    gl.uniform1f(loc.uTimeSpeed, BASE.timeSpeed)
    gl.uniform1f(loc.uColorBalance, BASE.colorBalance)
    gl.uniform1f(loc.uWarpStrength, BASE.warpStrength)
    gl.uniform1f(loc.uWarpFrequency, BASE.warpFrequency)
    gl.uniform1f(loc.uWarpSpeed, BASE.warpSpeed)
    gl.uniform1f(loc.uWarpAmplitude, BASE.warpAmplitude)
    gl.uniform1f(loc.uBlendAngle, BASE.blendAngle)
    gl.uniform1f(loc.uBlendSoftness, BASE.blendSoftness)
    gl.uniform1f(loc.uRotationAmount, BASE.rotationAmount)
    gl.uniform1f(loc.uNoiseScale, BASE.noiseScale)
    gl.uniform1f(loc.uGrainAmount, BASE.grainAmount)
    gl.uniform1f(loc.uGrainScale, BASE.grainScale)
    gl.uniform1f(loc.uContrast, BASE.contrast)
    gl.uniform1f(loc.uGamma, BASE.gamma)
    gl.uniform1f(loc.uSaturation, BASE.saturation)
    gl.uniform1f(loc.uDim, BASE.dim)
    gl.uniform3fv(loc.uColor1, C1)
    gl.uniform3fv(loc.uColor2, C2)
    gl.uniform3fv(loc.uColor3, C3)
    views.forEach(function (v) { v.drawn = false })
    return true
  }

  function measure(v) {
    var r = v.host.getBoundingClientRect()
    var scale = phone.matches ? 1 : Math.min(window.devicePixelRatio || 1, 1.5)
    if (r.width * r.height * scale * scale > MAX_PIXELS) scale = Math.sqrt(MAX_PIXELS / Math.max(1, r.width * r.height))
    var w = Math.max(1, Math.round(r.width * scale))
    var h = Math.max(1, Math.round(r.height * scale))
    if (v.canvas.width !== w || v.canvas.height !== h) {
      v.canvas.width = w
      v.canvas.height = h
      v.drawn = false
    }
  }

  function render(v, t) {
    var w = v.canvas.width
    var h = v.canvas.height
    if (glCanvas.width < w) glCanvas.width = w
    if (glCanvas.height < h) glCanvas.height = h
    gl.viewport(0, 0, w, h)
    gl.uniform2f(loc.iResolution, w, h)
    gl.uniform1f(loc.iTime, t + v.seed)
    gl.uniform2f(loc.uCenterOffset, v.cx, v.cy)
    gl.uniform1f(loc.uZoom, v.zoom)
    gl.drawArrays(gl.TRIANGLES, 0, 3)
    // The viewport sits at the bottom left of the GL canvas, which is its last rows as an image.
    v.ctx.drawImage(glCanvas, 0, glCanvas.height - h, w, h, 0, 0, w, h)
    v.drawn = true
    if (!v.ready) {
      v.ready = true
      v.host.classList.add('grainient-ready')
    }
  }

  /* Time advances only while something moves, in steps of at most 0.1 s, so a hidden tab or a
     long scroll never makes the fields jump. Phones draw every other frame. */
  function frame(now) {
    requestAnimationFrame(frame)
    if (!gl) return
    var moving = !calm.matches && !document.hidden
    var t = moving && last ? held + Math.min(now - last, 100) / 1000 : held
    last = now
    held = t
    var due = !phone.matches || now - lastDraw >= 31
    if (due) lastDraw = now
    for (var i = 0; i < views.length; i++) {
      var v = views[i]
      if (!v.visible) continue
      if (!v.drawn || (moving && due)) render(v, t)
    }
  }

  function num(value, fallback) {
    var n = parseFloat(value)
    return isNaN(n) ? fallback : n
  }

  var hosts = document.querySelectorAll('[data-grainient]')
  if (!hosts.length) return
  if (!setup()) return

  var io = 'IntersectionObserver' in window ? new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      for (var i = 0; i < views.length; i++) if (views[i].host === e.target) views[i].visible = e.isIntersecting
    })
  }, { rootMargin: '160px 0px' }) : null
  var ro = 'ResizeObserver' in window ? new ResizeObserver(function (entries) {
    entries.forEach(function (e) {
      for (var i = 0; i < views.length; i++) if (views[i].host === e.target) measure(views[i])
    })
  }) : null

  Array.prototype.forEach.call(hosts, function (host) {
    var canvas = host.querySelector(':scope > canvas.grainient')
    if (!canvas) return
    var ctx = canvas.getContext('2d', { alpha: false })
    if (!ctx) return
    var v = {
      host: host, canvas: canvas, ctx: ctx,
      seed: num(host.dataset.seed, 0), zoom: num(host.dataset.zoom, BASE.zoom),
      cx: num(host.dataset.cx, 0), cy: num(host.dataset.cy, 0),
      visible: !io, drawn: false, ready: false
    }
    // Under memory pressure a phone may take a 2D canvas away: the CSS gradient shows until it is back.
    canvas.addEventListener('contextlost', function (e) { e.preventDefault(); v.ready = false; v.drawn = false; host.classList.remove('grainient-ready') })
    views.push(v)
    measure(v)
    if (io) io.observe(host)
    if (ro) ro.observe(host)
  })
  if (!ro) window.addEventListener('resize', function () { views.forEach(measure) })

  glCanvas.addEventListener('webglcontextlost', function (e) {
    e.preventDefault()
    gl = null
    views.forEach(function (v) { v.ready = false; v.drawn = false; v.host.classList.remove('grainient-ready') })
  })
  // Restoring reuses the same canvas and its context: still one context.
  glCanvas.addEventListener('webglcontextrestored', function () { setup() })

  requestAnimationFrame(frame)
})()
