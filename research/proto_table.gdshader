shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

// Prototype for the cost of the per-eye table method: the curved part of every ray (floor,
// leaving the shell, movable balls and cubes) from three tables per eye instead of integrals and
// sampling. The flat universes and the shading are wormhole_core's, unchanged. Not used by the app:
// compiled by tools/adreno_stats.sh --shader to compare instructions and registers.

uniform float wh_rho0 = 3.0;
uniform float wh_h = 5.0;
uniform float wh_fillet = 1.0;
uniform vec4 wh_sph[6];
uniform vec4 wh_pil[4];
uniform vec4 wh_box[4];
uniform vec4 wh_ball[12];
uniform vec4 wh_ballCol[12];
uniform int wh_nBall = 0;
uniform float head_l = 10.0;
uniform vec3 head_n = vec3(1.0, 0.0, 0.0);
uniform vec4 head_f[3];
uniform vec3 head_pos;
uniform float wh_pix = 0.0015;
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[30];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube = 0;
uniform vec4 wh_bound[4];
uniform ivec4 wh_bIdx;
uniform ivec4 wh_cIdx;
uniform vec4 wh_fball[12];

#include "res://shaders/wormhole_core.gdshaderinc"

// per eye (layer = VIEW_INDEX): rows by alpha, the lower side (alpha < alpha_c) then the upper
uniform sampler2DArray pt_exit : filter_linear, repeat_disable;    // 1 column: (psi_exit, s_exit, side, 0)
uniform sampler2DArray pt_floor : filter_linear, repeat_disable;   // psi columns: (l, s)
uniform sampler2DArray pt_path : filter_linear, repeat_disable;    // sqrt(s) columns: (u, v, w, l)
uniform vec4 pt_eye[2];      // per eye: (alpha_c, span below, span above, 0)
uniform vec4 pt_dim = vec4(1024.0, 256.0, 256.0, 8.0);   // rows per side, path columns, floor columns, smax

varying flat float v_l;
varying flat vec3 v_n;
varying flat vec4 v_f0;
varying flat vec4 v_f1;
varying flat vec4 v_f2;
varying vec4 v_ray;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
	float l = head_l;
	vec3 n = head_n;
	vec4 f0 = head_f[0];
	vec4 f1 = head_f[1];
	vec4 f2 = head_f[2];
	vec3 eye = (INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
	vec3 off = eye - head_pos;
	float len = length(off);
	if (len > 1e-6) {
		vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
		wh_geodesic(l, n, dir, len, f0, f1, f2);
	}
	v_l = l; v_n = n; v_f0 = f0; v_f1 = f1; v_f2 = f2;
	vec4 pa = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.001, 1.0);
	vec4 pb = INV_PROJECTION_MATRIX * vec4(VERTEX.xy, 0.999, 1.0);
	vec3 qa = pa.xyz / pa.w;
	vec3 qb = pb.xyz / pb.w;
	vec3 pd = mat3(INV_VIEW_MATRIX) * ((dot(qa, qa) > dot(qb, qb) ? qa : qb) - EYE_OFFSET);
	v_ray = pd.x * f0 + pd.y * f1 + pd.z * f2;
}

// the row coordinate of alpha: dense toward the critical angle (one log)
float pt_row(float alpha, vec4 EY) {
	bool up = alpha >= EY.x;
	float d = max((alpha - EY.x) * (up ? 1.0 : -1.0), 0.0);
	float sp = up ? EY.z : EY.y;
	float x = 0.75 * d / sp + 0.25 * log(1.0 + d * 1e6) / log(1.0 + sp * 1e6);
	x = clamp(x, 0.5 / pt_dim.x, 1.0 - 0.5 / pt_dim.x);
	return ((up ? 1.0 : 0.0) + x) * 0.5;
}

vec4 pt_q(float rowv, float layer, float s) {
	float c = sqrt(clamp(s / pt_dim.w, 0.0, 1.0));
	return textureLod(pt_path, vec3(c * (pt_dim.y - 1.0) / pt_dim.y + 0.5 / pt_dim.y, rowv, layer), 0.0);
}

