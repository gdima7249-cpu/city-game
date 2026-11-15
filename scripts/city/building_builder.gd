class_name BuildingBuilder
extends RefCounted
## Строит здания из деталей пака: ряды домов вдоль улиц, башни, крыши,
## витрины с навесами и вывесками. Соседние дома всегда разные: другой
## стиль фасада и заметно другая высота.

const FLOOR := 3.0

const AWNING_COLORS: Array[Color] = [
	Color(0.7, 0.15, 0.12), Color(0.12, 0.35, 0.22), Color(0.15, 0.25, 0.5),
	Color(0.85, 0.6, 0.15), Color(0.35, 0.18, 0.4), Color(0.2, 0.2, 0.2),
]
const SIGN_COLORS: Array[Color] = [
	Color(1.0, 0.3, 0.25), Color(0.25, 0.8, 1.0), Color(1.0, 0.8, 0.25),
	Color(0.4, 1.0, 0.45), Color(1.0, 0.4, 0.85), Color(1.0, 1.0, 0.95),
]

## Цвет упрощённого дома (виден издалека вместо детального) для каждого стиля фасада
const LOD_COLORS := {
	"brick": Color(0.56, 0.3, 0.24), "brick_arch": Color(0.6, 0.36, 0.28), "brick_inset": Color(0.55, 0.32, 0.26),
	"redwhite": Color(0.66, 0.36, 0.3), "trim": Color(0.8, 0.74, 0.6), "glass": Color(0.52, 0.57, 0.62),
	"office": Color(0.46, 0.5, 0.55), "warehouse": Color(0.62, 0.62, 0.6), "prebuilt": Color(0.72, 0.62, 0.5),
}

const FAR_SHADER := preload("res://shaders/far_building.gdshader")

static var _window_texture: ImageTexture
static var _window_glow: ImageTexture

var kit: CityKit
var boxes: BoxBatch
var rng: RandomNumberGenerator
var body: StaticBody3D ## Сюда складываются столкновения всех зданий

var _mats := {}
var _prev_style := ""
var _prev_floors := -10
var _prev_prebuilt := ""


func _init(p_kit: CityKit, p_boxes: BoxBatch, p_rng: RandomNumberGenerator, p_body: StaticBody3D) -> void:
	kit = p_kit
	boxes = p_boxes
	rng = p_rng
	body = p_body


func material(key: String, color: Color, roughness: float = 0.85) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = roughness
		_mats[key] = m
	return _mats[key]


func _glow(key: String, color: Color, energy: float) -> StandardMaterial3D:
	if not _mats.has(key):
		_mats[key] = NightLights.glowing(color, energy)
	return _mats[key]


func collision(xform: Transform3D, b: AABB) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = b.size
	shape.shape = box
	shape.transform = xform * Transform3D(Basis(), b.get_center())
	body.add_child(shape)


# --- Ряды домов ---------------------------------------------------------------

## Ряд зданий вдоль северной (side = -1) или южной (side = 1) стороны квартала,
## фасадами к улице. Возвращает глубину самого глубокого здания.
func row(r: Rect2, side: float, p: Dictionary) -> float:
	var yaw := 0.0 if side > 0.0 else PI
	var front := r.end.y if side > 0.0 else r.position.y
	var max_allowed := floorf((r.size.y * 0.5 - 1.0) / 2.0) * 2.0
	var prebuilt: Array = p["prebuilt"]
	var widths: Array = p["widths"]
	var depths: Array = p["depths"]
	var floors_range: Vector2i = p["floors"]
	var gap: Vector2 = p["gap"]
	var cursor := 0.0
	var span := r.size.x
	var max_depth := 0.0
	_prev_style = ""
	_prev_floors = -10
	_prev_prebuilt = ""
	while span - cursor >= 6.0:
		var remaining := span - cursor
		var fitting: Array[String] = []
		for building: String in prebuilt:
			var b := kit.bounds(building)
			if b.size.x <= remaining and b.size.z <= max_allowed and building != _prev_prebuilt:
				fitting.append(building)
		var bounds: AABB
		var xform: Transform3D
		if not fitting.is_empty() and rng.randf() < float(p["prebuilt_chance"]):
			var building := fitting[rng.randi() % fitting.size()]
			bounds = kit.bounds(building)
			xform = _row_transform(r.position.x + cursor, front, yaw, bounds)
			kit.add(building, xform)
			_lod(xform, bounds, "prebuilt")
			_prev_prebuilt = building
			_prev_style = ""
			_prev_floors = int(bounds.size.y / FLOOR)
		else:
			var width := mini(int(remaining) / 2 * 2, int(widths[rng.randi() % widths.size()]))
			var depth := minf(float(depths[rng.randi() % depths.size()]), max_allowed)
			if depth < 6.0:
				break
			var floors := _different_floors(floors_range)
			var style := _different_style(p["styles"])
			bounds = AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width, floors * FLOOR, depth))
			xform = _row_transform(r.position.x + cursor, front, yaw, bounds)
			var stepped: bool = floors >= 9 and width >= 12 and depth >= 12 and rng.randf() < float(p.get("stepped", 0.0))
			if stepped:
				stepped_tower(xform, width, depth, floors, style, p)
			else:
				modular(xform, width, depth, floors, style, p)
			_prev_prebuilt = ""
		collision(xform, bounds)
		max_depth = maxf(max_depth, bounds.size.z)
		cursor += bounds.size.x + rng.randf_range(gap.x, gap.y)
	return max_depth


