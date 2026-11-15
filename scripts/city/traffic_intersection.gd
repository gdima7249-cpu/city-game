class_name TrafficIntersection
extends Node3D
## Перекрёсток со светофорами.
##
## Зелёный горит по очереди для каждого въезда отдельно, поэтому машины
## на перекрёстке никогда не пересекают пути друг друга.
## На поворотах и прямых стыках (меньше трёх дорог) светофора нет: всегда «зелёный».
##
## Светофор «умный»: зелёный не горит впустую. Если к въезду никто не едет,
## его пропускают, а если машины кончились — зелёный выключают раньше.
##
## Пешеходы: на перекрёстках со светофором (там нарисованы зебры) по «кнопке»
## (кто-то ждёт у зебры) включается пешеходная фаза: всем машинам красный,
## людям зелёный на всех переходах сразу.
##
## Вся «железная» часть (столбы, корпуса, лампы) нарисована тремя MultiMesh
## на перекрёсток, чтобы не тратить сотни отдельных вызовов отрисовки.

enum Light { RED, YELLOW, GREEN }

const MIN_GREEN := 4.0     ## Зелёный горит не меньше этого
const GREEN_TIME := 10.0   ## и не больше этого, если кто-то ждёт на других въездах
const YELLOW_TIME := 2.0
const ALL_RED_TIME := 1.5
const WALK_TIME := 7.0       ## Пешеходам зелёный
const WALK_CLEAR_TIME := 2.5 ## Мигающий пешеходный: новые не выходят, машины ещё стоят
const PED_EVERY := 2         ## Пешеходам — не реже, чем через столько въездов (если ждут)
const DEMAND_RANGE := 45.0   ## Машина ближе этого к стоп-линии «нажимает кнопку»
const VISIBLE_RANGE := 250.0 ## Дальше этого светофор не рисуется
## Зебра и стоп-линия (их рисует city_grid.gd): расстояния от края поперечной дороги
const ZEBRA_FROM := 0.6
const ZEBRA_WIDTH := 2.8
const STOP_LINE := 3.8

const LAMP_COLORS: Array[Color] = [Color(1, 0.1, 0.05), Color(1, 0.75, 0.05), Color(0.1, 1, 0.3)]
const PED_COLORS: Array[Color] = [Color(1, 0.15, 0.05), Color(0.3, 1, 0.6)]
const LAMP_OFF := 0.12 ## Яркость выключенной лампы

static var _shared := {} # общие меши и материалы для всех перекрёстков

var grid: CityGrid
var index: int

var _approaches: Array[int] = [] # направления, с которых можно въехать
var _current := 0
var _phase := 0 # 0 зелёный, 1 жёлтый, 2 все красные, 3 пешеходам зелёный, 4 пешеходы доходят
var _served := 0 # сколько въездов получили зелёный после пешеходной фазы
var _walk_requested := false
var _timer := 0.0
var _demand := {} # направление -> есть ли машины у въезда
var _demand_timer := 0.0
var _has_lights := true
var _lamp_mm: MultiMesh
var _lamp_slots := {} # направление -> номер первой из трёх ламп
var _ped_slots: Array[int] = [] # номера пар [красный, зелёный] пешеходных ламп


func setup(city: CityGrid, idx: int, has_lights: bool) -> void:
	grid = city
	index = idx
	_has_lights = has_lights
	global_position = grid.center(index)
	for dir in 4:
		# Въезд в направлении dir существует, если есть соседний перекрёсток позади
		if grid.neighbor(index, (dir + 2) % 4) != -1:
			_approaches.append(dir)
	_current = grid.rng.randi() % maxi(_approaches.size(), 1)
	_timer = grid.rng.randf_range(0.0, MIN_GREEN)
	_demand_timer = grid.rng.randf_range(0.0, 0.3)
	if not _has_lights or _approaches.is_empty():
		return
	_build_lights()
	_update_lamps()


