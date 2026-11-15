class_name CityGrid
extends Node3D
## Город по схеме из city_layout.gd: районы, дороги разной ширины, парки,
## набережная, светофоры, машины и пешеходы. Всё строится кодом при запуске.
##
## Узел стоит в северо-западном углу города (у внешнего края кольцевой дороги).
## Перекрёстки нумеруются так: index = i + j * (число столбцов + 1),
## где i — номер дороги «север-юг» с запада, j — номер дороги «запад-восток» с севера.

@export_group("Жизнь")
@export var car_count: int = 60
@export var pedestrian_count: int = 100
@export var random_seed: int = 12345

@export_group("Старт")
## Игрок и его машина появляются в городе у площади (или в деловом центре).
@export var player_path: NodePath
@export var car_path: NodePath

## Направления: 0 — север (-Z), 1 — восток (+X), 2 — юг (+Z), 3 — запад (-X)
const DIRS: Array[Vector3] = [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]

const LANE_WIDTH := 3.5
const CENTER_GAP := 0.6  ## От оси дороги до первой полосы
const AVENUE_WIDTH := 14.0 ## Дорога не уже этого — две полосы в каждую сторону
const MARGIN := 40.0     ## Полоса земли вокруг города
const PROMENADE := 5.0   ## Ширина набережной между дорогой и водой
const FLOOR_HEIGHT := 3.0

## Как застраивается каждая сторона квартала в разных районах
const DOWNTOWN_ROW := {
	"prebuilt": CityModels.PREBUILT_TALL, "prebuilt_chance": 0.2,
	"widths": [8, 10, 12, 14, 16, 18], "depths": [12.0, 14.0, 16.0],
	"floors": Vector2i(5, 18), "gap": Vector2(0.0, 0.6),
	"styles": [CityModels.STYLE_GLASS, CityModels.STYLE_OFFICE, CityModels.STYLE_OFFICE,
			CityModels.STYLE_TRIM, CityModels.STYLE_BRICK_INSET, CityModels.STYLE_REDWHITE],
	"shops": true, "stepped": 0.35, "roof": "flat",
}
const RESIDENTIAL_ROW := {
	"prebuilt": CityModels.PREBUILT_LOW, "prebuilt_chance": 0.15,
	"widths": [6, 8, 10, 12], "depths": [10.0, 12.0],
	"floors": Vector2i(2, 6), "gap": Vector2(0.0, 3.0),
	"styles": [CityModels.STYLE_BRICK, CityModels.STYLE_BRICK_ARCH, CityModels.STYLE_BRICK_INSET,
			CityModels.STYLE_REDWHITE, CityModels.STYLE_TRIM],
	"shops": true, "roof": "tanks",
}
const INDUSTRIAL_ROW := {
	"prebuilt": [], "prebuilt_chance": 0.0,
	"widths": [14, 16, 18, 20, 24], "depths": [16.0, 18.0, 20.0],
	"floors": Vector2i(2, 3), "gap": Vector2(2.0, 6.0),
	"styles": [CityModels.STYLE_WAREHOUSE],
	"roof": "flat",
}

const CAR_COLORS: Array[Color] = [
	Color(0.85, 0.85, 0.85), Color(0.1, 0.1, 0.12), Color(0.15, 0.3, 0.6),
	Color(0.6, 0.6, 0.62), Color(0.7, 0.15, 0.1), Color(0.9, 0.75, 0.2), Color(0.2, 0.45, 0.3),
]

var nx: int ## Столбцов кварталов
var nz: int ## Строк кварталов
var land_columns: int ## Столбцов суши (дальше на восток — вода)
var line_x := PackedFloat32Array() ## Оси дорог «север-юг» (в координатах узла)
var line_z := PackedFloat32Array() ## Оси дорог «запад-восток»
var land_east: float ## Восточный край набережной дороги
var total_z: float
var intersections: Array[TrafficIntersection] = [] ## null там, где перекрёстка нет
var cars: Array[TrafficCar] = []
var rng := RandomNumberGenerator.new()

var _kit: CityKit
var _boxes: BoxBatch
var _builder: BuildingBuilder
var _props: StreetProps
var _mats := {}
var _paint: Array[Transform3D] = []
var _yellow: Array[Transform3D] = []
var _trunks: Array[Transform3D] = []
var _crowns: Array[Array] = [[], []]
var _props_body: StaticBody3D


