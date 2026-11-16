class_name StreetProps
extends RefCounted
## Всё, что стоит на улицах: фонари (ночью горят), деревья вдоль тротуаров,
## скамейки, урны, гидранты, остановки, знаки, зебры, люки и машины,
## припаркованные у бордюров.

const LAMP_STEP := 24.0       ## Шаг фонарей вдоль улицы
const TREE_STEP := 12.0       ## Шаг деревьев вдоль тротуара
const PARKING_ROAD := Vector2(10.0, 13.0) ## Парковка у бордюра на улицах такой ширины
const LAMP_RANGE := 18.0
const LAMP_ENERGY := 2.2
const SMALL_DRAW := 200.0     ## Мелочи не рисуются дальше этого

var grid: CityGrid
var kit: CityKit
var boxes: BoxBatch
var rng: RandomNumberGenerator
var body: StaticBody3D
var cars := ModelBatch.new()

var _mats := {}
var _lamp_head: StandardMaterial3D


func _init(p_grid: CityGrid, p_kit: CityKit, p_boxes: BoxBatch, p_rng: RandomNumberGenerator, p_body: StaticBody3D) -> void:
	grid = p_grid
	kit = p_kit
	boxes = p_boxes
	rng = p_rng
	body = p_body
	cars.draw_range = 450.0
	_lamp_head = NightLights.glowing(Color(1.0, 0.88, 0.65), 4.0)


func _mat(key: String, color: Color, roughness: float = 0.7) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = roughness
		_mats[key] = m
	return _mats[key]


func build() -> void:
	for j in grid.nz:
		for i in grid.land_columns:
			var t := grid.cell_type(i, j)
			if t == "W":
				continue
			_cell(i, j, t)
	_crosswalks()
	cars.flush(grid, "ParkedCars")


## Четыре стороны квартала: вдоль каждой, где есть дорога, — фонари, деревья и прочее.
func _cell(i: int, j: int, t: String) -> void:
	var r := grid.cell_rect(i, j)
	var sidewalk: float = CityLayout.SIDEWALK.get(t, 3.0)
	# [начало стороны, направление вдоль, наружу к дороге, длина, ширина дороги, соседняя клетка]
	var sides := [
		[Vector3(r.position.x, 0, r.position.y), Vector3(1, 0, 0), Vector3(0, 0, -1), r.size.x, CityLayout.ROADS_EW[j], grid.cell_type(i, j - 1)],
		[Vector3(r.position.x, 0, r.end.y), Vector3(1, 0, 0), Vector3(0, 0, 1), r.size.x, CityLayout.ROADS_EW[j + 1], grid.cell_type(i, j + 1)],
		[Vector3(r.position.x, 0, r.position.y), Vector3(0, 0, 1), Vector3(-1, 0, 0), r.size.y, CityLayout.ROADS_NS[i], grid.cell_type(i - 1, j)],
		[Vector3(r.end.x, 0, r.position.y), Vector3(0, 0, 1), Vector3(1, 0, 0), r.size.y, CityLayout.ROADS_NS[i + 1], grid.cell_type(i + 1, j)],
	]
	for side: Array in sides:
		var neighbor_type: String = side[5]
		if CityLayout.merges(t, neighbor_type):
			continue # внутри большого парка дороги нет
		_side(side[0], side[1], side[2], side[3], side[4], sidewalk, t)
	if t == "S":
		_square_bollards(r)


