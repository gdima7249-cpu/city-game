class_name TrafficIntersection
extends Node3D
## Перекрёсток со светофорами.
##
## Зелёный горит по очереди для каждого въезда отдельно, поэтому машины
## на перекрёстке никогда не пересекают пути друг друга.

enum Light { RED, YELLOW, GREEN }

const GREEN_TIME := 7.0
const YELLOW_TIME := 2.0
const ALL_RED_TIME := 1.5

var grid: CityGrid
var index: int

var _approaches: Array[int] = [] # направления, с которых можно въехать
var _current := 0
var _phase := 0 # 0 зелёный, 1 жёлтый, 2 все красные
var _timer := 0.0
var _lamps := {} # направление -> [красная, жёлтая, зелёная] материалы


func setup(city: CityGrid, idx: int) -> void:
	grid = city
	index = idx
	global_position = grid.center(index)
	for dir in 4:
		# Въезд в направлении dir существует, если есть соседний перекрёсток позади
		if grid.neighbor(index, (dir + 2) % 4) != -1:
			_approaches.append(dir)
	_current = grid.rng.randi() % maxi(_approaches.size(), 1)
	_timer = grid.rng.randf_range(0.0, GREEN_TIME)
	for dir in _approaches:
		_build_light(dir)
	_update_lamps()


func light_for(dir: int) -> Light:
	if _approaches.is_empty() or _approaches[_current] != dir:
		return Light.RED
	match _phase:
		0: return Light.GREEN
		1: return Light.YELLOW
		_: return Light.RED


func _process(delta: float) -> void:
	if _approaches.is_empty():
		return
	_timer += delta
	var limit: float = [GREEN_TIME, YELLOW_TIME, ALL_RED_TIME][_phase]
	if _timer < limit:
		return
	_timer = 0.0
	_phase += 1
	if _phase > 2:
		_phase = 0
		_current = (_current + 1) % _approaches.size()
	_update_lamps()


func _build_light(dir: int) -> void:
	var h := CityGrid.DIRS[dir]
	var half := grid.road_width * 0.5
	# Столб на правом углу перед перекрёстком
	var base := -h * (half + 0.8) + CityGrid.right_of(h) * (half + 0.8)
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.1
	pole_mesh.height = 3.6
	pole.mesh = pole_mesh
	pole.position = base + Vector3.UP * 1.8
	pole.material_override = _plain(Color(0.15, 0.15, 0.15))
	add_child(pole)

	var housing := MeshInstance3D.new()
	var housing_mesh := BoxMesh.new()
	housing_mesh.size = Vector3(0.4, 1.1, 0.3)
	housing.mesh = housing_mesh
	housing.material_override = _plain(Color(0.1, 0.1, 0.1))
	housing.position = base + Vector3.UP * 3.9
	add_child(housing)

	var mats: Array[StandardMaterial3D] = []
	var colors: Array[Color] = [Color(1, 0.1, 0.05), Color(1, 0.75, 0.05), Color(0.1, 1, 0.3)]
	for k in 3:
		var lamp := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.13
		sphere.height = 0.26
		lamp.mesh = sphere
		var m := _plain(colors[k] * 0.25)
		m.emission = colors[k]
		mats.append(m)
		lamp.material_override = m
		# Лампы смотрят навстречу машинам
		lamp.position = base + Vector3.UP * (4.25 - k * 0.35) - h * 0.17
		add_child(lamp)
	_lamps[dir] = mats


func _update_lamps() -> void:
	for dir in _lamps:
		var state := light_for(dir)
		var mats: Array = _lamps[dir]
		for k in 3:
			var on := (k == 0 and state == Light.RED) or (k == 1 and state == Light.YELLOW) \
					or (k == 2 and state == Light.GREEN)
			var m: StandardMaterial3D = mats[k]
			m.emission_enabled = on
			m.emission_energy_multiplier = 3.0


func _plain(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.7
	return m