## Есть ли светофор (иначе пешеходы переходят, когда рядом нет машин).
func has_lights() -> bool:
	return _has_lights and not _approaches.is_empty()


## Человек ждёт у зебры («нажал кнопку»).
func request_walk() -> void:
	_walk_requested = true


## Горит ли пешеходам зелёный и сколько секунд ему осталось (0 — красный).
func walk_time_left() -> float:
	if not has_lights():
		return 0.0
	return WALK_TIME - _timer if _phase == 3 else 0.0


## Середина зебры через дорогу, уходящую от перекрёстка в направлении dir.
func crosswalk_center(dir: int) -> Vector3:
	return grid.center(index) + CityGrid.DIRS[dir] * crosswalk_distance(dir)


## Расстояние от центра перекрёстка до середины зебры на дороге dir.
func crosswalk_distance(dir: int) -> float:
	return grid.crossing_half(index, dir) + ZEBRA_FROM + ZEBRA_WIDTH * 0.5


func light_for(dir: int) -> Light:
	if not _has_lights:
		return Light.GREEN
	if _approaches.is_empty() or _approaches[_current] != dir:
		return Light.RED
	match _phase:
		0: return Light.GREEN
		1: return Light.YELLOW
		_: return Light.RED


# --- Переключение -------------------------------------------------------------

func _process(delta: float) -> void:
	if not has_lights():
		return
	_timer += delta
	_demand_timer -= delta
	if _demand_timer <= 0.0:
		_demand_timer = 0.3
		_update_demand()
	match _phase:
		0:
			var others_wait := _someone_else_waits()
			var empty: bool = not _demand.get(_approaches[_current], false)
			if others_wait and (_timer >= GREEN_TIME or (_timer >= MIN_GREEN and empty)):
				_set_phase(1)
		1:
			if _timer >= YELLOW_TIME:
				_set_phase(2)
		2:
			if _timer >= ALL_RED_TIME:
				_served += 1
				_choose_next()
		3:
			if _timer >= WALK_TIME:
				_set_phase(4)
		4:
			_blink_walk()
			if _timer >= WALK_CLEAR_TIME:
				_choose_next()


## После красного для всех: пешеходы (если ждут и пора) или следующий въезд с машинами.
func _choose_next() -> void:
	var cars_wait := false
	for dir in _approaches:
		if _demand.get(dir, false):
			cars_wait = true
	if _phase != 4 and _walk_requested and (_served >= PED_EVERY or not cars_wait):
		_served = 0
		_walk_requested = false
		_set_phase(3)
		return
	for step in range(1, _approaches.size() + 1):
		var k := (_current + step) % _approaches.size()
		if _demand.get(_approaches[k], false):
			_current = k
			_set_phase(0)
			return
	# Никто не едет — зелёный остаётся следующему по кругу
	_current = (_current + 1) % _approaches.size()
	_set_phase(0)


func _set_phase(phase: int) -> void:
	_phase = phase
	_timer = 0.0
	_update_lamps()


func _someone_else_waits() -> bool:
	if _walk_requested:
		return true
	for dir in _approaches:
		if dir != _approaches[_current] and _demand.get(dir, false):
			return true
	return false


## Какие въезды «нажали кнопку»: к ним подъезжают машины.
func _update_demand() -> void:
	_demand.clear()
	for car in grid.cars:
		var dir := car.approaching(index, DEMAND_RANGE)
		if dir >= 0:
			_demand[dir] = true


# --- Внешний вид --------------------------------------------------------------

