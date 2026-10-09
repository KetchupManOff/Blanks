shader_type canvas_item;

// General piece bloom for the playfield render target: a thresholded
// multi-ring blur of bright pixels added back over the unmodified
// source, so boards with bright piece colors or skins gain a visible
// retro glow while cells, grid, and skins stay sharp. Offsets derive
// from the texture's texel size, keeping the effect stable for the solo
// board and every co-op board width/cell size. Thresholding keeps the
// opaque board background and the faint grid from washing the field
// out. `intensity` is the theme-provided multiplier (default 0.8 for
// direct material use; the presenter always supplies the resolved
// numeric value). The sampling stays inlined in fragment(): shader
// built-ins like TEXTURE are not visible inside helper functions.

uniform float threshold : hint_range(0.0, 1.0) = 0.45;
uniform float intensity : hint_range(0.0, 2.0) = 0.8;
uniform float radius : hint_range(0.5, 4.0) = 2.0;

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	vec2 texel = TEXTURE_PIXEL_SIZE * radius;
	vec3 glow = vec3(0.0);
	for (int ring = 1; ring <= 3; ring++) {
		vec2 r = texel * float(ring);
		glow += max(texture(TEXTURE, UV + r * vec2(1.0, 0.0)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(-1.0, 0.0)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(0.0, 1.0)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(0.0, -1.0)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(0.7071, 0.7071)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(-0.7071, 0.7071)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(0.7071, -0.7071)).rgb - threshold, vec3(0.0));
		glow += max(texture(TEXTURE, UV + r * vec2(-0.7071, -0.7071)).rgb - threshold, vec3(0.0));
	}
	glow *= (1.0 / 24.0) * intensity;
	COLOR = vec4(src.rgb + glow, src.a);
}
