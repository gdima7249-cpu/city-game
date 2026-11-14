class_name CityGrid
extends Node3D
## Квартал-сетка: дороги, тротуары, здания-заглушки, светофоры,
## машины и пешеходы. Всё строится кодом при запуске игры.
##
## Узел стоит в углу квартала. Перекрёстки идут с шагом
## block_size + road_width по осям +X и +Z.

@export_group("Размеры")
@export var blocks_x: int = 4
@export var blocks_z: int = 3
@export var block_size: float = 40.0
@export var road_width: float = 10.0
@export var sidewalk_width: float = 3.0
@export var lane_offset: float = 2.3 ## Расстояние от центра дороги до середины полосы

@export_group("Жизнь")
@export var car_count: int = 26
@export var pedestrian_count: int = 45
@export var random_seed: int = 12345

## Направления: 0 — север (-Z), 1 — восток (+X), 2 — юг (+Z), 3 — запад (-X)
const DIRS: Array[Vector3] = [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]

var pitch: float
var intersections: Array[TrafficIntersection] = []
var cars: Array[TrafficCar] = []
var rng := RandomNumberGenerator.new()

var _half_road: float
var _kit: CityKit

## Готовые здания из пака: имя модели
const PREBUILT: Array[String] = ["Building_Large_2", "Building_Medium_2_001", "Building_Small_1"]

## Наборы деталей для зданий, которые собираются из кусков (стены по 2 м, этаж 3 м)
const STYLES := [
	{
		"ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Trim_FirstFloor_Window_001"],
		"door": "DoorFrame_Metal_Single",
		"upper": ["Brick_Window_Trim", "Brick_Window_Trim_Single", "Brick_Window_Square_Single"],
		"cornice": "Cornice_Brick_Center",
	},
	{
		"ground": ["Trim_FirstFloor_Window_001", "Trim_FirstFloor_Wall", "Trim_FirstFloor_Window_001"],
		"door": "DoorFrame_Trim",
		"upper": ["Trim_Window", "Trim_Window", "Trim_Plain_3"],
		"cornice": "Cornice_Trim_Center",
	},
	{
		"ground": ["Metal_FirstFloor_Window", "Metal_FullWindow"],
		"door": "DoorFrame_Metal_Single",
		"upper": ["Metal_FullWindow", "Metal_Window_Half", "Metal_FullWindow"],
		"cornice": "Cornice_Metal_Center",
	},
]


func _ready() -> void:
	rng.seed = random_seed
	pitch = block_size + road_width
	_half_road = road_width * 0.5
	_build_ground()
	_build_markings()
	if CityKit.available():
		_kit = CityKit.new()
		_build_blocks_from_kit()
		_kit.flush(self)
	else:
		_build_blocks()
	_build_intersections()
	_spawn_cars()
	_spawn_pedestrians()


# --- Геометрия сетки ---------------------------------------------------------

func index_of(i: int, j: int) -> int:
	if i < 0 or j < 0 or i > blocks_x or j > blocks_z:
		return -1
	return i + j * (blocks_x + 1)


func center(index: int) -> Vector3:
	var i := index % (blocks_x + 1)
	var j := index / (blocks_x + 1)
	return global_position + Vector3(i * pitch, 0.0, j * pitch)


func neighbor(index: int, dir: int) -> int:
	var i := index % (blocks_x + 1)
	var j := index / (blocks_x + 1)
	match dir:
		0: return index_of(i, j - 1)
		1: return index_of(i + 1, j)
		2: return index_of(i, j + 1)
		_: return index_of(i - 1, j)


static func right_of(heading: Vector3) -> Vector3:
	return Vector3(-heading.z, 0.0, heading.x)


## Точка, где машина выезжает из перекрёстка в направлении dir.
func exit_point(index: int, dir: int) -> Vector3:
	var h := DIRS[dir]
	return center(index) + h * (_half_road + 1.0) + right_of(h) * lane_offset