func _side(start: Vector3, along: Vector3, out: Vector3, length: float, road: float, sidewalk: float, t: String) -> void:
	var curb := start + Vector3.UP * 0.1
	var busy := t in ["D", "S", "R"]
	# Фонари
	var lamp_step := LAMP_STEP * (0.85 if t in ["D", "S"] else 1.0)
	var count := maxi(int((length - 8.0) / lamp_step), 1)
	for k in count + 1:
		var d := 4.0 + (length - 8.0) * k / maxf(count, 1)
		_lamp(curb + along * d - out * 0.45, out)
	# Деревья вдоль тротуара, между ними скамейки и урны
	if busy and sidewalk >= 3.0:
		var trees := int((length - 10.0) / TREE_STEP)
		for k in trees:
			var d := 5.0 + TREE_STEP * (k + 0.5)
			if d > length - 5.0:
				break
			var p := curb + along * d - out * 1.1
			grid.add_street_tree(p, rng.randf_range(0.6, 0.8))
			boxes.box(Transform3D(Basis(), p + Vector3.UP * 0.03), Vector3(1.3, 0.06, 1.3), _mat("pit", Color(0.25, 0.2, 0.16), 1.0), SMALL_DRAW)
			var roll := rng.randf()
			if roll < 0.18:
				_bench(curb + along * (d + TREE_STEP * 0.5) - out * 1.1, out)
			elif roll < 0.3:
				_bin(curb + along * (d + 2.0) - out * 0.6)
	elif t in ["P", "p"] and rng.randf() < 0.5:
		_bench(curb + along * length * rng.randf_range(0.3, 0.7) - out * (sidewalk - 0.6), -out)
	# Гидрант
	if rng.randf() < 0.5:
		_hydrant(curb + along * rng.randf_range(8.0, maxf(length - 8.0, 8.1)) - out * 0.5)
	# Остановка на проспектах
	if road >= CityGrid.AVENUE_WIDTH and busy and length > 30.0 and rng.randf() < 0.35:
		_bus_stop(curb + along * (length * 0.5) - out * (sidewalk - 1.0), along, out)
	# Решётки водостока у бордюра и люки на дороге
	for k in int(length / 30.0):
		var d := rng.randf_range(6.0, length - 6.0)
		kit.add(CityModels.DRAIN, Transform3D(Basis(), curb + along * d + out * 0.4 - Vector3.UP * 0.085))
	if rng.randf() < 0.5:
		var p := curb + along * rng.randf_range(10.0, maxf(length - 10.0, 10.1)) + out * (road * 0.5 - 2.0)
		kit.add(CityModels.MANHOLE, Transform3D(Basis(), p - Vector3.UP * 0.085))
	# Знак ограничения скорости на проспектах
	if road >= CityGrid.AVENUE_WIDTH and rng.randf() < 0.4:
		_speed_sign(curb + along * 6.0 - out * 0.4, out, along)
	# Машины у бордюра
	if road >= PARKING_ROAD.x and road <= PARKING_ROAD.y and t in ["D", "R", "I", "S"]:
		_parked_row(curb, along, out, length)


func _lamp(base: Vector3, out: Vector3) -> void:
	var dark := _mat("lamp_pole", Color(0.16, 0.17, 0.18), 0.5)
	var basis := Basis.looking_at(out, Vector3.UP)
	boxes.cylinder(Transform3D(Basis(), base + Vector3.UP * 3.25), Vector3(0.16, 6.5, 0.16), dark)
	boxes.cylinder(Transform3D(Basis(), base + Vector3.UP * 0.3), Vector3(0.3, 0.6, 0.3), dark, SMALL_DRAW)
	var arm_end := base + out * 1.6 + Vector3.UP * 6.4
	boxes.box(Transform3D(basis, base + out * 0.8 + Vector3.UP * 6.45), Vector3(0.1, 0.1, 1.7), dark)
	boxes.box(Transform3D(basis, arm_end), Vector3(0.35, 0.14, 0.7), _lamp_head)
	_shape(Transform3D(Basis(), base + Vector3.UP * 2.0), Vector3(0.25, 4.0, 0.25))
	var light := OmniLight3D.new()
	light.position = arm_end - Vector3.UP * 0.3
	light.omni_range = LAMP_RANGE
	light.omni_attenuation = 1.2
	light.light_color = Color(1.0, 0.85, 0.62)
	light.light_energy = 0.0
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 110.0
	light.distance_fade_length = 30.0
	light.visible = false
	light.set_meta("energy", LAMP_ENERGY)
	light.add_to_group(NightLights.GROUP)
	grid.add_child(light)