func _build_lights() -> void:
	var poles: Array[Transform3D] = []
	var boxes: Array[Transform3D] = []
	var lamps: Array[Transform3D] = []
	for dir in _approaches:
		var h := CityGrid.DIRS[dir]
		var own_half := grid.road_width(index, dir) * 0.5
		var cross_half := grid.crossing_half(index, dir)
		# Столб на правом углу перед перекрёстком
		var base := -h * (cross_half + 0.8) + CityGrid.right_of(h) * (own_half + 0.8)
		poles.append(Transform3D(Basis(), base + Vector3.UP * 1.8))
		var face := Basis.looking_at(-h, Vector3.UP)
		boxes.append(Transform3D(face.scaled(Vector3(0.4, 1.1, 0.3)), base + Vector3.UP * 3.9))
		_lamp_slots[dir] = lamps.size()
		for k in 3:
			# Лампы смотрят навстречу машинам
			lamps.append(Transform3D(Basis(), base + Vector3.UP * (4.25 - k * 0.35) - h * 0.17))
		# Пешеходный светофор на том же столбе: смотрит через дорогу
		var across := -CityGrid.right_of(h)
		boxes.append(Transform3D(Basis.looking_at(across, Vector3.UP).scaled(Vector3(0.3, 0.6, 0.3)),
				base + Vector3.UP * 2.4))
		_ped_slots.append(lamps.size())
		for k in 2:
			lamps.append(Transform3D(Basis.from_scale(Vector3(0.8, 0.8, 0.8)),
					base + Vector3.UP * (2.55 - k * 0.3) + across * 0.12))
	_add_multimesh("Poles", _mesh("pole"), poles, false, true)
	_add_multimesh("Housings", _mesh("box"), boxes, false, true)
	_lamp_mm = _add_multimesh("Lamps", _mesh("lamp"), lamps, true, false)


func _add_multimesh(node_name: String, mesh: Mesh, xforms: Array[Transform3D], colored: bool, shadow: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colored
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = VISIBLE_RANGE
	add_child(node)
	return mm


## Общие меши: столб, корпус (куб 1×1×1, размер задаётся масштабом), лампа.
static func _mesh(kind: String) -> Mesh:
	if _shared.has(kind):
		return _shared[kind]
	var mesh: Mesh
	match kind:
		"pole":
			var c := CylinderMesh.new()
			c.top_radius = 0.08
			c.bottom_radius = 0.1
			c.height = 3.6
			c.radial_segments = 8
			c.material = _plain(Color(0.15, 0.15, 0.15))
			mesh = c
		"box":
			var b := BoxMesh.new()
			b.material = _plain(Color(0.1, 0.1, 0.1))
			mesh = b
		_:
			var s := SphereMesh.new()
			s.radius = 0.13
			s.height = 0.26
			s.radial_segments = 10
			s.rings = 6
			# Цвет лампы — из цвета экземпляра; светится сама, без освещения
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.vertex_color_use_as_albedo = true
			s.material = m
			mesh = s
	_shared[kind] = mesh
	return mesh


func _update_lamps() -> void:
	if _lamp_mm == null:
		return
	for dir in _lamp_slots:
		var state := light_for(dir)
		var first: int = _lamp_slots[dir]
		for k in 3:
			var on := (k == 0 and state == Light.RED) or (k == 1 and state == Light.YELLOW) \
					or (k == 2 and state == Light.GREEN)
			_lamp_mm.set_instance_color(first + k, _lamp_color(LAMP_COLORS[k], on))
	var walk := _phase == 3 or _phase == 4
	for first in _ped_slots:
		_lamp_mm.set_instance_color(first, _lamp_color(PED_COLORS[0], not walk))
		_lamp_mm.set_instance_color(first + 1, _lamp_color(PED_COLORS[1], walk))


## Последние секунды пешеходной фазы: зелёный человечек мигает.
func _blink_walk() -> void:
	if _lamp_mm == null:
		return
	var on := fmod(_timer, 0.5) < 0.25
	for first in _ped_slots:
		_lamp_mm.set_instance_color(first + 1, _lamp_color(PED_COLORS[1], on))


static func _lamp_color(color: Color, on: bool) -> Color:
	# Горящая лампа ярче 1 — так её подхватывает свечение (glow), если оно включено
	return color * 2.0 if on else color * LAMP_OFF + Color(0.03, 0.03, 0.03)


static func _plain(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.7
	return m