## Стоп-линия перед перекрёстком для машины, едущей в направлении dir.
func stop_point(index: int, dir: int) -> Vector3:
	var h := DIRS[dir]
	return center(index) - h * (_half_road + 3.0) + right_of(h) * lane_offset


## Куда можно поехать с перекрёстка, если приехали в направлении arriving.
func exits_from(index: int, arriving: int) -> Array[int]:
	var result: Array[int] = []
	var back := (arriving + 2) % 4
	for d in 4:
		if d != back and neighbor(index, d) != -1:
			result.append(d)
	if result.is_empty():
		result.append(back)
	return result


## Плавная траектория через перекрёсток (кривая Безье).
func turn_path(index: int, arriving: int, leaving: int) -> PackedVector3Array:
	var p0 := stop_point(index, arriving)
	var p2 := exit_point(index, leaving)
	var p1: Vector3
	if arriving == leaving:
		p1 = (p0 + p2) * 0.5
	elif arriving % 2 == 0:
		p1 = Vector3(p0.x, 0.0, p2.z)
	else:
		p1 = Vector3(p2.x, 0.0, p0.z)
	var points := PackedVector3Array()
	var steps := 10
	for s in range(1, steps + 1):
		var t := float(s) / steps
		points.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))
	return points


# --- Построение квартала -----------------------------------------------------

func _material(color: Color, roughness: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


func _add_box(size: Vector3, pos: Vector3, material: Material, with_collision: bool) -> Node3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	if not with_collision:
		mesh.position = pos
		add_child(mesh)
		return mesh
	var body := StaticBody3D.new()
	body.position = pos
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	body.add_child(mesh)
	add_child(body)
	return body


func _build_ground() -> void:
	# Асфальт под всем кварталом (столкновения даёт общая земля карты)
	var width := blocks_x * pitch + road_width
	var depth := blocks_z * pitch + road_width
	var asphalt := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, depth)
	asphalt.mesh = plane
	var asphalt_mat := _material(Color(0.32, 0.32, 0.33))
	var texture_path := "res://assets/downtown/T_Concrete_Asphalt_BaseColor.png"
	if ResourceLoader.exists(texture_path):
		# Текстура асфальта из пака, повторяется каждые 8 м
		asphalt_mat.albedo_color = Color(0.85, 0.85, 0.85)
		asphalt_mat.albedo_texture = load(texture_path)
		asphalt_mat.uv1_triplanar = true
		asphalt_mat.uv1_world_triplanar = true
		asphalt_mat.uv1_scale = Vector3(0.125, 0.125, 0.125)
		asphalt_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	asphalt.material_override = asphalt_mat
	asphalt.position = Vector3(blocks_x * pitch * 0.5, 0.012, blocks_z * pitch * 0.5)
	add_child(asphalt)


func _build_markings() -> void:
	# Прерывистая осевая линия и стоп-линии
	var paint := _material(Color(0.95, 0.95, 0.9))
	var dashes: Array[Transform3D] = []
	var stops: Array[Transform3D] = []
	for index in (blocks_x + 1) * (blocks_z + 1):
		for dir: int in [1, 2]: # каждую дорогу рисуем один раз: на восток и на юг
			if neighbor(index, dir) == -1:
				continue
			var h := DIRS[dir]
			var along_basis := Basis(Vector3.UP, PI * 0.5) if dir == 1 else Basis()
			var start := center(index) + h * (_half_road + 2.0)
			var length := pitch - road_width - 4.0
			var t := 0.0
			while t < length:
				dashes.append(Transform3D(along_basis, start + h * t - global_position + Vector3.UP * 0.02))
				t += 5.0
		for dir in 4:
			if neighbor(index, (dir + 2) % 4) == -1:
				continue
			# Стоп-линия поперёк полосы
			var across_basis := Basis(Vector3.UP, PI * 0.5) if dir % 2 == 0 else Basis()
			var p := stop_point(index, dir) + DIRS[dir] * 2.6 - global_position
			stops.append(Transform3D(across_basis, p + Vector3.UP * 0.02))
	_add_multimesh(Vector3(0.15, 0.02, 2.0), paint, dashes)
	_add_multimesh(Vector3(0.4, 0.02, _half_road - 0.4), paint, stops)