func _ready() -> void:
	rng.seed = random_seed
	NightLights.clear()
	_compute_lines()
	_props_body = StaticBody3D.new()
	_props_body.name = "Props"
	add_child(_props_body)
	var buildings_body := StaticBody3D.new()
	buildings_body.name = "Buildings"
	add_child(buildings_body)
	_build_ground()
	_build_water()
	_kit = CityKit.new()
	_kit.rng.seed = random_seed + 1
	_boxes = BoxBatch.new()
	_builder = BuildingBuilder.new(_kit, _boxes, rng, buildings_body)
	_props = StreetProps.new(self, _kit, _boxes, rng, _props_body)
	_build_cells()
	_props.build()
	_build_markings()
	_flush_batches()
	_kit.flush(self)
	_boxes.flush(self, "Details")
	# Если игра начинается ночью — сразу включить окна и фонари
	NightLights.set_amount(NightLights.amount, get_tree())
	_build_intersections()
	_spawn_cars()
	_spawn_pedestrians()
	_place_player()


# --- Схема --------------------------------------------------------------------

func _compute_lines() -> void:
	nz = CityLayout.MAP.size()
	nx = CityLayout.MAP[0].length()
	assert(CityLayout.BLOCK_WIDTHS.size() == nx and CityLayout.ROADS_NS.size() == nx + 1)
	assert(CityLayout.BLOCK_DEPTHS.size() == nz and CityLayout.ROADS_EW.size() == nz + 1)
	# Вода — только целыми столбцами у восточного края
	land_columns = nx
	while land_columns > 0 and _column_is_water(land_columns - 1):
		land_columns -= 1
	line_x.resize(nx + 1)
	line_z.resize(nz + 1)
	line_x[0] = CityLayout.ROADS_NS[0] * 0.5
	for i in nx:
		line_x[i + 1] = line_x[i] + (CityLayout.ROADS_NS[i] + CityLayout.ROADS_NS[i + 1]) * 0.5 + CityLayout.BLOCK_WIDTHS[i]
	line_z[0] = CityLayout.ROADS_EW[0] * 0.5
	for j in nz:
		line_z[j + 1] = line_z[j] + (CityLayout.ROADS_EW[j] + CityLayout.ROADS_EW[j + 1]) * 0.5 + CityLayout.BLOCK_DEPTHS[j]
	land_east = line_x[land_columns] + CityLayout.ROADS_NS[land_columns] * 0.5
	total_z = line_z[nz] + CityLayout.ROADS_EW[nz] * 0.5


func _column_is_water(i: int) -> bool:
	for j in nz:
		if cell_type(i, j) != "W":
			return false
	return true


## Буква квартала; "" — за краем схемы.
func cell_type(i: int, j: int) -> String:
	if i < 0 or j < 0 or i >= nx or j >= nz:
		return ""
	return CityLayout.MAP[j][i]


## Квартал без дорог вокруг (x, z, ширина, глубина) в координатах узла.
func cell_rect(i: int, j: int) -> Rect2:
	var x0 := line_x[i] + CityLayout.ROADS_NS[i] * 0.5
	var x1 := line_x[i + 1] - CityLayout.ROADS_NS[i + 1] * 0.5
	var z0 := line_z[j] + CityLayout.ROADS_EW[j] * 0.5
	var z1 := line_z[j + 1] - CityLayout.ROADS_EW[j + 1] * 0.5
	return Rect2(x0, z0, x1 - x0, z1 - z0)


func _road_between(a: String, b: String) -> bool:
	var a_open := a == "" or a == "W"
	var b_open := b == "" or b == "W"
	if a_open and b_open:
		return false
	return not CityLayout.merges(a, b)


## Есть ли кусок дороги «север-юг» номер i между перекрёстками (i, j) и (i, j + 1).
func _segment_ns(i: int, j: int) -> bool:
	return _road_between(cell_type(i - 1, j), cell_type(i, j))


## Есть ли кусок дороги «запад-восток» номер j между перекрёстками (i, j) и (i + 1, j).
func _segment_ew(i: int, j: int) -> bool:
	return _road_between(cell_type(i, j - 1), cell_type(i, j))


# --- Дорожная сеть (ей пользуются машины и светофоры) -------------------------

func index_of(i: int, j: int) -> int:
	if i < 0 or j < 0 or i > nx or j > nz:
		return -1
	return i + j * (nx + 1)


func _ij(index: int) -> Vector2i:
	return Vector2i(index % (nx + 1), index / (nx + 1))


func _local_center(index: int) -> Vector3:
	var ij := _ij(index)
	return Vector3(line_x[ij.x], 0.0, line_z[ij.y])


func center(index: int) -> Vector3:
	return global_position + _local_center(index)


func neighbor(index: int, dir: int) -> int:
	var ij := _ij(index)
	var i := ij.x
	var j := ij.y
	match dir:
		0:
			if j > 0 and _segment_ns(i, j - 1):
				return index_of(i, j - 1)
		1:
			if i < nx and _segment_ew(i, j):
				return index_of(i + 1, j)
		2:
			if j < nz and _segment_ns(i, j):
				return index_of(i, j + 1)
		_:
			if i > 0 and _segment_ew(i - 1, j):
				return index_of(i - 1, j)
	return -1


