shader_type spatial;
// «Комната за окном»: вместо плоской серой заливки окна видна комната с глубиной
// (задняя стена, пол, потолок, боковые стены, иногда мебель и жалюзи).
// Каждое окно получает свой цвет стен по своему месту в мире.
// Ночью окна с lit = 1 светятся (night_energy задаёт NightLights).

uniform float lit = 0.0;
uniform float night_energy = 0.0;
uniform float room_depth = 0.9;
uniform float day_light = 0.3;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void fragment() {
	// Взгляд в координатах окна: x — вдоль окна, y — вверх, z — из стены наружу
	vec3 v = normalize(vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL)));
	vec3 dir = vec3(-v.x, -v.y, -max(v.z, 0.05));
	vec3 o = vec3(UV.x, 1.0 - UV.y, 0.0);

	float tx = ((dir.x > 0.0 ? 1.0 : 0.0) - o.x) / (abs(dir.x) < 1e-4 ? 1e-4 : dir.x);
	float ty = ((dir.y > 0.0 ? 1.0 : 0.0) - o.y) / (abs(dir.y) < 1e-4 ? 1e-4 : dir.y);
	float tz = -room_depth / dir.z;
	float t = min(min(tx, ty), tz);
	vec3 h = o + dir * t;

	vec3 cell = floor(world_pos / vec3(2.0, 3.0, 2.0) + vec3(0.01));
	float r1 = hash(cell);
	float r2 = hash(cell + 17.0);
	vec3 wall = mix(vec3(0.86, 0.76, 0.6), vec3(0.6, 0.72, 0.8), step(0.45, r1));
	wall = mix(wall, vec3(0.74, 0.8, 0.6), step(0.75, r1));
	wall = mix(wall, vec3(0.85, 0.62, 0.55), step(0.9, r1));

	vec3 col;
	if (t == tz) {
		col = wall;
		// Шкаф или диван у задней стены
		if (r2 > 0.3 && h.y < 0.38 && abs(h.x - 0.5) < 0.32) {
			col = mix(vec3(0.25, 0.18, 0.12), vec3(0.2, 0.24, 0.3), step(0.65, r2));
		}
	} else if (t == ty) {
		col = dir.y < 0.0 ? vec3(0.3, 0.2, 0.13) : vec3(0.9, 0.89, 0.85);
	} else {
		col = wall * 0.7;
	}
	// В глубине комнаты темнее
	col *= mix(1.0, 0.4, clamp(-h.z / room_depth, 0.0, 1.0));

	// Жалюзи в части окон
	float blinds = step(0.72, r2) * step(1.0 - (0.25 + 0.5 * r1), o.y);
	col = mix(col, vec3(0.8, 0.78, 0.72) * (0.85 + 0.15 * step(0.5, fract(o.y * 14.0))), blinds);

	// Комната освещена сама по себе (свет из других окон), поэтому часть цвета —
	// свечение: иначе в тени дома окна выглядят плоскими серыми
	ALBEDO = col * 0.45;
	ROUGHNESS = 0.9;
	vec3 light = mix(vec3(1.0, 0.8, 0.55), vec3(0.85, 0.9, 1.0), step(0.85, r2));
	EMISSION = col * (day_light * (1.0 - clamp(night_energy, 0.0, 1.0)) + light * night_energy * lit);
}