func _bench(pos: Vector3, facing: Vector3) -> void:
	var basis := Basis.looking_at(facing, Vector3.UP)
	var wood := _mat("bench_wood", Color(0.5, 0.33, 0.2))
	var metal := _mat("bench_metal", Color(0.15, 0.15, 0.16), 0.4)
	boxes.box(Transform3D(basis, pos + Vector3.UP * 0.45), Vector3(1.8, 0.08, 0.5), wood, SMALL_DRAW)
	boxes.box(Transform3D(basis, pos + Vector3.UP * 0.75 + basis * Vector3(0, 0, 0.25)), Vector3(1.8, 0.45, 0.06), wood, SMALL_DRAW)
	for x: float in [-0.75, 0.75]:
		boxes.box(Transform3D(basis, pos + basis * Vector3(x, 0.22, 0)), Vector3(0.08, 0.45, 0.45), metal, SMALL_DRAW)
	_shape(Transform3D(basis, pos + Vector3.UP * 0.45), Vector3(1.8, 0.9, 0.5))


func _bin(pos: Vector3) -> void:
	boxes.cylinder(Transform3D(Basis(), pos + Vector3.UP * 0.45), Vector3(0.5, 0.9, 0.5), _mat("bin", Color(0.12, 0.3, 0.2), 0.5), SMALL_DRAW)


func _hydrant(pos: Vector3) -> void:
	var red := _mat("hydrant", Color(0.75, 0.1, 0.08), 0.5)
	boxes.cylinder(Transform3D(Basis(), pos + Vector3.UP * 0.35), Vector3(0.28, 0.7, 0.28), red, SMALL_DRAW)
	boxes.cylinder(Transform3D(Basis(), pos + Vector3.UP * 0.75), Vector3(0.22, 0.12, 0.22), red, SMALL_DRAW)
	boxes.cylinder(Transform3D(Basis(Vector3.FORWARD, PI * 0.5), pos + Vector3.UP * 0.5), Vector3(0.12, 0.45, 0.12), red, SMALL_DRAW)


func _bus_stop(pos: Vector3, along: Vector3, out: Vector3) -> void:
	var basis := Basis.looking_at(out, Vector3.UP)
	var frame := _mat("stop_frame", Color(0.2, 0.22, 0.25), 0.4)
	var glass := _mat("stop_glass", Color(0.55, 0.68, 0.75), 0.1)
	boxes.box(Transform3D(basis, pos + Vector3.UP * 2.5), Vector3(4.0, 0.12, 1.6), frame)
	boxes.box(Transform3D(basis, pos + Vector3.UP * 1.25 + basis * Vector3(0, 0, 0.75)), Vector3(3.9, 2.4, 0.06), glass)
	for x: float in [-1.9, 1.9]:
		boxes.box(Transform3D(basis, pos + basis * Vector3(x, 1.25, 0.75)), Vector3(0.08, 2.5, 0.08), frame)
	boxes.box(Transform3D(basis, pos + basis * Vector3(1.9, 1.5, 0.0)), Vector3(0.06, 1.6, 1.2), _mat_glow("ad", Color(0.95, 0.95, 0.9), 2.0))
	_bench(pos + basis * Vector3(-0.5, 0, 0.3), out)
	_shape(Transform3D(basis, pos + Vector3.UP * 1.25 + basis * Vector3(0, 0, 0.75)), Vector3(4.0, 2.5, 0.1))
	# Знак остановки
	var sign_pos := pos + along * 2.8 + out * 0.6
	boxes.cylinder(Transform3D(Basis(), sign_pos + Vector3.UP * 1.4), Vector3(0.08, 2.8, 0.08), frame, SMALL_DRAW)
	boxes.box(Transform3D(basis, sign_pos + Vector3.UP * 2.6), Vector3(0.5, 0.5, 0.04), _mat("bus_sign", Color(0.1, 0.35, 0.75), 0.4), SMALL_DRAW)


func _mat_glow(key: String, color: Color, energy: float) -> StandardMaterial3D:
	if not _mats.has(key):
		_mats[key] = NightLights.glowing(color, energy)
	return _mats[key]