## Ширина дороги, по которой едут из перекрёстка в направлении dir.
func road_width(index: int, dir: int) -> float:
	var ij := _ij(index)
	return CityLayout.ROADS_NS[ij.x] if dir % 2 == 0 else CityLayout.ROADS_EW[ij.y]


## Половина ширины поперечной дороги — сколько ехать через перекрёсток.
func crossing_half(index: int, dir: int) -> float:
	return road_width(index, dir + 1) * 0.5


## Полос в одну сторону на дороге в направлении dir.
func lanes(index: int, dir: int) -> int:
	return 2 if road_width(index, dir) >= AVENUE_WIDTH else 1


## Расстояние от оси дороги до середины полосы. Полоса 0 — ближняя к оси.
static func lane_offset(lane: int) -> float:
	return CENTER_GAP + LANE_WIDTH * (lane + 0.5)


static func right_of(heading: Vector3) -> Vector3:
	return Vector3(-heading.z, 0.0, heading.x)


## Точка, где машина выезжает из перекрёстка в направлении dir.
func exit_point(index: int, dir: int, lane: int = 0) -> Vector3:
	var h := DIRS[dir]
	return center(index) + h * (crossing_half(index, dir) + 1.0) + right_of(h) * lane_offset(lane)


## Стоп-линия перед перекрёстком для машины, едущей в направлении dir.
func stop_point(index: int, dir: int, lane: int = 0) -> Vector3:
	var h := DIRS[dir]
	return center(index) - h * (crossing_half(index, dir) + 3.0) + right_of(h) * lane_offset(lane)


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


## Полоса после поворота: направо — в крайнюю правую, налево — в левую.
func lane_after_turn(index: int, arriving: int, leaving: int, lane: int) -> int:
	var count := lanes(index, leaving)
	if leaving == (arriving + 1) % 4:
		return count - 1
	if leaving == (arriving + 3) % 4:
		return 0
	return mini(lane, count - 1)


## Плавная траектория через перекрёсток (кривая Безье).
func turn_path(index: int, arriving: int, leaving: int, lane_in: int = 0, lane_out: int = 0) -> PackedVector3Array:
	var p0 := stop_point(index, arriving, lane_in)
	var p2 := exit_point(index, leaving, lane_out)
	var p1: Vector3
	if arriving == leaving:
		p1 = (p0 + p2) * 0.5
	elif arriving % 2 == 0:
		p1 = Vector3(p0.x, p0.y, p2.z)
	else:
		p1 = Vector3(p2.x, p0.y, p0.z)
	var points := PackedVector3Array()
	var steps := 10
	for s in range(1, steps + 1):
		var t := float(s) / steps
		points.append(p0.lerp(p1, t).lerp(p1.lerp(p2, t), t))
	return points


# --- Общие детали -------------------------------------------------------------

func _material(key: String, color: Color, roughness: float = 0.9) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	_mats[key] = m
	return m


func _grass() -> StandardMaterial3D:
	return _material("grass", Color(0.33, 0.47, 0.25))


func _add_box(size: Vector3, pos: Vector3, material: Material, with_collision: bool = false) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = pos
	add_child(mesh)
	if with_collision:
		_add_shape(BoxShape3D.new(), size, Transform3D(Basis(), pos))


func _add_shape(shape: Shape3D, size: Vector3, xform: Transform3D) -> void:
	if shape is BoxShape3D:
		(shape as BoxShape3D).size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xform
	_props_body.add_child(cs)


## Плоская плита на уровне тротуара (без столкновений: о неё не спотыкаться).
func _slab(r: Rect2, height: float, material: Material) -> void:
	var c := r.get_center()
	_add_box(Vector3(r.size.x, 0.1, r.size.y), Vector3(c.x, height - 0.05, c.y), material)


## Разметка: белая или жёлтая полоса заданного размера.
func _add_paint(list: Array[Transform3D], pos: Vector3, along_x: bool, length: float, width: float) -> void:
	var basis := Basis(Vector3.UP, PI * 0.5) if along_x else Basis()
	list.append(Transform3D(basis * Basis.from_scale(Vector3(width, 0.02, length)), pos + Vector3.UP * 0.02))


