// Dispatch's phosphor look, not Ghostty's: a pass after the frame (MetalRenderer.draw with a Glow) that adds a halo
// around what is brighter than the background and faint scanlines. Compiled after ghosttyShaders, whose Uniforms,
// load_color and full_screen_vertex it uses. Still: nothing animates, so an idle terminal draws no frames for it.
#if canImport(Metal)
let glowShaders = #"""

struct GlowParams {
  float strength;
  float scanline_depth;
};

constexpr sampler glow_sampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

// Four taps around `uv` at a mip level, half a texel of that level apart: smooths the box filter's blocks.
float3 glow_level(texture2d<float> frame, float2 uv, float lod, float3 bg) {
  float2 texel = exp2(lod) / float2(frame.get_width(), frame.get_height());
  float3 sum = 0;
  for (int i = 0; i < 4; i++) {
    float2 offset = float2((i & 1) ? 0.5 : -0.5, (i & 2) ? 0.5 : -0.5) * texel;
    sum += max(frame.sample(glow_sampler, uv + offset, level(lod)).rgb - bg, 0.0);
  }
  return sum / 4;
}

fragment float4 glow_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]],
  constant GlowParams& params [[buffer(2)]],
  texture2d<float> frame [[texture(0)]]
) {
  float4 color = frame.read(uint2(in.position.xy));
  float2 uv = in.position.xy / float2(frame.get_width(), frame.get_height());
  float3 bg = load_color(uniforms.bg_color, uniforms.use_display_p3, uniforms.use_linear_blending).rgb;

  // The halo's reach follows the cell, so it looks the same at any scale: a near one about an eighth of a row,
  // a far one four times wider and fainter.
  float near = max(log2(uniforms.cell_size.y / 8.0), 0.0);
  float3 halo = glow_level(frame, uv, near, bg) * 0.65 + glow_level(frame, uv, near + 2.0, bg) * 0.35;
  color.rgb += halo * params.strength;

  // Scanlines: a whole number per row (about every 3 pixels), aligned to the grid so they never beat against it.
  float lines = max(round(uniforms.cell_size.y / 3.0), 1.0);
  float period = uniforms.cell_size.y / lines;
  float phase = fract((in.position.y - uniforms.grid_padding.x) / period);
  color.rgb *= 1.0 - params.scanline_depth * (0.5 - 0.5 * cos(phase * 2.0 * M_PI_F));

  // Premultiplied: a translucent background keeps its alpha, and the halo can't brighten past it.
  color.rgb = min(color.rgb, float3(color.a));
  return color;
}
"""#
#endif