// distance in R^4 from the subspace point q to object i (ball i, or cube i - WH_MAXB)
float pt_dist(int i, vec3 q, vec3 cb, float perp2, vec3 e1, vec3 e2) {
	if (i < WH_MAXB) {
		vec3 a = q - cb;
		return sqrt(dot(a, a) + perp2) - wh_ballCol[i].w;
	}
	int c = i - WH_MAXB;
	float o2 = 0.0;
	float inside = -1e9;
	for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
		vec4 Ek = wh_cubeE[5 * c + k];
		float u = abs(dot(q, vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w)) - wh_cubeE[5 * c + 4][k]) - 1.0;
		o2 += u > 0.0 ? u * u : 0.0;
		inside = max(inside, u);
	}
	return (o2 > 0.0 ? sqrt(o2) : inside) * wh_cubeCol[c].w;
}

// does the chord q0 -> q1 meet object i grown by g (a superset test for cubes)
bool pt_chord(int i, vec3 q0, vec3 q1, float g, vec3 cb, float perp2, vec3 e1, vec3 e2) {
	vec3 D = q1 - q0;
	if (i < WH_MAXB) {
		vec3 a = q0 - cb;
		float rr = wh_ballCol[i].w + g;
		float A = max(dot(D, D), 1e-20);
		float B = dot(a, D);
		float C = dot(a, a) + perp2 - rr * rr;
		float disc = B * B - A * C;
		float t = (-B - sqrt(max(disc, 0.0))) / A;
		return C <= 0.0 || (disc >= 0.0 && t >= 0.0 && t <= 1.0);
	}
	int c = i - WH_MAXB;
	float gk = 1.0 + g / wh_cubeCol[c].w;
	float tin = 0.0;
	float tout = 1.0;
	for (int k = 0; k < 4 + min(wh_nCube, 0); k++) {
		vec4 Ek = wh_cubeE[5 * c + k];
		vec3 ek = vec3(dot(Ek.xyz, e1), dot(Ek.xyz, e2), Ek.w);
		float a0 = dot(q0, ek) - wh_cubeE[5 * c + 4][k];
		float dk = dot(D, ek);
		float idk = 1.0 / (abs(dk) > 1e-9 ? dk : 1e-9);
		float t0 = (-gk - a0) * idk;
		float t1 = (gk - a0) * idk;
		tin = max(tin, min(t0, t1));
		tout = min(tout, max(t0, t1));
	}
	return tin <= tout;
}

const float PT_KMAX = 1.0;   // the space's largest principal curvature (1 / fillet): the chords' sag

// The bounded search for object i along the path [0, send): sphere tracing while far, chords of
// reach / 2 near it, each chord that meets the grown object split into 8 and refined. Returns
// the entry's s, or -1.
float pt_search(int i, float rowv, float layer, float send, vec3 cb, float perp2, float reach, vec3 e1, vec3 e2) {
	float s = 0.0;
	vec3 q = pt_q(rowv, layer, s).xyz;
	float d = pt_dist(i, q, cb, perp2, e1, e2);
	if (d <= 0.0) return -1.0;
	for (int it = 0; it < 24 + min(wh_nBall, 0); it++) {
		if (s >= send) break;
		if (d >= reach) {
			s += d;
			q = pt_q(rowv, layer, s).xyz;
			d = pt_dist(i, q, cb, perp2, e1, e2);
			continue;
		}
		float step = min(0.5 * reach, send - s);
		float s1 = s + step;
		vec3 q1 = pt_q(rowv, layer, s1).xyz;
		if (pt_chord(i, q, q1, PT_KMAX * step * step * 0.125 + 1e-6, cb, perp2, e1, e2)) {
			vec3 qa = q;
			float sa = s;
			float da = d;
			for (int j = 1; j <= 8 + min(wh_nBall, 0); j++) {
				float sb = s + step * float(j) * 0.125;
				vec3 qb = pt_q(rowv, layer, sb).xyz;
				float db = pt_dist(i, qb, cb, perp2, e1, e2);
				if (db <= 0.0) {
					// regula falsi, three steps
					for (int r = 0; r < 3 + min(wh_nBall, 0); r++) {
						float sx = (sa * db - sb * da) / (db - da);
						float dx = pt_dist(i, pt_q(rowv, layer, sx).xyz, cb, perp2, e1, e2);
						if (dx > 0.0) { sa = sx; da = dx; } else { sb = sx; db = dx; }
					}
					return sb;
				}
				qa = qb; sa = sb; da = db;
			}
		}
		s = s1;
		q = q1;
		d = pt_dist(i, q, cb, perp2, e1, e2);
	}
	return -1.0;
}