func _add_tree(pos: Vector3, size: float) -> void:
	_trunks.append(Transform3D(Basis.from_scale(Vector3(size, size, size)), pos + Vector3.UP * 1.5 * size))
	var crown := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(size, size * rng.randf_range(0.9, 1.3), size)),
			pos + Vector3.UP * 3.8 * size)
	_crowns[rng.randi() % 2].append(crown)
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.25 * size
	cyl.height = 3.0 * size
	_add_shape(cyl, Vector3.ZERO, Transform3D(Basis(), pos + Vector3.UP * 1.5 * size))


func _multimesh(mesh: Mesh, transforms: Array, node_name: String) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for k in transforms.size():
		mm.set_instance_transform(k, transforms[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	add_child(mmi)


func _flush_batches() -> void:
	var white := BoxMesh.new()
	white.material = _material("paint", Color(0.95, 0.95, 0.9))
	_multimesh(white, _paint, "PaintWhite")
	var yellow := BoxMesh.new()
	yellow.material = _material("yellow", Color(0.95, 0.75, 0.15))
	_multimesh(yellow, _yellow, "PaintYellow")

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.14
	trunk.bottom_radius = 0.22
	trunk.height = 3.0
	trunk.radial_segments = 6
	trunk.rings = 1
	trunk.material = _material("bark", Color(0.33, 0.24, 0.17))
	_multimesh(trunk, _trunks, "TreeTrunks")
	var shades: Array[Color] = [Color(0.22, 0.45, 0.2), Color(0.3, 0.52, 0.22)]
	for k in 2:
		var crown := SphereMesh.new()
		crown.radius = 2.0
		crown.height = 3.6
		crown.radial_segments = 7
		crown.rings = 4
		crown.material = _material("leaves%d" % k, shades[k])
		_multimesh(crown, _crowns[k], "TreeCrowns%d" % k)


# --- Земля и вода -------------------------------------------------------------

func _build_ground() -> void:
	# Земля с травой по краям и столкновениями для всего города
	var x0 := -MARGIN
	var x1 := land_east + PROMENADE
	var z0 := -MARGIN
	var z1 := total_z + MARGIN
	var depth := 4.0
	var size := Vector3(x1 - x0, depth, z1 - z0)
	_add_box(size, Vector3((x0 + x1) * 0.5, -depth * 0.5, (z0 + z1) * 0.5), _grass(), true)

	# Асфальт под всеми улицами; кварталы ложатся сверху
	var asphalt := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(land_east, total_z)
	asphalt.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.32, 0.33)
	mat.roughness = 0.9
	var texture_path := "res://assets/downtown/T_Concrete_Asphalt_BaseColor.png"
	if ResourceLoader.exists(texture_path):
		# Текстура асфальта из пака, повторяется каждые 8 м
		mat.albedo_color = Color(1.5, 1.47, 1.42)
		mat.albedo_texture = load(texture_path)
		mat.uv1_triplanar = true
		mat.uv1_world_triplanar = true
		mat.uv1_scale = Vector3(0.125, 0.125, 0.125)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	asphalt.material_override = mat
	asphalt.position = Vector3(land_east * 0.5, 0.012, total_z * 0.5)
	add_child(asphalt)


func _build_water() -> void:
	if land_columns == nx:
		return
	var edge := land_east + PROMENADE
	var concrete := _material("concrete", Color(0.62, 0.62, 0.6))
	# Набережная: плитка, бетонная стенка и ограждение
	_slab(Rect2(land_east, -MARGIN, PROMENADE, total_z + MARGIN * 2.0), 0.1, concrete)
	var length := total_z + MARGIN * 2.0
	_add_box(Vector3(0.6, 4.2, length), Vector3(edge + 0.3, -2.0, total_z * 0.5), concrete, true)
	var rail := _material("rail", Color(0.2, 0.22, 0.24), 0.5)
	_add_box(Vector3(0.12, 1.1, length), Vector3(edge - 0.3, 0.55, total_z * 0.5), rail, true)

	# Дно и вода
	var width := 600.0
	var bottom_depth := 6.0
	_add_box(Vector3(width, 1.0, length + 400.0), Vector3(edge + 0.6 + width * 0.5, -bottom_depth - 0.5, total_z * 0.5),
			_material("seabed", Color(0.25, 0.3, 0.28)), true)
	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, length + 400.0)
	water.mesh = plane
	var water_mat := StandardMaterial3D.new()
	water_mat.albedo_color = Color(0.12, 0.3, 0.42)
	water_mat.metallic = 0.3
	water_mat.roughness = 0.08
	water.material_override = water_mat
	water.position = Vector3(edge + 0.6 + width * 0.5, -0.8, total_z * 0.5)
	add_child(water)


# --- Кварталы -----------------------------------------------------------------

