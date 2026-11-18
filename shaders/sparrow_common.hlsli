// Project Sparrow: frame data and the real sun shadow map for the material
// shaders, built with /D SPARROW=1 (tools/shaders/build_replace.py writes
// them to shaders/sparrow_replace; only the Sparrow edition loads that).
//
// The SDK (cvar sparrow_renderer) copies its sun shadow map (post_sun_map)
// into an R32_FLOAT texture at a fixed index of the bindless 2D table after
// the game's depth pre-pass, before the colour pass (sparrow_sun.cs.hlsl in
// the SDK):
//   rows 0 .. size-1  depth along the sun, reversed (larger = nearer the
//                     sun, 0 = nothing drawn there);
//   rows size ..      the ground ambient grid, size / 8 rows
//                     (sparrow_ambient.cs.hlsl; SparrowGroundAmbient);
//   last row          frame data: 0-2 map centre, 3 signed half width
//                     (negative: up axis flipped), 4 half depth, 5 size,
//                     6 valid, 7 bias texels, 8-10 direction toward the
//                     sun, 11 frame counter, 12 debug mode (SDK cvar
//                     sparrow_debug: 1 = no sun wherever the map covers),
//                     13 grid written this frame.
// Include after xe_common.hlsli.

#ifndef SPARROW_COMMON_HLSLI
#define SPARROW_COMMON_HLSLI

#define SPARROW_SUN_INDEX 3

// Map height in texels plus the frame row; 0 when the slot is still null.
uint SparrowSunRows() {
  uint w, h, n;
  xe_textures_2d[SPARROW_SUN_INDEX].GetDimensions(w, h, n);
  return h;
}

float SparrowMap(int2 p) {
  return xe_textures_2d[SPARROW_SUN_INDEX].Load(int4(p, 0, 0)).x;
}

// sparrow_debug (SDK cvar): 0 off, 1 no sun where the map covers, 2 only
// the light the Sparrow materials add.
int SparrowDebug() {
  uint rows = SparrowSunRows();
  return rows >= 2u ? int(SparrowMap(int2(12, int(rows) - 1)) + 0.5) : 0;
}

// Whether the Sparrow renderer is on (the SDK writes the frame row every
// frame it has scene depth): the Sparrow-only lighting additions follow it,
// so with the cvar off the ports render exactly as the game's own shaders.
// It does not need a sun: indoors and at night there is no sun map, but the
// lamps still get Sparrow's specular and the characters their materials.
// Everything that reads the map (sun shadow, sky light, bounce, the ground
// grid) checks SparrowSunValid itself and keeps the game's term without it.
bool SparrowActive() {
  return SparrowSunRows() >= 2u;
}

// Whether the SDK drew a sun map this frame.
bool SparrowSunValid() {
  uint rows = SparrowSunRows();
  return rows >= 2u && SparrowMap(int2(6, int(rows) - 1)) > 0.5;
}