func _add_multimesh(size: Vector3, material: Material, transforms: Array[Transform3D]) -> void:
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = transforms.size()
	for k in transforms.size():
		mm.set_instance_transform(k, transforms[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)


func _build_blocks() -> void:
	var sidewalk_mat := _material(Color(0.6, 0.6, 0.58))
	var lot_mat := _material(Color(0.42, 0.5, 0.36))
	var palette: Array[Color] = [
		Color(0.85, 0.82, 0.75), Color(0.75, 0.7, 0.62), Color(0.6, 0.65, 0.7),
		Color(0.9, 0.88, 0.85), Color(0.55, 0.55, 0.58), Color(0.8, 0.7, 0.6),
	]
	var window_mat := _material(Color(0.25, 0.35, 0.45), 0.2)
	for bi in blocks_x:
		for bj in blocks_z:
			var c := Vector3((bi + 0.5) * pitch, 0.0, (bj + 0.5) * pitch)
			# Тротуар — только картинка, чтобы о бордюр не спотыкаться
			_add_box(Vector3(block_size, 0.08, block_size), c + Vector3.UP * 0.04, sidewalk_mat, false)
			var inner := block_size - sidewalk_width * 2.0
			_add_box(Vector3(inner, 0.02, inner), c + Vector3.UP * 0.09, lot_mat, false)
			# Четыре участка с домами-заглушками
			var lot := inner * 0.5
			for lx in 2:
				for lz in 2:
					var lot_center := c + Vector3((lx - 0.5) * lot, 0.0, (lz - 0.5) * lot)
					var w := lot - rng.randf_range(1.5, 5.0)
					var d := lot - rng.randf_range(1.5, 5.0)
					var h := rng.randf_range(8.0, 42.0)
					var mat := _material(palette[rng.randi() % palette.size()], 0.8)
					_add_box(Vector3(w, h, d), lot_center + Vector3.UP * (h * 0.5), mat, true)
					# Полосы «окон», чтобы здания читались как здания
					var floors := int(h / 3.5)
					for f in range(1, floors):
						_add_box(Vector3(w + 0.06, 1.2, d + 0.06), lot_center + Vector3.UP * (f * 3.5), window_mat, false)


# --- Квартал из моделей пака -------------------------------------------------

func _build_blocks_from_kit() -> void:
	var lot_mat := _material(Color(0.5, 0.5, 0.48))
	var roof_mat := _material(Color(0.22, 0.22, 0.23))
	for bi in blocks_x:
		for bj in blocks_z:
			var c := Vector3((bi + 0.5) * pitch, 0.0, (bj + 0.5) * pitch)
			var lot := block_size - sidewalk_width * 2.0 - 0.3
			_add_box(Vector3(lot, 0.1, lot), c + Vector3.UP * 0.05, lot_mat, false)
			_add_sidewalk_ring(c)
			var half := block_size * 0.5 - sidewalk_width
			for side: float in [1.0, -1.0]:
				_build_row(c, half, side, roof_mat)


## Тротуар из плиток 3×3 м по краю квартала, бордюр смотрит на дорогу.
func _add_sidewalk_ring(c: Vector3) -> void:
	var count := maxi(roundi(block_size / 3.0), 2)
	var s := block_size / (count * 3.0)
	var edge := block_size * 0.5 - 1.5 * s
	var sides := [[Vector3(0, 0, 1), 0.0], [Vector3(0, 0, -1), PI], [Vector3(1, 0, 0), PI * 0.5], [Vector3(-1, 0, 0), -PI * 0.5]]
	for side_index in sides.size():
		var normal: Vector3 = sides[side_index][0]
		var yaw: float = sides[side_index][1]
		var along := Vector3(normal.z, 0.0, normal.x).abs()
		var first := 0 if side_index < 2 else 1 # углы кладём только один раз
		var last := count if side_index < 2 else count - 1
		var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(s, 1.0, s))
		for k in range(first, last):
			var offset := -block_size * 0.5 + 1.5 * s + 3.0 * s * k
			var pos := c + normal * edge + along * offset + Vector3.UP * 0.1
			_kit.add("Sidewalk_Straight_3m", Transform3D(basis, pos))