func _build_cells() -> void:
	for j in nz:
		for i in land_columns:
			var t := cell_type(i, j)
			if t == "W":
				continue
			var r := cell_rect(i, j)
			var sidewalk: float = CityLayout.SIDEWALK.get(t, 3.0)
			_add_sidewalk_ring(r, sidewalk)
			var inner := r.grow(-sidewalk)
			match t:
				"D": _build_downtown(inner)
				"R": _build_residential(inner)
				"I": _build_industrial(inner)
				"P": _build_park(inner, 1.0 / 80.0)
				"p": _build_park(inner, 1.0 / 130.0)
				"S": _build_square(inner)
				"L": _build_parking(inner)
				_: _slab(inner, 0.1, _material("concrete", Color(0.62, 0.62, 0.6)))
	_fill_merged_roads()


## Где две клетки парка слились, вместо дороги — трава.
func _fill_merged_roads() -> void:
	for j in nz:
		for i in range(1, land_columns):
			var a := cell_type(i - 1, j)
			var b := cell_type(i, j)
			if CityLayout.merges(a, b) and a != "W":
				var r := cell_rect(i, j)
				var w: float = CityLayout.ROADS_NS[i]
				_slab(Rect2(line_x[i] - w * 0.5, r.position.y, w, r.size.y), 0.1, _grass())
	for j in range(1, nz):
		for i in land_columns:
			var a := cell_type(i, j - 1)
			var b := cell_type(i, j)
			if CityLayout.merges(a, b) and a != "W":
				var r := cell_rect(i, j)
				var w: float = CityLayout.ROADS_EW[j]
				_slab(Rect2(r.position.x, line_z[j] - w * 0.5, r.size.x, w), 0.1, _grass())
	# Перекрёсток, к которому не ведёт ни одна дорога, — тоже трава
	for j in range(1, nz):
		for i in range(1, land_columns):
			var index := index_of(i, j)
			var dead := true
			for d in 4:
				if neighbor(index, d) != -1:
					dead = false
			if dead:
				var w: float = CityLayout.ROADS_NS[i]
				var h: float = CityLayout.ROADS_EW[j]
				_slab(Rect2(line_x[i] - w * 0.5, line_z[j] - h * 0.5, w, h), 0.1, _grass())


## Тротуар из плиток по краю квартала, бордюр смотрит на дорогу.
func _add_sidewalk_ring(r: Rect2, sidewalk: float) -> void:
	var across := sidewalk / 3.0
	var c := r.get_center()
	# Северная и южная стороны во всю длину, восточная и западная — между ними
	var sides := [
		[Vector3(0, 0, 1), 0.0, r.size.x, r.size.y * 0.5],
		[Vector3(0, 0, -1), PI, r.size.x, r.size.y * 0.5],
		[Vector3(1, 0, 0), PI * 0.5, r.size.y - sidewalk * 2.0, r.size.x * 0.5],
		[Vector3(-1, 0, 0), -PI * 0.5, r.size.y - sidewalk * 2.0, r.size.x * 0.5],
	]
	for side: Array in sides:
		var normal: Vector3 = side[0]
		var yaw: float = side[1]
		var length: float = side[2]
		var half_extent: float = side[3]
		if length <= 0.5:
			continue
		var along := Vector3(normal.z, 0.0, normal.x).abs()
		var count := maxi(roundi(length / 3.0), 1)
		var tile := length / count
		var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(tile / 3.0, 1.0, across))
		for k in count:
			var offset := -length * 0.5 + tile * (k + 0.5)
			var pos := Vector3(c.x, 0.1, c.y) + normal * (half_extent - sidewalk * 0.5) + along * offset
			_kit.add(CityModels.SIDEWALK_TILE, Transform3D(basis, pos))


func _build_downtown(r: Rect2) -> void:
	_slab(r, 0.1, _material("plaza", Color(0.55, 0.55, 0.53)))
	var north := _builder.row(r, -1.0, DOWNTOWN_ROW)
	var south := _builder.row(r, 1.0, DOWNTOWN_ROW)
	# Между рядами — башня, если хватает места
	var z0 := r.position.y + north + 2.0
	var z1 := r.end.y - south - 2.0
	if z1 - z0 >= 10.0 and r.size.x >= 14.0:
		var width := mini(int(r.size.x - 6.0) / 2 * 2, 20)
		var depth := floorf(minf(z1 - z0, 20.0) / 2.0) * 2.0
		var floors := rng.randi_range(14, 28)
		var pos := Vector3(r.get_center().x, 0.1, (z0 + z1) * 0.5)
		var xform := Transform3D(Basis(Vector3.UP, PI if rng.randf() < 0.5 else 0.0), pos)
		var style: Dictionary = [CityModels.STYLE_GLASS, CityModels.STYLE_OFFICE][rng.randi() % 2]
		if width >= 12 and depth >= 12 and rng.randf() < 0.6:
			_builder.stepped_tower(xform, width, depth, floors, style, {"roof": "flat"})
		else:
			_builder.modular(xform, width, depth, floors, style, {"no_door": true, "antenna": true})
		_builder.collision(xform, AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width, floors * FLOOR_HEIGHT, depth)))