// Sun visibility at a world position (1 lit, 0 shadowed, 3x3 PCF), or -1
// when the map is off or the point lies outside it: the caller then keeps
// the game's own shadow. n is the surface normal (for the normal offset);
// pass 0 for leaves, bark and ferns (no usable normal): the point then steps
// toward the sun instead.
float SparrowSunShadow(float3 pos, float3 n) {
  uint rows = SparrowSunRows();
  if (rows < 2u) return -1.0;
  int frame_row = int(rows) - 1;
  if (SparrowMap(int2(6, frame_row)) < 0.5) return -1.0;
  float3 centre = float3(SparrowMap(int2(0, frame_row)), SparrowMap(int2(1, frame_row)),
                         SparrowMap(int2(2, frame_row)));
  float signed_radius = SparrowMap(int2(3, frame_row));
  float depth_half = SparrowMap(int2(4, frame_row));
  float size = SparrowMap(int2(5, frame_row));
  float bias_texels = SparrowMap(int2(7, frame_row));
  float3 l = float3(SparrowMap(int2(8, frame_row)), SparrowMap(int2(9, frame_row)),
                    SparrowMap(int2(10, frame_row)));
  float radius = abs(signed_radius);
  if (radius <= 0.0 || depth_half <= 0.0 || size < 1.0) return -1.0;
  // The basis the SDK drew the map with (SetupSunMapFrame / post_ao.cs.hlsl).
  float3 ref = abs(l.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
  float3 right = normalize(cross(ref, l));
  float3 up = cross(l, right);
  if (signed_radius < 0.0) up = -up;
  float texel = 2.0 * radius / size;
  if (dot(n, n) < 0.25) n = l;
  float ndl = dot(n, l);
  // Facing away: no direct sun on the game's own terms either (skin wraps
  // past the terminator), so leave it to the game.
  if (ndl <= 0.0) return -1.0;
  // Normal offset, more of it at grazing angles where acne starts.
  float3 v = pos + n * (texel * bias_texels * (1.0 + 2.0 * (1.0 - ndl))) - centre;
  float x = dot(right, v) / radius, y = dot(up, v) / radius;
  float z = dot(l, v) / (2.0 * depth_half) + 0.5;
  float edge = max(abs(x), abs(y));
  if (edge >= 1.0 || z >= 1.0 || z <= 0.0) return -1.0;
  float2 uv = float2(x * 0.5 + 0.5, 0.5 - y * 0.5) * size - 0.5;
  float z_bias = texel * bias_texels / (2.0 * depth_half);
  int2 base = int2(floor(uv));
  float2 f = uv - float2(base);
  int max_texel = int(size) - 1;
  float lit[4][4];
  [unroll] for (int j = 0; j < 4; ++j) {
    [unroll] for (int i = 0; i < 4; ++i) {
      int2 q = clamp(base + int2(i - 1, j - 1), int2(0, 0), int2(max_texel, max_texel));
      lit[j][i] = SparrowMap(q) > z + z_bias ? 0.0 : 1.0;
    }
  }
  float sum = 0.0;
  [unroll] for (int j2 = 0; j2 < 3; ++j2) {
    [unroll] for (int i2 = 0; i2 < 3; ++i2) {
      float top = lerp(lit[j2][i2], lit[j2][i2 + 1], f.x);
      float bottom = lerp(lit[j2 + 1][i2], lit[j2 + 1][i2 + 1], f.x);
      sum += lerp(top, bottom, f.y);
    }
  }
  if (abs(SparrowMap(int2(12, frame_row)) - 1.0) < 0.5) return 0.0;
  return sum / 9.0;
}

// The game's shadow value combined with the map's where the map covers the
// point: shadowed if either says so (the game's cascade holds casters off
// screen; ours reaches much further).
// Shadows only the map casts keep SPARROW_MAP_LEAK of the sun: most of them
// are tree canopies, which let light through (Brightwood and Fairfax went
// darker than the game in the shade at noon).
#ifndef SPARROW_MAP_LEAK
#define SPARROW_MAP_LEAK 0.4
#endif
float SparrowSunOr(float game_shadow, float3 pos, float3 n) {
  float s = SparrowSunShadow(pos, n);
  return s < 0.0 ? game_shadow : min(game_shadow, lerp(SPARROW_MAP_LEAK, 1.0, s));
}

// No surface normal: leaves, bark, ferns.
float SparrowSunOrVolume(float game_shadow, float3 pos) {
  return SparrowSunOr(game_shadow, pos, float3(0.0, 0.0, 0.0));
}

// --- Physically based lighting ----------------------------------------------
// The game lights with Lambert diffuse in its own units (albedo * light, no
// 1/pi), so a specular lobe in the same units is pi * BRDF_spec. GGX normal
// distribution, Smith height-correlated visibility, Schlick Fresnel.
#ifndef SPARROW_F0
#define SPARROW_F0 0.04        // dielectric: stone, earth, wood, plaster
#endif

float SparrowFresnel(float f0, float vdh) {
  float k = 1.0 - saturate(vdh);
  float k2 = k * k;
  return f0 + (1.0 - f0) * k2 * k2 * k;
}

// Specular light for one light of colour `light` (already attenuated and
// shadowed) arriving along l: pi * D * V * F * N.L.
float3 SparrowSpecular(float3 n, float3 v, float3 l, float roughness, float f0, float3 light) {
  float ndl = saturate(dot(n, l));
  float ndv = max(dot(n, v), 1e-4);
  if (ndl <= 0.0) return 0.0;
  float3 h = normalize(l + v);
  float ndh = saturate(dot(n, h));
  float a = max(roughness * roughness, 0.002);
  float a2 = a * a;
  float d = ndh * ndh * (a2 - 1.0) + 1.0;
  float D = a2 / (3.14159265 * d * d);
  float gv = ndl * sqrt(ndv * ndv * (1.0 - a2) + a2);
  float gl = ndv * sqrt(ndl * ndl * (1.0 - a2) + a2);
  float V = 0.5 / max(gv + gl, 1e-5);
  float F = SparrowFresnel(f0, dot(v, h));
  return light * (3.14159265 * D * V * F * ndl);
}

// The same lobe split for a specular colour known only later (a material's
// specular map as F0): F = f0 (1 - Fk) + Fk, so the caller forms
// f0 * base + grazing.
void SparrowSpecularSplit(float3 n, float3 v, float3 l, float roughness, float3 light,
                          inout float3 base, inout float3 grazing) {
  float3 s = SparrowSpecular(n, v, l, roughness, 1.0, light);  // F = 1
  float k = 1.0 - saturate(dot(v, normalize(l + v)));
  float k2 = k * k;
  float fk = k2 * k2 * k;
  base += s * (1.0 - fk);
  grazing += s * fk;
}

// Sky reflection weight for the ambient light: Fresnel at the view angle,
// damped by roughness (rough surfaces scatter it into the diffuse they
// already have). Multiply by the ambient/sky light.
float SparrowEnvSpecular(float3 n, float3 v, float roughness, float f0) {
  float ndv = saturate(dot(n, v));
  float k = 1.0 - ndv;
  float k2 = k * k;
  float f = f0 + (max(1.0 - roughness, f0) - f0) * k2 * k2 * k;
  float smooth = 1.0 - roughness;
  return f * smooth * smooth;
}


// --- Sky light and bounce light ---------------------------------------------
// The sun map is a height field of everything the sun sees, and each of its
// texels is a sunlit surface point whose world position can be rebuilt.
//   SparrowSkyVisibility: how much of the sky above a point is open (8
//     directions x 3 distances, horizon angles from the rebuilt points).
//   SparrowBounce: sunlight bounced off the nearby sunlit points (one
//     bounce, Lambert, no occlusion between them), in the game's light
//     units per unit sun colour: multiply by the sun's colour.
#ifndef SPARROW_BOUNCE_ALBEDO
#define SPARROW_BOUNCE_ALBEDO float3(0.42, 0.36, 0.28)  // earth, sandstone, plaster
#endif
#ifndef SPARROW_BOUNCE_RADIUS
#define SPARROW_BOUNCE_RADIUS 6.0
#endif

struct SparrowFrameData {
  float3 centre, l, right, up;
  float radius, depth_half, size;
  bool valid;
};

SparrowFrameData SparrowFrame() {
  SparrowFrameData f = (SparrowFrameData)0;
  uint rows = SparrowSunRows();
  if (rows < 2u) return f;
  int fr = int(rows) - 1;
  f.valid = SparrowMap(int2(6, fr)) > 0.5;
  f.centre = float3(SparrowMap(int2(0, fr)), SparrowMap(int2(1, fr)), SparrowMap(int2(2, fr)));
  float sr = SparrowMap(int2(3, fr));
  f.radius = abs(sr);
  f.depth_half = SparrowMap(int2(4, fr));
  f.size = SparrowMap(int2(5, fr));
  f.l = float3(SparrowMap(int2(8, fr)), SparrowMap(int2(9, fr)), SparrowMap(int2(10, fr)));
  float3 ref = abs(f.l.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
  f.right = normalize(cross(ref, f.l));
  f.up = cross(f.l, f.right);
  if (sr < 0.0) f.up = -f.up;
  f.valid = f.valid && f.radius > 0.0 && f.depth_half > 0.0 && f.size >= 1.0;
  return f;
}

// The sunlit surface point the map holds at the map-plane position of
// `pos` + `offset` (world units along right / up); false where nothing is
// drawn or outside the map.
bool SparrowSunlitPoint(SparrowFrameData f, float3 pos, float2 offset, out float3 hit) {
  float3 v = pos - f.centre;
  float x = dot(f.right, v) + offset.x, y = dot(f.up, v) + offset.y;
  hit = 0.0;
  float2 m = float2(x, y) / f.radius;
  if (max(abs(m.x), abs(m.y)) >= 1.0) return false;
  // Bilinear over the four texels (ones with nothing drawn left out), so
  // heights vary smoothly between texels.
  float2 uv = float2(m.x * 0.5 + 0.5, 0.5 - m.y * 0.5) * f.size - 0.5;
  int2 b = int2(floor(uv));
  float2 fr = uv - float2(b);
  int2 hi = int2(int(f.size) - 1, int(f.size) - 1);
  float d00 = SparrowMap(clamp(b, 0, hi)), d10 = SparrowMap(clamp(b + int2(1, 0), 0, hi));
  float d01 = SparrowMap(clamp(b + int2(0, 1), 0, hi)), d11 = SparrowMap(clamp(b + int2(1, 1), 0, hi));
  float4 w4 = float4((1.0 - fr.x) * (1.0 - fr.y), fr.x * (1.0 - fr.y), (1.0 - fr.x) * fr.y, fr.x * fr.y);
  w4 *= float4(d00 > 0.0, d10 > 0.0, d01 > 0.0, d11 > 0.0);
  float wsum = dot(w4, 1.0);
  if (wsum <= 1e-4) return false;
  float d = dot(w4, float4(d00, d10, d01, d11)) / wsum;
  hit = f.centre + f.right * x + f.up * y + f.l * ((d - 0.5) * 2.0 * f.depth_half);
  return true;
}

// 0 (closed in) .. 1 (open sky), cosine-weighted for the normal n; -1
// where the map is off or does not cover the point.
float SparrowSkyVisibility(float3 pos, float3 n) {
  SparrowFrameData f = SparrowFrame();
  if (!f.valid) return -1.0;
  float3 v = pos - f.centre;
  if (max(abs(dot(f.right, v)), abs(dot(f.up, v))) >= f.radius * 0.97) return -1.0;
  // Search from half a metre out along the normal: from the face itself a
  // wall finds its own top overhead and shades itself.
  float3 origin = pos + n * 0.5;
  const float radii[3] = {0.6, 1.8, 5.0};
  // The nearest ring counts less: with eight directions a thin pole or a
  // person would block a whole 45-degree slice.
  const float ring_weight[3] = {0.5, 1.0, 1.0};
  float open = 0.0, weight = 0.0;
  [unroll] for (int k = 0; k < 8; ++k) {
    float a = (float(k) + 0.5) * (6.2831853 / 8.0);
    float2 dir = float2(cos(a), sin(a));
    float sin_h = 0.0;  // highest horizon in this direction
    float3 hdir = normalize(f.right * dir.x + f.up * dir.y);
    [unroll] for (int j = 0; j < 3; ++j) {
      float3 hit;
      if (SparrowSunlitPoint(f, origin, dir * radii[j], hit)) {
        float3 w = hit - origin;
        float len = length(w);
        if (len > 0.05) sin_h = max(sin_h, ring_weight[j] * w.z / len);
      }
    }
    // The open part of this slice above the horizon, weighted by how much
    // that part of the sky faces the surface (a vertical wall sees half).
    float facing = saturate(0.5 + 0.5 * dot(n, normalize(float3(hdir.xy, 0.0) + float3(0.0, 0.0, 1e-3))));
    float w8 = lerp(1.0, facing, saturate(1.0 - n.z));
    open += (1.0 - sin_h * sin_h) * w8;
    weight += w8;
  }
  return weight > 0.0 ? open / weight : -1.0;
}

// Bounce light per unit sun colour, in the game's light units.
float3 SparrowBounce(float3 pos, float3 n) {
  SparrowFrameData f = SparrowFrame();
  if (!f.valid) return 0.0;
  const int N = 16;
  float area = 3.14159265 * SPARROW_BOUNCE_RADIUS * SPARROW_BOUNCE_RADIUS / float(N);
  float sum = 0.0;
  [unroll] for (int k = 0; k < N; ++k) {
    // Spiral over the disc (golden angle), denser near the point.
    float r = SPARROW_BOUNCE_RADIUS * sqrt((float(k) + 0.5) / float(N));
    float a = float(k) * 2.3999632;
    float3 hit;
    if (!SparrowSunlitPoint(f, pos, float2(cos(a), sin(a)) * r, hit)) continue;
    float3 w = hit - pos;
    float d2 = max(dot(w, w), 0.25);
    w *= rsqrt(d2);
    float cos_r = saturate(dot(n, w));
    float cos_p = saturate(dot(-w, f.l) + 0.3);  // patch roughly faces the sun
    sum += cos_r * cos_p / d2;
  }
  return SPARROW_BOUNCE_ALBEDO * (sum * area / 3.14159265);
}

#ifndef SPARROW_SKY
#define SPARROW_SKY 1.0      // how much the sky's openness shapes the ambient
#endif
#ifndef SPARROW_BOUNCE
#define SPARROW_BOUNCE 1.0
#endif
// The sky light kept where the sun map sees no open sky at all: under a tree
// canopy the map's heights are solid, but leaves let light through and the
// game's baked light already darkens the ground there. Applied as
// vis + F (1 - vis)^2: closed-in points keep F of the game's ambient, while
// half-open ones (an arch: 0.67 -> 0.71) barely move.
#ifndef SPARROW_SKY_FLOOR
#define SPARROW_SKY_FLOOR 0.85
#endif
float SparrowSkyTerm(float vis) {
  float c = 1.0 - vis;
  return lerp(1.0, vis + SPARROW_SKY_FLOOR * c * c, SPARROW_SKY);
}

// --- Ground ambient grid -----------------------------------------------------
// The SDK works out sky visibility and bounce once a frame, one cell per
// 8 x 8 map texels, with the same search as above (sparrow_ambient.cs.hlsl).
// A cell is the line along the sun through its centre: a ground point maps
// to it whatever its height, and the cell holds the visibility at four
// heights spanning the occluders around, so the lookup interpolates at the
// point's own height (the ground itself is not in the map: it is drawn as
// blended colour-pass layers). Bilinear over four cells. -2: no grid this
// frame, -3: outside the map.
float SparrowGroundAmbient(float3 pos, out float bounce) {
  bounce = 0.0;
  uint rows = SparrowSunRows();
  if (rows < 2u) return -2.0;
  int fr = int(rows) - 1;
  if (SparrowMap(int2(6, fr)) < 0.5 || SparrowMap(int2(13, fr)) < 0.5) return -2.0;
  SparrowFrameData f = SparrowFrame();
  if (!f.valid) return -2.0;
  int size = int(f.size), g = size / 8;
  float3 v = pos - f.centre;
  float2 m = float2(dot(f.right, v), dot(f.up, v)) / f.radius;
  if (max(abs(m.x), abs(m.y)) >= 0.97) return -3.0;
  float2 uv = float2(m.x * 0.5 + 0.5, 0.5 - m.y * 0.5) * float(g) - 0.5;
  int2 b = int2(floor(uv));
  float2 fu = uv - float2(b);
  float vis = 0.0;
  [unroll] for (int k = 0; k < 4; ++k) {
    int2 o = int2(k & 1, k >> 1);
    int2 c = clamp(b + o, 0, g - 1);
    float w = (o.x ? fu.x : 1.0 - fu.x) * (o.y ? fu.y : 1.0 - fu.y);
    int row = size + c.y;
    float lo = SparrowMap(int2(4 * g + c.x, row)), hi = SparrowMap(int2(5 * g + c.x, row));
    float t = saturate((pos.z - lo) / max(hi - lo, 0.01)) * 3.0;
    float v0 = SparrowMap(int2(c.x, row)), v1 = SparrowMap(int2(g + c.x, row));
    float v2 = SparrowMap(int2(2 * g + c.x, row)), v3 = SparrowMap(int2(3 * g + c.x, row));
    float cv = t < 1.0 ? lerp(v0, v1, t) : (t < 2.0 ? lerp(v1, v2, t - 1.0) : lerp(v2, v3, t - 2.0));
    vis += w * cv;
    bounce += w * SparrowMap(int2(6 * g + c.x, row));
  }
  return saturate(vis);
}

// SparrowAmbient for upward-facing ground through the grid (n: the surface
// normal; steep faces keep the game's ambient).
float3 SparrowGroundAmbientLight(float3 ambient, float3 pos, float3 n, float3 sun, out float vis_out) {
  vis_out = -1.0;
  if (n.z < 0.6) return ambient;
  float bounce;
  float vis = SparrowGroundAmbient(pos, bounce);
  vis_out = vis;
  if (vis < 0.0) return ambient;
  vis_out = vis;
  return ambient * SparrowSkyTerm(vis) +
         SPARROW_BOUNCE_ALBEDO * bounce * saturate(n.z) * sun * SPARROW_BOUNCE;
}

// SparrowAmbient for foliage (bushes, grass clumps, leaves): their normals
// point every way, so the sky visibility comes from the ground grid at the
// point's height, and the bounce is spread over all sides (half).
float3 SparrowFoliageAmbient(float3 ambient, float3 pos, float3 sun, out float vis_out) {
  float bounce;
  float vis = SparrowGroundAmbient(pos, bounce);
  vis_out = vis;
  if (vis < 0.0) return ambient;
  return ambient * SparrowSkyTerm(vis) + 0.5 * SPARROW_BOUNCE_ALBEDO * bounce * sun * SPARROW_BOUNCE;
}

// The faint sky sheen the cobbles have (path.ps.hlsl, SPARROW_SKY_REFLECT),
// for the dirt and earth around them: without it the sheen stops at the
// cobble layer's edge and draws a straight line there. ambient: the
// material's ambient light (game units, before albedo); v: toward the camera.
#ifndef SPARROW_GROUND_SHEEN
#define SPARROW_GROUND_SHEEN 0.25
#endif
#ifndef SPARROW_GROUND_ROUGHNESS
#define SPARROW_GROUND_ROUGHNESS 0.55
#endif
float3 SparrowGroundSheen(float3 ambient, float3 n, float3 v) {
  return ambient * SparrowEnvSpecular(n, v, SPARROW_GROUND_ROUGHNESS, SPARROW_F0) * SPARROW_GROUND_SHEEN;
}

// --- Character highlights ----------------------------------------------------
// The game draws characters nearly matte: their specular maps are close to
// zero on hair, clothes and skin, so the map cannot tell cloth, leather and
// metal apart. Instead the SDK tags each character draw with a material from
// a table of albedo texture hashes (shaders/sparrow_replace/
// character_materials.txt, xe_flags bits 29-30):
//   0 cloth   (unlisted) a soft dielectric lobe and a faint grazing sky sheen,
//                        the fabric's rim; the look the user approved first
//   1 leather            a tighter, brighter dielectric lobe
//   2 metal              a sharp lobe tinted by the albedo (F0 = albedo) and
//                        a strong sky reflection; the diffuse stays, since the
//                        game's albedo has the metal's shading painted in
//   3 gloss              polished dielectric (lacquer, jewel, wet skin)
// light: the light's colour, attenuated and shadowed but without N.L;
// ambient: the ambient light in game units (times c27.w), before the albedo.
#ifndef SPARROW_CHAR_ROUGH
#define SPARROW_CHAR_ROUGH 0.6
#endif
#ifndef SPARROW_CHAR_SPEC
#define SPARROW_CHAR_SPEC 1.0
#endif
#ifndef SPARROW_CHAR_SHEEN
#define SPARROW_CHAR_SHEEN 0.5
#endif
#ifndef SPARROW_LEATHER_ROUGH
#define SPARROW_LEATHER_ROUGH 0.42
#endif
#ifndef SPARROW_LEATHER_SPEC
#define SPARROW_LEATHER_SPEC 1.3
#endif
#ifndef SPARROW_METAL_ROUGH
#define SPARROW_METAL_ROUGH 0.32
#endif
#ifndef SPARROW_METAL_SPEC
#define SPARROW_METAL_SPEC 1.0
#endif
#ifndef SPARROW_METAL_SHEEN
#define SPARROW_METAL_SHEEN 1.5
#endif
#ifndef SPARROW_GLOSS_ROUGH
#define SPARROW_GLOSS_ROUGH 0.22
#endif
struct SparrowCharMat {
  float rough;
  float f0;
  float3 tint;   // colour of the highlight (white for dielectrics)
  float spec;    // light lobe scale
  float sheen;   // sky reflection scale
};
uint SparrowCharMaterialId() { return (xe_flags >> 29) & 3u; }
// albedo: the colour map (TF0) in linear terms (squared).
SparrowCharMat SparrowCharMaterial(float3 albedo) {
  SparrowCharMat m;
  m.rough = SPARROW_CHAR_ROUGH; m.f0 = SPARROW_F0; m.tint = 1.0;
  m.spec = SPARROW_CHAR_SPEC; m.sheen = SPARROW_CHAR_SHEEN;
  uint id = SparrowCharMaterialId();
  if (id == 1u) {
    m.rough = SPARROW_LEATHER_ROUGH; m.spec = SPARROW_LEATHER_SPEC;
  } else if (id == 2u) {
    float lum = max(dot(albedo, float3(0.2126, 0.7152, 0.0722)), 1e-3);
    m.rough = SPARROW_METAL_ROUGH;
    m.f0 = saturate(lum);
    m.tint = saturate(albedo / lum);
    m.spec = SPARROW_METAL_SPEC; m.sheen = SPARROW_METAL_SHEEN;
  } else if (id == 3u) {
    m.rough = SPARROW_GLOSS_ROUGH; m.f0 = 0.05;
  }
  return m;
}
// sparrow_debug 4: a strong material colour on characters (none on cloth,
// orange leather, cyan metal, magenta gloss), added through the sheen, which
// every character shader adds exactly once.
float3 SparrowCharMaterialDebug() {
  if (SparrowDebug() != 4) return 0.0;
  uint id = SparrowCharMaterialId();
  return id == 1u ? float3(8.0, 3.0, 0.0) : id == 2u ? float3(0.0, 6.0, 8.0)
       : id == 3u ? float3(8.0, 0.0, 8.0) : float3(0.0, 0.0, 0.0);
}
float3 SparrowCharacterSpecular(float3 n, float3 v, float3 l, float3 light, SparrowCharMat m) {
  return SparrowSpecular(n, v, l, m.rough, m.f0, light) * (m.tint * m.spec);
}
float3 SparrowCharacterSheen(float3 ambient, float3 n, float3 v, SparrowCharMat m) {
  return ambient * SparrowEnvSpecular(n, v, m.rough, m.f0) * (m.tint * m.sheen) +
         SparrowCharMaterialDebug();
}

// --- Lit world materials with several lights -----------------------------------
// The Sparrow specular of a lit material (lit4.ps.hlsl's, generalised): GGX
// for each light with the game's specular map as F0 (floor SPARROW_F0), its
// shininess setting the roughness, plus a damped sky reflection of the
// ambient. Character draws (the dynamic-mesh flag) get their material's lobe
// and sheen instead. The caller drops the game's own Phong specular.
//   n, v       surface normal and direction to the camera
//   l[k]       direction to light k; light[k] its colour times attenuation and
//              shadow (no N.L), zero for unused slots
//   spec_map   the specular map (linear); albedo: the colour map (linear)
//   ambient    the ambient light in game units, before the albedo (* c27.w)
#define SPARROW_MAX_LIGHTS 7

// A lit shader's light from its constants, as the game's shaders work it out
// (lit4 / lit7 slots: position c80+k with w = 0 for a direction, range
// c96[k], spot axis c98+k, spot offset c105[k] and scale c107[k], spot amount
// c94[k]; lights 4-6 use c84+, c97, c102+, c106, c108, c95). Returns the
// direction to the light; atten = 1 + amount * (spot * range - 1).
float3 SparrowGameLight(float3 pos, float4 lp, float range, float3 spot_axis, float spot_offset,
                        float spot_scale, float spot_amount, out float atten) {
  float3 d = lp.xyz - pos * lp.w;
  float len = length(d);
  float3 l = d / max(len, 1e-6);
  float r = saturate(1.0 - len * range);
  float s = saturate((dot(l, spot_axis) - spot_offset) * spot_scale);
  atten = (s * r - 1.0) * spot_amount + 1.0;
  return l;
}
// Lights 0-3 / 4-6 of a lit shader into l[] / c[] (colour * shadow mask *
// attenuation); `mask` is the game's per-light shadow factor (1 = lit). Use
// where the shader defines C80..C107 / C84..C108 (expanded at the use site).
#define SPARROW_GAME_LIGHT(k, pos, P, R, A, O, S, M, COL, mask, l, c) \
  { float a_; l[k] = SparrowGameLight(pos, P, R, A.xyz, O, S, M, a_); c[k] = COL.xyz * ((mask) * a_); }
#define SPARROW_GAME_LIGHTS_0_3(pos, mask, l, c) \
  SPARROW_GAME_LIGHT(0, pos, C80, C96.x, C98, C105.x, C107.x, C94.x, C87, (mask).x, l, c) \
  SPARROW_GAME_LIGHT(1, pos, C81, C96.y, C99, C105.y, C107.y, C94.y, C88, (mask).y, l, c) \
  SPARROW_GAME_LIGHT(2, pos, C82, C96.z, C100, C105.z, C107.z, C94.z, C89, (mask).z, l, c) \
  SPARROW_GAME_LIGHT(3, pos, C83, C96.w, C101, C105.w, C107.w, C94.w, C90, (mask).w, l, c)
#define SPARROW_GAME_LIGHTS_4_6(pos, mask, l, c) \
  SPARROW_GAME_LIGHT(4, pos, C84, C97.x, C102, C106.x, C108.x, C95.x, C91, (mask).x, l, c) \
  SPARROW_GAME_LIGHT(5, pos, C85, C97.y, C103, C106.y, C108.y, C95.y, C92, (mask).y, l, c) \
  SPARROW_GAME_LIGHT(6, pos, C86, C97.z, C104, C106.z, C108.z, C95.z, C93, (mask).z, l, c)
// --- Lamp shadows -----------------------------------------------------------------
// Screen-space shadows for the game's point lights: from the pixel toward the
// lamp through the scene depth the SDK copies after the depth pre-pass
// (SystemBindlessView::kSparrowDepth, sparrow_depth.cs.hlsl), with the camera
// in the frame row (16-39, sparrow_sun.cs.hlsl). The camera is last frame's
// (the game resolves its depth before it draws), so each pixel shifts the
// march by the difference between where last frame's camera puts it and
// where it is drawn. Anything in front of the ray by up to
// SPARROW_LAMP_THICKNESS world units blocks the lamp; off screen counts as lit.
#define SPARROW_DEPTH_INDEX 4
#ifndef SPARROW_LAMP_STEPS
#define SPARROW_LAMP_STEPS 12
#endif
#ifndef SPARROW_LAMP_THICKNESS
#define SPARROW_LAMP_THICKNESS 1.5
#endif
// Stop this far short of the lamp: its own lantern and post sit around it.
#ifndef SPARROW_LAMP_STOP
#define SPARROW_LAMP_STOP 0.6
#endif

struct SparrowCamera {
  float4x4 m;      // world -> clip rows
  float alpha, beta, zs, zo;
  float2 size;     // depth texture size in pixels
  bool y_down;
  float2 shift;    // this pixel's shift since last frame's camera
  bool valid;
};

float2 SparrowCameraPixel(SparrowCamera cam, float4 c) {
  float2 ndc = c.xy / c.w;
  return float2(ndc.x * 0.5 + 0.5, cam.y_down ? ndc.y * 0.5 + 0.5 : 0.5 - ndc.y * 0.5) * cam.size;
}

// sparrow_debug 5 shows the lamp shadows alone (white lit, black shadowed);
// 6 turns them off (A/B).
SparrowCamera SparrowCameraFor(float3 pos, float2 svpos) {
  SparrowCamera cam = (SparrowCamera)0;
  uint rows = SparrowSunRows();
  if (rows < 2u) return cam;
  int fr = int(rows) - 1;
  if (SparrowMap(int2(39, fr)) < 0.5) return cam;
  if (abs(SparrowMap(int2(12, fr)) - 6.0) < 0.5) return cam;  // sparrow_debug 6: off
  [unroll] for (int r = 0; r < 4; ++r) {
    cam.m[r] = float4(SparrowMap(int2(16 + r * 4, fr)), SparrowMap(int2(17 + r * 4, fr)),
                      SparrowMap(int2(18 + r * 4, fr)), SparrowMap(int2(19 + r * 4, fr)));
  }
  cam.alpha = SparrowMap(int2(32, fr));
  cam.beta = SparrowMap(int2(33, fr));
  cam.zs = SparrowMap(int2(34, fr));
  cam.zo = SparrowMap(int2(35, fr));
  cam.size = float2(SparrowMap(int2(36, fr)), SparrowMap(int2(37, fr)));
  cam.y_down = SparrowMap(int2(38, fr)) > 0.5;
  float4 c = mul(cam.m, float4(pos, 1.0));
  if (c.w <= 0.05) return cam;
  cam.shift = svpos - SparrowCameraPixel(cam, c);
  // A large shift is not the camera moving but the game drawing the screen
  // in EDRAM tiles (the lower tile's pixels are offset): no correction then.
  if (any(abs(cam.shift) > 24.0)) cam.shift = 0.0;
  cam.valid = true;
  return cam;
}

// 1 lit, 0 blocked, for a point light at lp (w = 1; a direction, w = 0,
// is the sun's and stays lit here).
// range: the light's c96 entry (it reaches 1 / range).
float SparrowLampShadow(SparrowCamera cam, float3 pos, float2 svpos, float3 n, float4 lp,
                        float range) {
  if (!cam.valid || lp.w < 0.5) return 1.0;
  float3 to_light = lp.xyz - pos;
  // A light behind the surface lights none of it (the game's own shading):
  // no march, which would only find the surface itself.
  if (dot(n, to_light) <= 0.0) return 1.0;
  float len = length(to_light);
  if (len < 2.0 * SPARROW_LAMP_STOP || len * range >= 1.0) return 1.0;
  float3 end = lp.xyz - to_light * (SPARROW_LAMP_STOP / len);
  float4 c0 = mul(cam.m, float4(pos, 1.0));
  float4 c1 = mul(cam.m, float4(end, 1.0));
  const float kNear = 0.05;
  if (c0.w <= kNear) return 1.0;
  if (c1.w <= kNear) c1 = lerp(c0, c1, (c0.w - kNear) / (c0.w - c1.w));
  float2 p0 = SparrowCameraPixel(cam, c0) + cam.shift;
  float2 p1 = SparrowCameraPixel(cam, c1) + cam.shift;
  float px = length(p1 - p0);
  if (px < 2.0) return 1.0;
  // Start a few pixels out (the surface itself), jittered per pixel.
  float t0 = min(3.0 / px, 0.5);
  float jitter = frac(52.9829189 * frac(dot(svpos, float2(0.06711056, 0.00583715))));
  [loop] for (int i = 0; i < SPARROW_LAMP_STEPS; ++i) {
    float t = lerp(t0, 1.0, (float(i) + jitter) / float(SPARROW_LAMP_STEPS));
    float4 c = lerp(c0, c1, t);
    float2 p = SparrowCameraPixel(cam, c) + cam.shift;
    if (any(p < 0.0) || any(p >= cam.size)) break;
    float d = xe_textures_2d[SPARROW_DEPTH_INDEX].Load(int4(int2(p), 0, 0)).x;
    float z = (d - cam.zo) / cam.zs;
    float w_buf = cam.beta / (z - cam.alpha);
    float bias = 0.05 + 0.01 * c.w;
    if (w_buf > 0.0 && w_buf < c.w - bias && w_buf > c.w - SPARROW_LAMP_THICKNESS) return 0.0;
  }
  return 1.0;
}

// The four lights of a lit shader's c80..c83 with ranges c96 (lights 4-6:
// c84..c86, c97; pass w = 0 for a missing light).
float4 SparrowLampShadows4(float3 pos, float2 svpos, float4 l0, float4 l1, float4 l2, float4 l3,
                           float4 range) {
  SparrowCamera cam = SparrowCameraFor(pos, svpos);
  // The surface's facing normal from the screen derivatives (moving right,
  // moving down the screen).
  float3 n = cross(ddy(pos), ddx(pos));
  return float4(SparrowLampShadow(cam, pos, svpos, n, l0, range.x),
                SparrowLampShadow(cam, pos, svpos, n, l1, range.y),
                SparrowLampShadow(cam, pos, svpos, n, l2, range.z),
                SparrowLampShadow(cam, pos, svpos, n, l3, range.w));
}
// sparrow_debug 7: whether this pixel is in the depth copy (green: its
// depth matches; red: something else, or nothing, is there).
float3 SparrowDepthCheck(float3 pos, float2 svpos) {
  SparrowCamera cam = SparrowCameraFor(pos, svpos);
  float4 c = mul(cam.m, float4(pos, 1.0));
  if (!cam.valid) return float3(0.0, 0.0, 0.5);
  float d = xe_textures_2d[SPARROW_DEPTH_INDEX].Load(int4(int2(SparrowCameraPixel(cam, c) + cam.shift), 0, 0)).x;
  float w_buf = cam.beta / ((d - cam.zo) / cam.zs - cam.alpha);
  return abs(w_buf - c.w) < 0.1 + 0.01 * c.w ? float3(0.0, 0.5, 0.0) : float3(0.5, 0.0, 0.0);
}
// --- Reflections ------------------------------------------------------------------
// Screen-space reflections: the reflected ray marched through last frame's
// scene depth (kSparrowDepth) with its camera, and at a hit last frame's
// scene colour (kSparrowColor, sparrow_color.cs.hlsl) there. Returns the
// colour in the target's units (exposure and colour exponent bias
// included: divide by both before mixing into a material's light) and a
// weight (0 = no hit: keep the material's own sky reflection). Fades at
// the screen edges, toward the end of the ray and on rough surfaces.
// sparrow_debug 8 shows the reflections alone, 9 turns them off.
#define SPARROW_COLOR_INDEX 5
#ifndef SPARROW_REFL_STEPS
#define SPARROW_REFL_STEPS 24
#endif
#ifndef SPARROW_REFL_DIST
#define SPARROW_REFL_DIST 80.0     // world units along the ray
#endif
#ifndef SPARROW_REFL_MAX_ROUGH
#define SPARROW_REFL_MAX_ROUGH 0.6
#endif

float4 SparrowReflection(float3 pos, float2 svpos, float3 n, float3 v, float rough) {
  if (rough >= SPARROW_REFL_MAX_ROUGH || abs(SparrowDebug() - 9.0) < 0.5) return 0.0;
  SparrowCamera cam = SparrowCameraFor(pos, svpos);
  if (!cam.valid) return 0.0;
  float3 r = reflect(-v, n);
  if (dot(r, n) <= 0.0) return 0.0;
  float4 c0 = mul(cam.m, float4(pos, 1.0));
  float4 c1 = mul(cam.m, float4(pos + r * SPARROW_REFL_DIST, 1.0));
  const float kNear = 0.05;
  if (c0.w <= kNear) return 0.0;
  if (c1.w <= kNear) c1 = lerp(c0, c1, (c0.w - kNear) / (c0.w - c1.w));
  float2 p0 = SparrowCameraPixel(cam, c0) + cam.shift;
  float px = length(SparrowCameraPixel(cam, c1) + cam.shift - p0);
  if (px < 2.0) return 0.0;
  float t0 = min(2.0 / px, 0.5);
  float jitter = frac(52.9829189 * frac(dot(svpos, float2(0.06711056, 0.00583715))));
  float t_prev = t0;
  float w_prev = c0.w;
  [loop] for (int i = 0; i < SPARROW_REFL_STEPS; ++i) {
    // Denser near the surface, where most reflections are found.
    float f = (float(i) + jitter) / float(SPARROW_REFL_STEPS);
    float t = lerp(t0, 1.0, f * f);
    float4 c = lerp(c0, c1, t);
    float2 p = SparrowCameraPixel(cam, c) + cam.shift;
    if (any(p < 0.0) || any(p >= cam.size)) break;
    float d = xe_textures_2d[SPARROW_DEPTH_INDEX].Load(int4(int2(p), 0, 0)).x;
    float w_buf = cam.beta / ((d - cam.zo) / cam.zs - cam.alpha);
    // A hit: the ray went behind the surface since the last step, and the
    // surface is not far in front of where the ray was (then it is an
    // occluder the ray passes behind, not what it reflects).
    float thick = 0.3 + 0.03 * c.w;
    if (w_buf > 0.0 && w_buf < c.w - 0.02 && w_buf > min(w_prev, c.w) - thick) {
      // Refine between the last miss and this hit.
      float lo = t_prev, hi = t;
      [unroll] for (int k = 0; k < 4; ++k) {
        float tm = 0.5 * (lo + hi);
        float4 cm = lerp(c0, c1, tm);
        float2 pm = SparrowCameraPixel(cam, cm) + cam.shift;
        float dm = xe_textures_2d[SPARROW_DEPTH_INDEX].Load(int4(int2(pm), 0, 0)).x;
        float wm = cam.beta / ((dm - cam.zo) / cam.zs - cam.alpha);
        if (wm > 0.0 && wm < cm.w - 0.02) hi = tm; else lo = tm;
      }
      float4 ch = lerp(c0, c1, hi);
      float2 ph = clamp(SparrowCameraPixel(cam, ch) + cam.shift, 0.0, cam.size - 1.0);
      float3 col = xe_textures_2d[SPARROW_COLOR_INDEX].Load(int4(int2(ph), 0, 0)).rgb;
      float2 edge = min(ph, cam.size - ph) / (0.08 * cam.size);
      float wgt = saturate(min(edge.x, edge.y));
      wgt *= 1.0 - smoothstep(0.6, 1.0, hi);
      wgt *= saturate((SPARROW_REFL_MAX_ROUGH - rough) / 0.3);
      return float4(col, wgt);
    }
    t_prev = t;
    w_prev = c.w;
  }
  return 0.0;
}

// The reflection as light for a material to add: to_light is what the
// shader multiplies its light by on the way out (exposure, tints, colour
// exponent bias); Fresnel and roughness from SparrowEnvSpecular. .a = the
// weight, for fading out the material's own sky / cube reflection.
float4 SparrowReflectLight(float3 pos, float2 svpos, float3 n, float3 v, float rough, float f0,
                           float3 to_light, float strength) {
  float4 r = SparrowReflection(pos, svpos, n, v, rough);
  r.rgb *= SparrowEnvSpecular(n, v, rough, f0) * r.a * strength / max(to_light, 1e-6);
  return r;
}

// --- Rain-wet ground ----------------------------------------------------------
// The SDK raises the wetness (frame row 14) while the game's rain draws and
// lets it fall slowly after (sparrow_rain_ps, sparrow_wet). Water fills a
// porous surface (darker) and smooths it; on flat ground it pools into
// puddles that mirror the scene. World z is up.
float SparrowWetness() {
  uint rows = SparrowSunRows();
  return rows >= 2u ? saturate(SparrowMap(int2(14, int(rows) - 1))) : 0.0;
}

float SparrowValueNoise(float2 p) {
  float2 i = floor(p), f = frac(p);
  f = f * f * (3.0 - 2.0 * f);
  float4 h = frac(sin(float4(dot(i, float2(127.1, 311.7)), dot(i + float2(1, 0), float2(127.1, 311.7)),
                             dot(i + float2(0, 1), float2(127.1, 311.7)),
                             dot(i + float2(1, 1), float2(127.1, 311.7)))) * 43758.5453);
  return lerp(lerp(h.x, h.y, f.x), lerp(h.z, h.w, f.x), f.y);
}

#ifndef SPARROW_WET_DARKEN
#define SPARROW_WET_DARKEN 0.55  // diffuse kept where soaked (wet stone and earth darken)
#endif
#ifndef SPARROW_WET_ROUGH
#define SPARROW_WET_ROUGH 0.2    // roughness of a soaked surface (water film)
#endif
#ifndef SPARROW_PUDDLE_ROUGH
#define SPARROW_PUDDLE_ROUGH 0.03
#endif
#ifndef SPARROW_PUDDLE_DARKEN
#define SPARROW_PUDDLE_DARKEN 0.4  // diffuse kept under standing water
#endif
#ifndef SPARROW_WET_SKY
#define SPARROW_WET_SKY 0.6  // sky sheen strength where wet (dry: the material's own)
#endif
#ifndef SPARROW_PUDDLE_SCALE
#define SPARROW_PUDDLE_SCALE 0.3  // puddle noise frequency per world unit
#endif

struct SparrowWet {
  float film;    // 0..1 water on the surface
  float puddle;  // 0..1 standing water
};

// cavity 0..1: gaps and crevices, which fill first. n: the shading normal;
// geo_up: how much the surface faces up (geometric, 0 walls, 1 floor).
SparrowWet SparrowWetGround(float3 pos, float cavity, float geo_up) {
  SparrowWet w = (SparrowWet)0;
  float wet = SparrowWetness();
  if (wet <= 0.0) return w;
  float up = saturate((geo_up - 0.55) / 0.35);  // water runs off slopes and walls
  w.film = wet * lerp(0.35, 1.0, up);
  float p = SparrowValueNoise(pos.xy * SPARROW_PUDDLE_SCALE) * 0.7 +
            SparrowValueNoise(pos.xy * SPARROW_PUDDLE_SCALE * 3.7 + 17.0) * 0.3;
  // Puddles form once the ground is soaked and spread as the rain goes on.
  float soak = saturate(wet * 1.6 - 0.4);
  // Water only stands on near-level ground.
  float level = saturate((geo_up - 0.93) / 0.05);
  w.puddle = smoothstep(0.7 - 0.1 * soak, 0.74 - 0.1 * soak, p + 0.15 * cavity) * level * soak;
  return w;
}

// Applies the water to a material's diffuse and roughness, and flattens the
// normal in the puddles (standing water is a level mirror).
void SparrowApplyWet(SparrowWet w, inout float3 diffuse, inout float rough, inout float3 n) {
  diffuse *= lerp(lerp(1.0, SPARROW_WET_DARKEN, w.film), SPARROW_PUDDLE_DARKEN, w.puddle);
  rough = lerp(rough, min(rough, SPARROW_WET_ROUGH), w.film);
  rough = lerp(rough, SPARROW_PUDDLE_ROUGH, w.puddle);
  n = normalize(lerp(n, float3(0.0, 0.0, 1.0), w.puddle * 0.9));
}

// For the ground shaders whose only Sparrow specular is the sky sheen
// (terrain, splats): darkens their finished light where wet and returns the
// light to add (the sheen, stronger where wet, and where wet the
// screen-space reflection). sky = the sheen's ambient (ambient x C11.x);
// to_light as SparrowReflectLight's. Dry, it is SparrowGroundSheen.
float3 SparrowGroundWetSheen(inout float3 lit, float3 sky, float3 pos, float2 svpos, float3 n,
                             float3 v, float to_light, out SparrowWet w) {
  float3 geo = normalize(cross(ddy(pos), ddx(pos)));
  w = SparrowWetGround(pos, 0.0, abs(geo.z));
  float amt = saturate(w.film + w.puddle);
  float rough = SPARROW_GROUND_ROUGHNESS;
  SparrowApplyWet(w, lit, rough, n);
  float4 refl = 0.0;
  if (amt > 0.0) refl = SparrowReflectLight(pos, svpos, n, v, rough, SPARROW_F0, to_light, 1.0);
  return sky * SparrowEnvSpecular(n, v, rough, SPARROW_F0) * lerp(SPARROW_GROUND_SHEEN, SPARROW_WET_SKY, amt) *
             (1.0 - refl.a) + refl.rgb;
}

// sparrow_debug 10: the wet mask.
float3 SparrowWetDebug(SparrowWet w) {
  return lerp(float3(0.0, w.film, w.film), float3(0.0, 0.2, 1.0), w.puddle);
}

// --- Surface relief (parallax occlusion) --------------------------------------
// The game's ground has no height maps, so the height is the colour's
// brightness (worn stone tops are light, the dirt between them dark): the
// view ray is marched through that height field below the surface and the
// textures are read where it lands, so the stones stand up and hide the
// gaps behind them. A short march toward the sun then shadows the gaps.
// sparrow_debug 11 turns it off (A/B), 12 shows the height.
#ifndef SPARROW_RELIEF_DEPTH
#define SPARROW_RELIEF_DEPTH 0.03  // world units from the tops to the bottom of the gaps
#endif
#ifndef SPARROW_RELIEF_FAR
#define SPARROW_RELIEF_FAR 18.0   // fades out by this distance (also saves the cost)
#endif

struct SparrowReliefFrame {
  float2 dir;        // uv change from the top to the full depth along the view ray
  float2 sun_dir;    // uv change rising the full depth toward the sun (0: no sun)
  float2 dx, dy;     // the uv's screen derivatives, for sampling the offset uv
  float fade;        // 0 off .. 1 full
};

// pos world position, uv the textures' uv, v toward the camera (unit),
// dist the camera distance.
SparrowReliefFrame SparrowReliefSetup(float3 pos, float2 uv, float3 v, float dist, float depth) {
  SparrowReliefFrame r = (SparrowReliefFrame)0;
  float3 dp1 = ddx(pos), dp2 = ddy(pos);
  float2 duv1 = ddx(uv), duv2 = ddy(uv);
  r.dx = ddx_coarse(uv);
  r.dy = ddy_coarse(uv);
  if (SparrowDebug() == 11) return r;
  float3 n = normalize(cross(dp2, dp1));
  if (dot(n, v) < 0.0) n = -n;
  // The uv's gradients over the surface (world units -> uv).
  float3 p2 = cross(dp2, n), p1 = cross(n, dp1);
  float det = dot(dp1, p2);
  if (abs(det) < 1e-12) return r;
  float3 gu = (p2 * duv1.x + p1 * duv2.x) / det;
  float3 gv = (p2 * duv1.y + p1 * duv2.y) / det;
  r.fade = 1.0 - smoothstep(SPARROW_RELIEF_FAR * 0.6, SPARROW_RELIEF_FAR, dist);
  float vn = max(dot(n, v), 0.25);  // grazing rays would smear the texture
  r.dir = -float2(dot(gu, v), dot(gv, v)) / vn * depth * r.fade;
  SparrowFrameData f = SparrowFrame();
  if (f.valid) {
    float ln = dot(n, f.l);
    if (ln > 0.05) r.sun_dir = float2(dot(gu, f.l), dot(gv, f.l)) / ln * depth * r.fade;
  }
  return r;
}

// After the relief moved the base uv, each texture read from it samples with
// the base uv's own derivatives times that texture's uv scale (its uv is
// base * scale + offset), not the moved uv's (which jump per pixel).
static bool sp_relief_on = false;
static float2 sp_relief_dx = 0.0, sp_relief_dy = 0.0;
void SparrowReliefGrads(float2 scale) {
  xe_grad_override = sp_relief_on;
  xe_grad_dx = sp_relief_dx * scale;
  xe_grad_dy = sp_relief_dy * scale;
}

// Starts the relief for a surface: base_uv the uv the shader's textures
// derive from, depth in world units. Returns the frame (fade 0: off).
SparrowReliefFrame SparrowReliefBegin(float3 pos, float3 cam, float2 base_uv, float depth) {
  float3 to_cam = cam - pos;
  float d = length(to_cam);
  return SparrowReliefSetup(pos, base_uv, to_cam / max(d, 1e-4), d, depth);
}

#ifndef SPARROW_RELIEF_CONTRAST
#define SPARROW_RELIEF_CONTRAST 2.5
#endif
// Defines P##Relief(base_uv, svpos, frame, scale, shadow_on, out h, out
// shadow) for a shader whose colour at a base uv is RGB(base_uv) (a
// function it defines; scale = that texture's uv scale). The height is the
// colour's brightness against the area's average (five mips up), so it
// does not depend on how bright the texture is, read three mips blurrier
// (rounded stones rather than the speckle of their grain; sharper reads
// turn the grain into spikes). The view ray is marched down through it
// (tops at 1) in 16 jittered steps; with shadow_on a march toward the sun
// gives how much higher ground shades the point (its reach doubled, so the
// gaps darken under a high sun too). Returns the base uv where it lands.
#define SPARROW_RELIEF_FUNCS(P, RGB)                                                    \
  static float P##_base = 0.5;                                                          \
  float P##Lum(float2 b) { return dot(RGB(b), float3(0.299, 0.587, 0.114)); }           \
  float P##Height(float2 b) {                                                           \
    return saturate(0.55 + (P##Lum(b) / max(P##_base, 0.02) - 1.0) *                    \
                               SPARROW_RELIEF_CONTRAST * 0.5);                          \
  }                                                                                     \
  float2 P##Relief(float2 uv, float2 svpos, SparrowReliefFrame r, float2 scale,         \
                   bool shadow_on, out float h_hit, out float shadow) {                 \
    shadow = 1.0;                                                                       \
    xe_grad_override = true;                                                            \
    xe_grad_dx = r.dx * scale * 32.0;                                                   \
    xe_grad_dy = r.dy * scale * 32.0;                                                   \
    P##_base = P##Lum(uv);                                                              \
    xe_grad_dx = r.dx * scale * 8.0;                                                    \
    xe_grad_dy = r.dy * scale * 8.0;                                                    \
    float t_prev = 0.0, gap_prev = 1.0 - P##Height(uv), t = 1.0;                        \
    float jitter = frac(52.9829189 * frac(dot(svpos, float2(0.06711056, 0.00583715)))); \
    [loop] for (int i = 1; i <= 16; ++i) {                                              \
      float ti = saturate((float(i) - jitter) / 16.0);                                  \
      float gap = (1.0 - P##Height(uv + r.dir * ti)) - ti;                              \
      if (gap <= 0.0) {                                                                 \
        t = lerp(t_prev, ti, gap_prev / max(gap_prev - gap, 1e-5));                     \
        break;                                                                          \
      }                                                                                 \
      t_prev = ti;                                                                      \
      gap_prev = gap;                                                                   \
    }                                                                                   \
    float2 hit = uv + r.dir * t;                                                        \
    h_hit = 1.0 - t;                                                                    \
    if (shadow_on && any(r.sun_dir != 0.0)) {                                           \
      float occ = 0.0;                                                                  \
      [unroll] for (int j = 1; j <= 6; ++j) {                                           \
        float s = (float(j) - jitter) / 6.0;                                            \
        occ = max(occ, (P##Height(hit + r.sun_dir * (2.0 * s)) - (h_hit + s)) * 4.0);   \
      }                                                                                 \
      shadow = 1.0 - saturate(occ) * r.fade;                                            \
    }                                                                                   \
    xe_grad_override = false;                                                           \
    return hit;                                                                         \
  }

// The standard use, for a shader that reads its textures from v0.xy with
// uv = base * scale + offset: in main, after r0 = input.v0,
//   SPARROW_RELIEF_APPLY(P, input.v0.xy, colour scale, world, camera, depth)
// moves r0.xy and turns the fetch wrappers' gradients on (not on characters).
#define SPARROW_RELIEF_APPLY(P, BASE, SCALE, POS, CAM, DEPTH)                         \
  float relief_h = 1.0, relief_shadow = 1.0;                                          \
  if (SparrowActive() && !(xe_flags & 0x80000000u)) {                                 \
    SparrowReliefFrame rf_ = SparrowReliefBegin(POS, CAM, BASE, DEPTH);               \
    [branch] if (rf_.fade > 0.0) {                                                    \
      r0.xy = P##Relief(BASE, input.position.xy, rf_, SCALE, false, relief_h, relief_shadow); \
      sp_relief_on = true;                                                            \
      sp_relief_dx = rf_.dx;                                                          \
      sp_relief_dy = rf_.dy;                                                          \
    }                                                                                 \
  }

// sparrow_debug 5: the lamp shadows alone.
float3 SparrowLampDebug(float4 vis) {
  return min(min(vis.x, vis.y), min(vis.z, vis.w)).xxx * 0.5;
}

// The game's Blinn-Phong gloss exponent as a GGX roughness (alpha = sqrt(2 / (n + 2)),
// roughness = sqrt(alpha)), for materials whose narrow game highlight a broad lobe
// would smear into a wash (wet stone, ice).
float SparrowGlossRoughness(float gloss) {
  return clamp(sqrt(sqrt(2.0 / (max(gloss, 0.0) + 2.0))), 0.15, 0.75);
}
float3 SparrowLitSpecularRough(float3 n, float3 v, float3 l[SPARROW_MAX_LIGHTS],
                               float3 light[SPARROW_MAX_LIGHTS], uint count, float3 spec_map,
                               float rough, float3 ambient) {
  float spec_lum = dot(spec_map, float3(0.2126, 0.7152, 0.0722));
  float3 sum = 0.0;
  float3 base = 0.0;
  [unroll] for (uint k2 = 0; k2 < SPARROW_MAX_LIGHTS; ++k2) {
    if (k2 < count) SparrowSpecularSplit(n, v, l[k2], rough, light[k2], base, sum);
  }
  sum += base * max(spec_map, SPARROW_F0);
  sum += ambient * SparrowEnvSpecular(n, v, rough, max(spec_lum, SPARROW_F0));
  return sum;
}
float3 SparrowLitSpecular(float3 n, float3 v, float3 l[SPARROW_MAX_LIGHTS],
                          float3 light[SPARROW_MAX_LIGHTS], uint count, float3 spec_map,
                          float3 albedo, float3 ambient) {
  float3 sum = 0.0;
  if (xe_flags & 0x80000000u) {
    SparrowCharMat cm = SparrowCharMaterial(albedo);
    [unroll] for (uint k = 0; k < SPARROW_MAX_LIGHTS; ++k) {
      if (k < count) sum += SparrowCharacterSpecular(n, v, l[k], light[k], cm);
    }
    return sum + SparrowCharacterSheen(ambient, n, v, cm);
  }
  float spec_lum = dot(spec_map, float3(0.2126, 0.7152, 0.0722));
  float rough = lerp(0.75, 0.35, saturate(spec_lum * 4.0));
  return SparrowLitSpecularRough(n, v, l, light, count, spec_map, rough, ambient);
}


// sparrow_debug 3: sky visibility as red (open) .. green (closed in), blue
// where Sparrow does not cover the point (vis < 0) and the game's ambient
// stays. Through the tonemap, read vis as R / (R + G).
float3 SparrowVisDebug(float vis) {
  // Ground grid misses: -2 no grid this frame (magenta), -3 outside the map
  // (cyan); -1 not covered / steep (blue).
  if (vis < -2.5) return float3(0.0, 0.5, 0.5);
  if (vis < -1.5) return float3(0.5, 0.0, 0.5);
  return vis < 0.0 ? float3(0.0, 0.0, 0.5) : float3(vis, 1.0 - vis, 0.0) * 0.5;
}

// The material's ambient light (game units, before albedo) shaped by the
// open sky and given the sun's bounce. vis_out: the sky visibility (for
// sparrow_debug 3), -1 where not covered.
float3 SparrowAmbient(float3 ambient, float3 pos, float3 n, float3 sun, out float vis_out) {
  float vis = SparrowSkyVisibility(pos, n);
  vis_out = vis;
  if (vis < 0.0) return ambient;
  return ambient * SparrowSkyTerm(vis) + SparrowBounce(pos, n) * sun * SPARROW_BOUNCE;
}

#endif