## Ряд зданий вдоль одной стороны квартала, фасадами к улице.
## side = 1 — южная сторона (+Z), -1 — северная (-Z).
func _build_row(c: Vector3, half: float, side: float, roof_mat: Material) -> void:
	var yaw := 0.0 if side > 0.0 else PI
	var front := c.z + side * half
	var cursor := -half
	while half - cursor >= 6.0:
		var remaining := half - cursor
		var fitting: Array[String] = []
		for building in PREBUILT:
			if _kit.bounds(building).size.x <= remaining:
				fitting.append(building)
		var bounds: AABB
		var xform: Transform3D
		if not fitting.is_empty() and rng.randf() < 0.6:
			var building := fitting[rng.randi() % fitting.size()]
			bounds = _kit.bounds(building)
			xform = _row_transform(c, cursor, front, yaw, bounds)
			_kit.add(building, xform)
		else:
			var width := mini(int(remaining) / 2 * 2, [6, 8, 10, 12][rng.randi() % 4])
			var depth: float = [10.0, 12.0, 14.0][rng.randi() % 3]
			var floors := rng.randi_range(3, 8)
			bounds = AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width, floors * 3.0, depth))
			xform = _row_transform(c, cursor, front, yaw, bounds)
			_build_modular(xform, width, depth, floors, roof_mat)
		_add_collision(xform, bounds)
		cursor += bounds.size.x + rng.randf_range(0.0, 0.6)


func _row_transform(c: Vector3, cursor: float, front: float, yaw: float, b: AABB) -> Transform3D:
	var pos: Vector3
	if yaw == 0.0:
		pos = Vector3(c.x + cursor - b.position.x, 0.1, front - b.end.z)
	else:
		pos = Vector3(c.x + cursor + b.end.x, 0.1, front + b.end.z)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


func _add_collision(xform: Transform3D, b: AABB) -> void:
	var body := StaticBody3D.new()
	body.transform = xform
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = b.size
	shape.shape = box
	shape.position = b.get_center()
	body.add_child(shape)
	add_child(body)


## Здание из кусков: стены по 2 м на каждый этаж, колонны по углам, карниз сверху.
func _build_modular(xform: Transform3D, width: int, depth: float, floors: int, roof_mat: Material) -> void:
	var style: Dictionary = STYLES[rng.randi() % STYLES.size()]
	var ground: Array = style["ground"]
	var upper: Array = style["upper"]
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
		var door_at := segments / 2 if side_index == 0 else -1
		for k in segments:
			var offset := -length * 0.5 + 1.0 + 2.0 * k
			var base := normal * half_extent + along * offset
			# Одна и та же деталь по всей высоте столбца — так фасад выглядит цельно
			var upper_piece: String = upper[rng.randi() % upper.size()]
			for f in floors:
				var piece: String
				if f == 0:
					piece = style["door"] if k == door_at else ground[rng.randi() % ground.size()]
				else:
					piece = upper_piece
				_kit.add(piece, xform * Transform3D(basis, base + Vector3.UP * (f * 3.0)))
			_kit.add(style["cornice"], xform * Transform3D(basis, base + Vector3.UP * (floors * 3.0)))
	# Колонны на углах
	for corner in [Vector3(w * 0.5, 0, depth * 0.5), Vector3(-w * 0.5, 0, depth * 0.5),
			Vector3(w * 0.5, 0, -depth * 0.5), Vector3(-w * 0.5, 0, -depth * 0.5)]:
		for f in floors:
			var column := "Trim_Column_Center"
			if f == 0:
				column = "Trim_Column_Bottom"
			elif f == floors - 1:
				column = "Trim_Column_Top"
			_kit.add(column, xform * Transform3D(Basis(), corner + Vector3.UP * (f * 3.0)))
	# Плоская крыша
	var roof := MeshInstance3D.new()
	var roof_mesh := BoxMesh.new()
	roof_mesh.size = Vector3(w - 0.1, 0.2, depth - 0.1)
	roof.mesh = roof_mesh
	roof.material_override = roof_mat
	roof.transform = xform * Transform3D(Basis(), Vector3.UP * (floors * 3.0 - 0.1))
	add_child(roof)