## Этажность, заметно отличающаяся от соседнего дома.
func _different_floors(range_floors: Vector2i) -> int:
	var floors := rng.randi_range(range_floors.x, range_floors.y)
	for attempt in 4:
		if absi(floors - _prev_floors) >= 2 or range_floors.y - range_floors.x < 3:
			break
		floors = rng.randi_range(range_floors.x, range_floors.y)
	_prev_floors = floors
	return floors


## Стиль фасада, отличный от соседнего дома.
func _different_style(styles: Array) -> Dictionary:
	var style: Dictionary = styles[rng.randi() % styles.size()]
	for attempt in 6:
		if style["name"] != _prev_style or styles.size() == 1:
			break
		style = styles[rng.randi() % styles.size()]
	_prev_style = style["name"]
	return style


## Где поставить здание, чтобы его левый край был в left, а фасад — на линии front.
func _row_transform(left: float, front: float, yaw: float, b: AABB) -> Transform3D:
	var pos: Vector3
	if yaw == 0.0:
		pos = Vector3(left - b.position.x, 0.1, front - b.end.z)
	else:
		pos = Vector3(left + b.end.x, 0.1, front + b.end.z)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


# --- Здания из деталей --------------------------------------------------------

## Башня с уступом: широкое основание и более узкий верх.
func stepped_tower(xform: Transform3D, width: int, depth: float, floors: int, style: Dictionary, p: Dictionary) -> void:
	var base_floors := rng.randi_range(3, maxi(3, floors / 2))
	var top_floors := floors - base_floors
	var base_opts := p.duplicate()
	base_opts["roof_props"] = false
	modular(xform, width, depth, base_floors, style, base_opts)
	var top_width := width - 4
	var top_depth := depth - 4.0
	var top_xform := xform * Transform3D(Basis(), Vector3(0.0, base_floors * FLOOR, 0.0))
	var top_opts := {"no_door": true, "roof": p.get("roof", "flat"), "antenna": true}
	modular(top_xform, top_width, top_depth, top_floors, style, top_opts)