func _build_residential(r: Rect2) -> void:
	_slab(r, 0.1, _material("paving", Color(0.6, 0.58, 0.55)))
	var north := _builder.row(r, -1.0, RESIDENTIAL_ROW)
	var south := _builder.row(r, 1.0, RESIDENTIAL_ROW)
	# Двор: трава и пара деревьев
	var yard := Rect2(r.position.x + 1.0, r.position.y + north + 1.5, r.size.x - 2.0, r.size.y - north - south - 3.0)
	if yard.size.y >= 4.0:
		_slab(yard, 0.12, _grass())
		var count := clampi(int(yard.get_area() / 120.0), 1, 6)
		for k in count:
			var p := Vector2(rng.randf_range(yard.position.x + 2.0, yard.end.x - 2.0), rng.randf_range(yard.position.y + 2.0, yard.end.y - 2.0))
			if yard.size.y >= 6.0:
				_add_tree(Vector3(p.x, 0.12, p.y), rng.randf_range(0.7, 1.0))


func _build_industrial(r: Rect2) -> void:
	_slab(r, 0.1, _material("yard", Color(0.45, 0.45, 0.44)))
	var north := _builder.row(r, -1.0, INDUSTRIAL_ROW)
	var south := _builder.row(r, 1.0, INDUSTRIAL_ROW)
	# Во дворе — контейнеры
	var yard := Rect2(r.position.x + 3.0, r.position.y + north + 3.0, r.size.x - 6.0, r.size.y - north - south - 6.0)
	if yard.size.y < 6.5:
		return
	var colors: Array[Color] = [Color(0.7, 0.2, 0.15), Color(0.15, 0.35, 0.6), Color(0.2, 0.5, 0.3), Color(0.8, 0.55, 0.15), Color(0.5, 0.5, 0.5)]
	var x := yard.position.x
	while x + 2.4 <= yard.end.x:
		if rng.randf() < 0.7:
			var color := colors[rng.randi() % colors.size()]
			var mat := _material("container%d" % colors.find(color), color, 0.6)
			for s in rng.randi_range(1, 2):
				_add_box(Vector3(2.4, 2.6, 6.0), Vector3(x + 1.2, 0.1 + 1.3 + s * 2.6, yard.get_center().y), mat, true)
		x += 3.2


func _build_park(r: Rect2, density: float) -> void:
	_slab(r, 0.12, _grass())
	# Дорожки крестом через центр
	var path := _material("path", Color(0.72, 0.66, 0.55))
	var c := r.get_center()
	_slab(Rect2(r.position.x, c.y - 1.25, r.size.x, 2.5), 0.14, path)
	_slab(Rect2(c.x - 1.25, r.position.y, 2.5, r.size.y), 0.14, path)
	var placed: Array[Vector2] = []
	var target := int(r.get_area() * density)
	var attempts := 0
	while placed.size() < target and attempts < target * 10:
		attempts += 1
		var p := Vector2(rng.randf_range(r.position.x + 1.5, r.end.x - 1.5), rng.randf_range(r.position.y + 1.5, r.end.y - 1.5))
		if absf(p.x - c.x) < 3.0 or absf(p.y - c.y) < 3.0:
			continue
		var ok := true
		for other in placed:
			if other.distance_to(p) < 4.5:
				ok = false
				break
		if ok:
			placed.append(p)
			_add_tree(Vector3(p.x, 0.12, p.y), rng.randf_range(0.8, 1.4))