func _build_intersections() -> void:
	for index in (blocks_x + 1) * (blocks_z + 1):
		var node := TrafficIntersection.new()
		node.name = "Intersection%d" % index
		add_child(node)
		node.setup(self, index)
		intersections.append(node)


func _spawn_cars() -> void:
	var colors: Array[Color] = [
		Color(0.85, 0.85, 0.85), Color(0.1, 0.1, 0.12), Color(0.15, 0.3, 0.6),
		Color(0.6, 0.6, 0.62), Color(0.7, 0.15, 0.1), Color(0.9, 0.75, 0.2), Color(0.2, 0.45, 0.3),
	]
	var lanes: Array[Vector2i] = []
	for index in (blocks_x + 1) * (blocks_z + 1):
		for dir in 4:
			if neighbor(index, dir) != -1:
				lanes.append(Vector2i(index, dir))
	var attempts := 0
	while cars.size() < car_count and attempts < car_count * 20:
		attempts += 1
		var lane := lanes[rng.randi() % lanes.size()]
		var to := neighbor(lane.x, lane.y)
		var a := exit_point(lane.x, lane.y)
		var b := stop_point(to, lane.y)
		var pos := a.lerp(b, rng.randf_range(0.05, 0.9))
		var too_close := false
		for other in cars:
			if other.global_position.distance_to(pos) < 9.0:
				too_close = true
				break
		if too_close:
			continue
		var car := TrafficCar.new()
		car.name = "TrafficCar%d" % cars.size()
		add_child(car)
		car.setup(self, lane.x, lane.y, pos, colors[rng.randi() % colors.size()], rng.randf_range(9.0, 13.0))
		cars.append(car)


func _spawn_pedestrians() -> void:
	var shirts: Array[Color] = [
		Color(0.8, 0.2, 0.2), Color(0.2, 0.4, 0.8), Color(0.9, 0.9, 0.9), Color(0.2, 0.6, 0.3),
		Color(0.95, 0.7, 0.2), Color(0.5, 0.3, 0.6), Color(0.15, 0.15, 0.15),
	]
	var skins: Array[Color] = [
		Color(0.95, 0.8, 0.68), Color(0.82, 0.64, 0.5), Color(0.6, 0.42, 0.3), Color(0.4, 0.28, 0.2),
	]
	for n in pedestrian_count:
		var bi := rng.randi() % blocks_x
		var bj := rng.randi() % blocks_z
		var c := global_position + Vector3((bi + 0.5) * pitch, 0.1, (bj + 0.5) * pitch)
		# Петля по тротуару вокруг квартала; у каждого своя «дорожка» по ширине
		var half := block_size * 0.5 - sidewalk_width * 0.5 + rng.randf_range(-0.9, 0.9)
		var loop := PackedVector3Array([
			c + Vector3(-half, 0, -half), c + Vector3(half, 0, -half),
			c + Vector3(half, 0, half), c + Vector3(-half, 0, half),
		])
		if rng.randf() < 0.5:
			loop.reverse()
		var ped := Pedestrian.new()
		ped.name = "Pedestrian%d" % n
		add_child(ped)
		ped.setup(loop, rng.randi() % 4, rng.randf(), rng.randf_range(1.1, 1.7),
				shirts[rng.randi() % shirts.size()], skins[rng.randi() % skins.size()])