## Здание из кусков: стены по 2 или 4 м на каждый этаж, колонны по углам, карниз,
## крыша с кондиционерами, а на первом этаже — навесы и вывески.
func modular(xform: Transform3D, width: int, depth: float, floors: int, style: Dictionary, opts: Dictionary = {}) -> void:
	var ground: Array = style["ground"]
	var upper: Array = style["upper"]
	var narrow: Array[String] = []
	for piece: String in upper:
		if kit.bounds(piece).size.x < 3.0:
			narrow.append(piece)
	if narrow.is_empty():
		narrow.append("Brick_Plain_3_noWear")
	var no_door: bool = opts.get("no_door", false)
	var w := float(width)
	var sides := [
		[Vector3(0, 0, 1), 0.0, w], [Vector3(0, 0, -1), PI, w],
		[Vector3(1, 0, 0), PI * 0.5, depth], [Vector3(-1, 0, 0), -PI * 0.5, depth],
	]
	for side_index in sides.size():
		var normal: Vector3 = sides[side_index][0]
		var yaw: float = sides[side_index][1]
		var length: float = sides[side_index][2]
		var half_extent: float = depth * 0.5 if side_index < 2 else w * 0.5
		var along := Vector3(normal.z, 0.0, normal.x).abs()
		var basis := Basis(Vector3.UP, yaw)
		var segments := int(round(length / 2.0))
		var door_at := segments / 2 if side_index == 0 and not no_door else -1

		# Столбцы фасада: одна деталь на всю высоту, широкие окна занимают два шага
		var columns: Array = []
		var k := 0
		while k < segments:
			var piece: String = upper[rng.randi() % upper.size()]
			var span := 2 if kit.bounds(piece).size.x > 3.0 else 1
			if k + span > segments:
				piece = narrow[rng.randi() % narrow.size()]
				span = 1
			columns.append([-length * 0.5 + 2.0 * k + span, piece])
			k += span

		for f in floors:
			var y := f * FLOOR
			if f == 0 and not no_door:
				for s in segments:
					var base := normal * half_extent + along * (-length * 0.5 + 1.0 + 2.0 * s)
					var piece: String
					if s == door_at:
						piece = style["door"]
						var door: String = CityModels.DOORS[rng.randi() % CityModels.DOORS.size()]
						kit.add(door, xform * Transform3D(basis, base) * Transform3D(Basis(), CityModels.DOOR_OFFSET))
					else:
						piece = ground[rng.randi() % ground.size()]
					kit.add(piece, xform * Transform3D(basis, base))
				continue
			for column: Array in columns:
				var base := normal * half_extent + along * float(column[0])
				kit.add(column[1], xform * Transform3D(basis, base + Vector3.UP * y))
		for s in segments:
			var base := normal * half_extent + along * (-length * 0.5 + 1.0 + 2.0 * s)
			kit.add(style["cornice"], xform * Transform3D(basis, base + Vector3.UP * (floors * FLOOR)))
		if side_index == 0 and not no_door and opts.get("shops", false):
			_shopfront(xform, basis, normal * half_extent, along, length, segments, door_at)

	# Колонны на углах
	for corner: Vector3 in [Vector3(w * 0.5, 0, depth * 0.5), Vector3(-w * 0.5, 0, depth * 0.5),
			Vector3(w * 0.5, 0, -depth * 0.5), Vector3(-w * 0.5, 0, -depth * 0.5)]:
		for f in floors:
			var column := CityModels.COLUMN_MIDDLE
			if f == 0:
				column = CityModels.COLUMN_BOTTOM
			elif f == floors - 1:
				column = CityModels.COLUMN_TOP
			kit.add(column, xform * Transform3D(Basis(), corner + Vector3.UP * (f * FLOOR)))

	# Плоская крыша и что на ней стоит
	var top := floors * FLOOR
	boxes.add("box", xform * Transform3D(Basis(), Vector3(0, top - 0.1, 0)), Vector3(w - 0.1, 0.2, depth - 0.1),
			material("roof", Color(0.24, 0.24, 0.25)), 0.0, 0.0, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	if opts.get("roof_props", true):
		_roof_props(xform, w, depth, top, opts)
	_lod(xform, AABB(Vector3(-w * 0.5, 0.0, -depth * 0.5), Vector3(w, top - 0.05, depth)), style["name"])


# --- Упрощённые дома ----------------------------------------------------------

## Коробка дома: издалека видна вместо детальных стен, а вблизи невидима,
## но отбрасывает тень (детали пака тени не дают — так в разы быстрее).
func _lod(xform: Transform3D, b: AABB, style_name: String) -> void:
	var center := xform * Transform3D(Basis(), b.get_center())
	boxes.add("box", center, b.size, _lod_material(style_name), 0.0, CityKit.NEAR_RANGE - 30.0,
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	# Тень: коробка чуть меньше дома, чтобы не затенять собственные стены
	var shadow_size := Vector3(maxf(b.size.x - 0.6, 0.5), b.size.y, maxf(b.size.z - 0.6, 0.5))
	boxes.add("box", center, shadow_size, material("shadow_proxy", Color.BLACK), 0.0, 0.0,
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)


func _lod_material(style_name: String) -> ShaderMaterial:
	var key := "lod_" + style_name
	if _mats.has(key):
		return _mats[key]
	_make_window_textures()
	var m := ShaderMaterial.new()
	m.shader = FAR_SHADER
	var wall: Color = LOD_COLORS.get(style_name, Color(0.6, 0.6, 0.6))
	m.set_shader_parameter("wall_color", wall)
	m.set_shader_parameter("roof_color", wall.darkened(0.45))
	m.set_shader_parameter("windows", _window_texture)
	m.set_shader_parameter("glow", _window_glow)
	NightLights.register_shader(m, CityKit.WINDOW_LIT_ENERGY)
	_mats[key] = m
	return m


## Текстура «стена с окнами» и маска окон, где ночью горит свет.
static func _make_window_textures() -> void:
	if _window_texture != null:
		return
	var size := 256
	var cell := 32
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var glow := Image.create(size, size, true, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	glow.fill(Color.BLACK)
	var random := RandomNumberGenerator.new()
	random.seed = 7
	for cy in size / cell:
		for cx in size / cell:
			var lit := random.randf() < CityKit.LIT_SHARE
			var window := Rect2i(cx * cell + 6, cy * cell + 7, cell - 12, cell - 13)
			img.fill_rect(window, Color(0.2, 0.23, 0.28))
			if lit:
				glow.fill_rect(window, Color.WHITE)
	img.generate_mipmaps()
	glow.generate_mipmaps()
	_window_texture = ImageTexture.create_from_image(img)
	_window_glow = ImageTexture.create_from_image(glow)


## Навесы над витринами или вывеска над дверью.
func _shopfront(xform: Transform3D, basis: Basis, face: Vector3, along: Vector3, length: float, segments: int, door_at: int) -> void:
	var roll := rng.randf()
	if roll < 0.5:
		var color := AWNING_COLORS[rng.randi() % AWNING_COLORS.size()]
		var mat := material("awning%d" % AWNING_COLORS.find(color), color, 0.7)
		for s in segments:
			if s == door_at:
				continue
			var pos := face + along * (-length * 0.5 + 1.0 + 2.0 * s) + face.normalized() * 0.6 + Vector3.UP * 2.8
			boxes.box(xform * Transform3D(basis * Basis(Vector3.RIGHT, 0.35), pos), Vector3(1.9, 0.06, 1.25), mat, 220.0)
	if roll >= 0.35 and door_at >= 0:
		var color := SIGN_COLORS[rng.randi() % SIGN_COLORS.size()]
		var mat := _glow("sign%d" % SIGN_COLORS.find(color), color, 2.5)
		var pos := face + along * (-length * 0.5 + 1.0 + 2.0 * door_at) + face.normalized() * 0.12 + Vector3.UP * 3.25
		boxes.box(xform * Transform3D(basis, pos), Vector3(2.6, 0.5, 0.1), mat, 260.0)


## Кондиционеры, будки выходов на крышу, баки с водой, антенны.
func _roof_props(xform: Transform3D, w: float, depth: float, top: float, opts: Dictionary) -> void:
	var hx := w * 0.5 - 1.5
	var hz := depth * 0.5 - 1.5
	if hx <= 0.5 or hz <= 0.5:
		return
	var count := clampi(int(w * depth / 45.0 * rng.randf_range(0.5, 1.0)), 1, 7)
	for k in count:
		var pos := Vector3(rng.randf_range(-hx, hx), top, rng.randf_range(-hz, hz))
		kit.add(CityModels.ROOF_AC, xform * Transform3D(Basis(Vector3.UP, PI * 0.5 * rng.randi_range(0, 3)), pos))
	if rng.randf() < 0.5 and hx > 2.0 and hz > 2.0:
		var pos := Vector3(rng.randf_range(-hx + 1.5, hx - 1.5), top + 1.2, rng.randf_range(-hz + 1.5, hz - 1.5))
		boxes.box(xform * Transform3D(Basis(), pos), Vector3(3.0, 2.4, 3.5), material("housing", Color(0.5, 0.49, 0.47)), 400.0)
	if opts.get("roof", "flat") == "tanks" and rng.randf() < 0.4:
		var pos := Vector3(rng.randf_range(-hx + 1.0, hx - 1.0), top, rng.randf_range(-hz + 1.0, hz - 1.0))
		var wood := material("tank", Color(0.42, 0.3, 0.2))
		boxes.cylinder(xform * Transform3D(Basis(), pos + Vector3.UP * 2.3), Vector3(2.2, 2.4, 2.2), wood, 400.0)
		boxes.cylinder(xform * Transform3D(Basis(), pos + Vector3.UP * 3.6), Vector3(2.4, 0.25, 2.4), material("tank_roof", Color(0.25, 0.22, 0.2)), 400.0)
		for leg: Vector3 in [Vector3(0.7, 0, 0.7), Vector3(-0.7, 0, 0.7), Vector3(0.7, 0, -0.7), Vector3(-0.7, 0, -0.7)]:
			boxes.box(xform * Transform3D(Basis(), pos + leg + Vector3.UP * 0.55), Vector3(0.15, 1.1, 0.15), wood, 300.0)
	if opts.get("antenna", false) and rng.randf() < 0.7:
		var pos := Vector3(rng.randf_range(-hx, hx) * 0.5, top, rng.randf_range(-hz, hz) * 0.5)
		var height := rng.randf_range(5.0, 10.0)
		boxes.cylinder(xform * Transform3D(Basis(), pos + Vector3.UP * height * 0.5), Vector3(0.15, height, 0.15),
				material("antenna", Color(0.6, 0.6, 0.62), 0.4))
		boxes.add("sphere", xform * Transform3D(Basis(), pos + Vector3.UP * height), Vector3(0.4, 0.4, 0.4),
				_glow("beacon", Color(1.0, 0.1, 0.05), 4.0), 0.0)