func _build_square(r: Rect2) -> void:
	_slab(r, 0.12, _material("square", Color(0.6, 0.58, 0.55)))
	var c := r.get_center()
	# Фонтан
	var stone := _material("stone", Color(0.8, 0.78, 0.74))
	var basin := MeshInstance3D.new()
	var basin_mesh := CylinderMesh.new()
	basin_mesh.top_radius = 5.0
	basin_mesh.bottom_radius = 5.0
	basin_mesh.height = 0.7
	basin.mesh = basin_mesh
	basin.material_override = stone
	basin.position = Vector3(c.x, 0.35, c.y)
	add_child(basin)
	var basin_shape := CylinderShape3D.new()
	basin_shape.radius = 5.0
	basin_shape.height = 0.7
	_add_shape(basin_shape, Vector3.ZERO, Transform3D(Basis(), basin.position))
	var pool := MeshInstance3D.new()
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 4.5
	pool_mesh.bottom_radius = 4.5
	pool_mesh.height = 0.05
	pool.mesh = pool_mesh
	pool.material_override = _material("pool", Color(0.2, 0.45, 0.6), 0.05)
	pool.position = Vector3(c.x, 0.71, c.y)
	add_child(pool)
	_add_box(Vector3(1.0, 3.0, 1.0), Vector3(c.x, 1.5, c.y), stone, true)
	# Деревья по краю площади
	var inset := 2.5
	for edge in 4:
		var horizontal := edge < 2
		var length := r.size.x if horizontal else r.size.y
		var count := int(length / 9.0)
		for k in count:
			var t := (k + 0.5) / count
			var p: Vector2
			if horizontal:
				p = Vector2(r.position.x + r.size.x * t, r.position.y + inset if edge == 0 else r.end.y - inset)
			else:
				p = Vector2(r.position.x + inset if edge == 2 else r.end.x - inset, r.position.y + r.size.y * t)
			_add_tree(Vector3(p.x, 0.12, p.y), 0.9)


func _build_parking(r: Rect2) -> void:
	_slab(r, 0.1, _material("lot", Color(0.28, 0.28, 0.29)))
	var stall := 2.8
	var depth := 5.5
	var count := int(r.size.x / stall)
	var start := r.position.x + (r.size.x - count * stall) * 0.5
	for row: float in [-1.0, 1.0]:
		var edge := r.position.y if row < 0.0 else r.end.y
		var z := edge - row * depth * 0.5
		for k in count + 1:
			_add_paint(_paint, Vector3(start + k * stall, 0.1, z), false, depth, 0.12)
		for k in count:
			if rng.randf() < 0.65:
				_add_parked_car(Vector3(start + (k + 0.5) * stall, 0.1, z), row)


## Припаркованная машина носом к проезду.
func _add_parked_car(pos: Vector3, facing: float) -> void:
	_props.parked_car(pos - Vector3.UP * 0.1, Vector3(0, 0, -facing))


# --- Разметка -----------------------------------------------------------------

func _build_markings() -> void:
	for index in (nx + 1) * (nz + 1):
		for dir: int in [1, 2]: # каждый кусок дороги рисуем один раз: на восток и на юг
			var next := neighbor(index, dir)
			if next != -1:
				_mark_segment(index, next, dir)
		if _approach_count(index) < 3:
			continue
		for dir in 4:
			if neighbor(index, (dir + 2) % 4) == -1:
				continue
			# Стоп-линия поперёк полос своего направления
			var h := DIRS[dir]
			var n := lanes(index, dir)
			var across := CENTER_GAP + n * LANE_WIDTH
			# Стоп-линия за зеброй (зебра — 0.6…3.4 м от края перекрёстка)
			var p := _local_center(index) - h * (crossing_half(index, dir) + 3.8) + right_of(h) * (across * 0.5 + 0.1)
			_add_paint(_paint, p, dir % 2 == 0, across - 0.2, 0.4)


func _mark_segment(index: int, next: int, dir: int) -> void:
	var h := DIRS[dir]
	var along_x := dir % 2 == 1
	var start := _local_center(index) + h * (crossing_half(index, dir) + 2.0)
	var finish := _local_center(next) - h * (crossing_half(next, dir) + 2.0)
	var length := (finish - start).dot(h)
	if length <= 1.0:
		return
	var mid := (start + finish) * 0.5
	var side := right_of(h)
	if lanes(index, dir) == 1:
		# Прерывистая осевая
		var t := 0.0
		while t + 2.0 <= length:
			_add_paint(_paint, start + h * (t + 1.0), along_x, 2.0, 0.15)
			t += 5.0
		return
	# Проспект: двойная жёлтая по оси и прерывистые между полосами
	for s: float in [-1.0, 1.0]:
		_add_paint(_yellow, mid + side * (0.15 * s), along_x, length, 0.12)
		var lane_line := mid + side * (s * (CENTER_GAP + LANE_WIDTH))
		var t := 0.0
		while t + 3.0 <= length:
			_add_paint(_paint, lane_line - mid + start + h * (t + 1.5), along_x, 3.0, 0.15)
			t += 9.0


func approach_count(index: int) -> int:
	return _approach_count(index)


func local_center(index: int) -> Vector3:
	return _local_center(index)


## Дерево у тротуара (для деталей улиц).
func add_street_tree(pos: Vector3, size: float) -> void:
	_add_tree(pos, size)


func _approach_count(index: int) -> int:
	var count := 0
	for dir in 4:
		if neighbor(index, dir) != -1:
			count += 1
	return count


# --- Светофоры, машины, пешеходы ---------------------------------------------