void fragment() {
	vec4 V = normalize(v_ray);
	float layer = float(VIEW_INDEX);
	vec4 EY = pt_eye[VIEW_INDEX];
	float l0 = v_l;
	vec3 n0 = v_n;
	float side = l0 > 0.0 ? 1.0 : -1.0;
	float wn = length(V.yzw);
	vec3 e1 = n0;
	vec3 e2 = V.yzw / max(wn, 1e-12);
	float alpha = atan(wn, V.x);
	float rowv = pt_row(alpha, EY);
	float rs = wh_r(l0);
	float b = rs * wn;
	int kind = -1;
	float fl = 0.0;
	vec3 fn = vec3(1.0, 0.0, 0.0);
	vec3 col = vec3(0.0);
	vec3 nrm = vec3(0.0, 0.0, 1.0);
	vec3 x = vec3(0.0);
	vec3 d = vec3(0.0);
	float dist = 0.0;
	bool curved = abs(l0) < wh_Lsh();
	if (!curved) {
		// straight until the shell
		x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
		d = wh_M(side, side * V.x * n0 + V.yzw);
		WhHit h = wh_traceFlat(side, x, d, true);
		curved = h.kind == 3;
		if (!curved) {
			vec3 p = x + h.t * d;
			if (h.kind == 0) { kind = 0; }
			else if (h.kind == 1) { kind = 1; float ip = inversesqrt(dot(p, p)); fn = wh_M(side, p) * ip; fl = side * (dot(p, p) * ip - wh_Rout() + wh_Lsh()); dist = h.t; }
			else { kind = 2; col = h.col; nrm = h.nrm; dist = h.t; }
		}
	}
	if (curved) {
		// the whole curved part of this ray, from the tables
		vec4 ex = textureLod(pt_exit, vec3(0.5, rowv, layer), 0.0);    // psi_exit, s_exit, side
		float psiF = atan(e1.z, -e2.z);
		bool floorIn = psiF < ex.x;
		vec2 fs = floorIn ? textureLod(pt_floor, vec3(psiF / WH_PI * (pt_dim.z - 1.0) / pt_dim.z + 0.5 / pt_dim.z, rowv, layer), 0.0).xy : vec2(0.0);
		float send = floorIn ? fs.y : ex.y;
		// movable balls and cubes within reach of this ray's subspace
		float best = send;
		int bi = -1;
		for (int i = wh_bIdx.x; i < wh_bIdx.w; i++) {
			vec4 C = wh_ball[i];
			float c1 = dot(C.xyz, e1);
			float c2 = dot(C.xyz, e2);
			float perp2 = dot(C.xyz, C.xyz) - c1 * c1 - c2 * c2;
			float rad = wh_ballCol[i].w;
			if (perp2 < rad * rad) {
				float sh = pt_search(i, rowv, layer, best, vec3(c1, c2, C.w), perp2, rad, e1, e2);
				if (sh >= 0.0) { best = sh; bi = i; }
			}
		}
		for (int i = wh_cIdx.x; i < wh_cIdx.w; i++) {
			vec4 C = wh_cube[i];
			float c1 = dot(C.xyz, e1);
			float c2 = dot(C.xyz, e2);
			float perp2 = dot(C.xyz, C.xyz) - c1 * c1 - c2 * c2;
			float rad = 2.0 * wh_cubeCol[i].w;
			if (perp2 < rad * rad) {
				float sh = pt_search(WH_MAXB + i, rowv, layer, best, vec3(c1, c2, C.w), perp2, wh_cubeCol[i].w, e1, e2);
				if (sh >= 0.0) { best = sh; bi = WH_MAXB + i; }
			}
		}
		if (bi >= 0) {
			vec4 Q = pt_q(rowv, layer, best);
			float hl = Q.w;
			vec3 hn = (Q.x * e1 + Q.y * e2) * inversesqrt(Q.x * Q.x + Q.y * Q.y);
			vec4 pr = wh_prof(hl);
			bool isCube = bi >= WH_MAXB;
			int ci = bi - WH_MAXB;
			vec4 N4 = vec4(pr.x * hn, pr.y) - (isCube ? wh_cube[ci] : wh_ball[bi]);
			if (isCube) {
				col = wh_cubeLook(ci, N4, best);
				vec3 sd = vec3(dot(N4, wh_cubeE[5 * ci]), dot(N4, wh_cubeE[5 * ci + 1]), dot(N4, wh_cubeE[5 * ci + 2]));
				vec3 ad = abs(sd);
				int k = ad.x >= ad.y && ad.x >= ad.z ? 0 : (ad.y >= ad.z ? 1 : 2);
				N4 = (sd[k] >= 0.0 ? 1.0 : -1.0) * wh_cubeE[5 * ci + k];
			} else {
				col = wh_ballCol[bi].rgb;
			}
			float rad = dot(N4.xyz, hn);
			side = hl >= 0.0 ? 1.0 : -1.0;
			kind = 2;
			nrm = normalize(wh_M(side, side * (pr.z * rad + pr.w * N4.w) * hn + N4.xyz - rad * hn));
			dist = best;
		} else if (floorIn) {
			kind = 1;
			fl = fs.x;
			fn = cos(psiF) * e1 + sin(psiF) * e2;
			dist = fs.y;
		} else {
			// leaves the shell: a straight ray in universe ex.z
			side = ex.z;
			float c = cos(ex.x);
			float sn = sin(ex.x);
			vec3 n = c * e1 + sn * e2;
			vec3 tt = c * e2 - sn * e1;
			float bR = b / wh_Rout();
			x = wh_M(side, wh_Rout() * n);
			d = wh_M(side, sqrt(max(1.0 - bR * bR, 0.0)) * n + bR * tt);
			WhHit h = wh_traceFlat(side, x, d, false);
			vec3 p = x + h.t * d;
			dist = ex.y;
			if (h.kind == 0) { kind = 0; }
			else if (h.kind == 1) { kind = 1; float ip = inversesqrt(dot(p, p)); fn = wh_M(side, p) * ip; fl = side * (dot(p, p) * ip - wh_Rout() + wh_Lsh()); dist += h.t; }
			else { kind = 2; col = h.col; nrm = h.nrm; dist += h.t; }
		}
	}
	if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;
	// the shading, as wh_renderE
	vec3 dn = d;
	vec2 ga = kind == 1 ? fn.xy : dn.xy;
	float az = wh_atan2(ga.y, ga.x);
	vec2 gq = kind == 1 ? vec2(fl, az * 24.0 / (2.0 * WH_PI)) : vec2(az, wh_asin(dn.z)) * (180.0 / WH_PI / 15.0);
	float cls = kind == 0 ? (side > 0.0 ? 0.0 : 1.0) : (kind == 1 ? 2.0 : 3.0);
	vec2 gdx = dFdx(gq + vec2(0.0, 64.0 * cls));
	vec2 gdy = dFdy(gq + vec2(0.0, 64.0 * cls));
	bool exx = abs(gdx.y) > 32.0;
	bool eyy = abs(gdy.y) > 32.0;
	vec2 fw = abs(exx ? gdy : gdx) + abs(eyy ? gdx : gdy);
	fw = exx && eyy ? vec2(1e-4) : max(fw, vec2(1e-4));
	vec3 c;
	if (kind == 0) c = wh_sky(side, dn);
	else if (kind == 1) c = wh_floor(gq, fw);
	else c = wh_shade(side, col, nrm);
	vec2 ifw = vec2(fw.y, fw.x) / (fw.x * fw.y);
	vec2 gf = abs(fract(gq + 0.5) - 0.5) * ifw;
	float line = 1.0 - clamp(min(gf.x, gf.y), 0.0, 1.0);
	c = mix(c, kind == 1 ? vec3(0.95) : (side > 0.0 ? vec3(1.0, 0.9, 0.8) : vec3(1.0)), (kind == 1 ? 0.55 : (kind == 0 ? 0.12 : 0.0)) * line);
	float fog = kind == 1 || kind == 2 ? 1.0 - exp(-dist * 0.012) : 0.0;
	ALBEDO = mix(c, side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95), fog);
}
