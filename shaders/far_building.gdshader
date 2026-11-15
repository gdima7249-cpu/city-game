shader_type spatial;
// Упрощённый дом вдали: стены с окнами по мировым координатам (окно 2 × 3 м),
// крыша без окон. Ночью часть окон светится (night_energy задаёт NightLights).

uniform vec3 wall_color : source_color = vec3(0.6);
uniform vec3 roof_color : source_color = vec3(0.35);
uniform sampler2D windows : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D glow : filter_linear_mipmap_anisotropic;
uniform vec3 glow_color : source_color = vec3(1.0, 0.82, 0.55);
uniform float night_energy = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ROUGHNESS = 0.85;
	if (abs(world_normal.y) > 0.5) {
		ALBEDO = roof_color;
	} else {
		float u = abs(world_normal.x) > abs(world_normal.z) ? world_pos.z : world_pos.x;
		vec2 uv = vec2(u / 16.0, -world_pos.y / 24.0);
		ALBEDO = wall_color * texture(windows, uv).rgb;
		EMISSION = glow_color * texture(glow, uv).r * night_energy;
	}
}