func _build_intersections() -> void:
	intersections.resize((nx + 1) * (nz + 1))
	for index in intersections.size():
		if _approach_count(index) == 0:
			continue
		var node := TrafficIntersection.new()
		node.name = "Intersection%d" % index
		add_child(node)
		node.setup(self, index, _approach_count(index) >= 3)
		intersections[index] = node


func _spawn_cars() -> void:
	var lanes_list: Array[Vector3i] = []
	for index in (nx + 1) * (nz + 1):
		for dir in 4:
			if neighbor(index, dir) != -1:
				for lane in lanes(index, dir):
					lanes_list.append(Vector3i(index, dir, lane))
	if lanes_list.is_empty():
		return
	var attempts := 0
	while cars.size() < car_count and attempts < car_count * 20:
		attempts += 1
		var lane := lanes_list[rng.randi() % lanes_list.size()]
		var to := neighbor(lane.x, lane.y)
		var a := exit_point(lane.x, lane.y, lane.z)
		var b := stop_point(to, lane.y, lane.z)
		if (b - a).dot(DIRS[lane.y]) < 4.0:
			continue
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
		car.setup(self, lane.x, lane.y, lane.z, pos, CAR_COLORS[rng.randi() % CAR_COLORS.size()], rng.randf_range(9.0, 13.0))
		cars.append(car)


func _spawn_pedestrians() -> void:
	var shirts: Array[Color] = [
		Color(0.8, 0.2, 0.2), Color(0.2, 0.4, 0.8), Color(0.9, 0.9, 0.9), Color(0.2, 0.6, 0.3),
		Color(0.95, 0.7, 0.2), Color(0.5, 0.3, 0.6), Color(0.15, 0.15, 0.15),
	]
	var skins: Array[Color] = [
		Color(0.95, 0.8, 0.68), Color(0.82, 0.64, 0.5), Color(0.6, 0.42, 0.3), Color(0.4, 0.28, 0.2),
	]
	# Больше людей в центре, меньше в промзоне
	var weights := {"D": 4, "S": 4, "R": 2, "p": 2, "P": 1, "L": 1, "I": 1}
	var walkable: Array[Vector2i] = []
	for j in nz:
		for i in land_columns:
			for k in int(weights.get(cell_type(i, j), 0)):
				walkable.append(Vector2i(i, j))
	if walkable.is_empty():
		return
	for n in pedestrian_count:
		var cell := walkable[rng.randi() % walkable.size()]
		var r := cell_rect(cell.x, cell.y)
		var sidewalk: float = CityLayout.SIDEWALK.get(cell_type(cell.x, cell.y), 3.0)
		# Петля по тротуару вокруг квартала; у каждого своя «дорожка» по ширине
		var inset := sidewalk * 0.5 + rng.randf_range(-sidewalk * 0.3, sidewalk * 0.3)
		var a := global_position + Vector3(r.position.x + inset, 0.1, r.position.y + inset)
		var b := global_position + Vector3(r.end.x - inset, 0.1, r.end.y - inset)
		var loop := PackedVector3Array([a, Vector3(b.x, a.y, a.z), b, Vector3(a.x, a.y, b.z)])
		if rng.randf() < 0.5:
			loop.reverse()
		var ped := Pedestrian.new()
		ped.name = "Pedestrian%d" % n
		add_child(ped)
		ped.setup(loop, rng.randi() % 4, rng.randf(), rng.randf_range(1.1, 1.7),
				shirts[rng.randi() % shirts.size()], skins[rng.randi() % skins.size()])


## Ставит игрока на тротуар у площади, а его машину — у бордюра рядом.
func _place_player() -> void:
	var spot := Vector2i(-1, -1)
	for wanted: String in ["S", "D"]:
		for j in nz:
			for i in land_columns:
				if spot.x < 0 and cell_type(i, j) == wanted:
					spot = Vector2i(i, j)
	if spot.x < 0:
		return
	var r := cell_rect(spot.x, spot.y)
	var sidewalk: float = CityLayout.SIDEWALK.get(cell_type(spot.x, spot.y), 3.0)
	# Машина на дороге южнее квартала, едет на восток, у правого бордюра
	var road_index := index_of(spot.x, spot.y + 1)
	var lane := lanes(road_index, 1) - 1
	var car_pos := global_position + Vector3(r.get_center().x + 3.0, 0.6, line_z[spot.y + 1] + lane_offset(lane))
	var car := get_node_or_null(car_path) as Node3D
	if car != null:
		car.global_transform = Transform3D(Basis(Vector3.UP, PI * 0.5), car_pos)
	var player := get_node_or_null(player_path) as Node3D
	if player != null:
		player.global_position = global_position + Vector3(r.get_center().x - 3.0, 0.3, r.end.y - sidewalk * 0.5)