func _speed_sign(pos: Vector3, out: Vector3, along: Vector3) -> void:
	var pole := _mat("lamp_pole", Color(0.16, 0.17, 0.18), 0.5)
	boxes.cylinder(Transform3D(Basis(), pos + Vector3.UP * 1.25), Vector3(0.07, 2.5, 0.07), pole, SMALL_DRAW)
	# Круглый знак смотрит навстречу машинам, едущим вдоль along
	var face := Basis.looking_at(-along, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
	boxes.cylinder(Transform3D(face, pos + Vector3.UP * 2.5), Vector3(0.7, 0.03, 0.7), _mat("sign_red", Color(0.8, 0.1, 0.08), 0.5), SMALL_DRAW)
	boxes.cylinder(Transform3D(face, pos + Vector3.UP * 2.5 - along * 0.02), Vector3(0.52, 0.03, 0.52), _mat("sign_white", Color(0.95, 0.95, 0.95), 0.5), SMALL_DRAW)


func _parked_row(curb: Vector3, along: Vector3, out: Vector3, length: float) -> void:
	if VehicleModels.TRAFFIC.is_empty():
		return
	# Машины смотрят туда же, куда едет трафик в этой половине дороги
	var heading := Vector3(-out.z, 0.0, out.x)
	var basis := Basis.looking_at(heading, Vector3.UP)
	var extra := Transform3D(Basis(Vector3.UP, deg_to_rad(VehicleModels.TRAFFIC_YAW_DEGREES)).scaled(Vector3.ONE * VehicleModels.SCALE), Vector3.ZERO)
	var d := 12.0
	while d < length - 12.0:
		if rng.randf() < 0.5:
			var pos := curb + along * d + out * 1.15 - Vector3.UP * 0.1
			var path: String = VehicleModels.TRAFFIC[rng.randi() % VehicleModels.TRAFFIC.size()]
			cars.add(path, Transform3D(basis, pos), extra)
			_shape(Transform3D(basis, pos + Vector3.UP * 0.75), Vector3(1.8, 1.4, 4.2))
		d += 6.5


## Машина на парковке (для кварталов-парковок).
func parked_car(pos: Vector3, heading: Vector3) -> void:
	if VehicleModels.TRAFFIC.is_empty():
		return
	var basis := Basis.looking_at(heading, Vector3.UP)
	var extra := Transform3D(Basis(Vector3.UP, deg_to_rad(VehicleModels.TRAFFIC_YAW_DEGREES)).scaled(Vector3.ONE * VehicleModels.SCALE), Vector3.ZERO)
	var path: String = VehicleModels.TRAFFIC[rng.randi() % VehicleModels.TRAFFIC.size()]
	cars.add(path, Transform3D(basis, pos), extra)
	_shape(Transform3D(basis, pos + Vector3.UP * 0.75), Vector3(1.8, 1.4, 4.2))


func _square_bollards(r: Rect2) -> void:
	for edge in 4:
		var horizontal := edge < 2
		var length := r.size.x if horizontal else r.size.y
		var k := 3.0
		while k < length - 3.0:
			var p: Vector3
			if horizontal:
				p = Vector3(r.position.x + k, 0.1, r.position.y + 0.3 if edge == 0 else r.end.y - 0.3)
			else:
				p = Vector3(r.position.x + 0.3 if edge == 2 else r.end.x - 0.3, 0.1, r.position.y + k)
			# Не ставим столбик вплотную к приствольной клетке дерева (деревья через TREE_STEP от 11 м)
			var from_tree := fposmod(k - 5.0 - TREE_STEP * 0.5, TREE_STEP)
			if from_tree > 1.5 and from_tree < TREE_STEP - 1.5:
				kit.add(CityModels.BOLLARD, Transform3D(Basis(), p))
			k += 4.0


## Зебры на всех перекрёстках со светофорами.
func _crosswalks() -> void:
	var paint := _mat("crosswalk", Color(0.93, 0.93, 0.9), 0.8)
	for index in (grid.nz + 1) * (grid.nx + 1):
		if grid.approach_count(index) < 3:
			continue
		var center := grid.local_center(index)
		for dir in 4:
			if grid.neighbor(index, dir) == -1:
				continue
			var h := CityGrid.DIRS[dir]
			var side := CityGrid.right_of(h)
			var half := grid.road_width(index, dir) * 0.5
			var start := center + h * (grid.crossing_half(index, dir) + 0.6)
			var s := -half + 0.8
			while s <= half - 0.8:
				var basis := Basis.looking_at(h, Vector3.UP)
				boxes.box(Transform3D(basis, start + h * 1.4 + side * s + Vector3.UP * 0.025), Vector3(0.5, 0.02, 2.8), paint, 300.0)
				s += 1.1


func _shape(xform: Transform3D, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = xform
	body.add_child(cs)
