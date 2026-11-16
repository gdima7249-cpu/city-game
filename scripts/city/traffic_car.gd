class_name TrafficCar
extends AnimatableBody3D
## Машина городского трафика. Едет по своей полосе, слушается светофоров,
## держит дистанцию до машины впереди и тормозит перед людьми, игроком и его машиной.
##
## Что ещё умеет:
## - останавливается перед пешеходной зеброй, а не на ней;
## - если дорогу долго загораживает что-то стоящее (машина игрока, сбитый человек),
##   сигналит, а потом медленно объезжает его по соседней полосе, когда там свободно;
## - если в неё врезалась машина игрока — её встряхивает, она останавливается и сигналит.

const LENGTH := 4.4
const HALF_WIDTH := 0.95
const ACCEL := 3.5
const DECEL := 7.0
## Насколько раньше точки поворота останавливаться на красный (чтобы не стоять на зебре)
const STOP_BACK := TrafficIntersection.STOP_LINE + 0.4 - (3.0 - LENGTH * 0.5)
const AVOID_SPEED := 4.5   ## Скорость при объезде
const BLOCKED_HONK := 1.2  ## Через сколько секунд стояния перед игроком сигналить
const BLOCKED_AVOID := 3.0 ## Через сколько секунд начинать объезд
const HIDE_DISTANCE := 220.0 ## Дальше этого от камеры машину не рисуем

static var _honk_short: AudioStreamWAV
static var _honk_long: AudioStreamWAV
static var _cache_frame := -1
static var _cache := {} # группа -> список узлов на этот кадр (чтобы не собирать их сотни раз)

var grid: CityGrid
var max_speed := 11.0
var speed := 0.0
var heading := Vector3.FORWARD

var _from := 0       # перекрёсток, откуда едем
var _dir := 0        # направление полосы
var _lane := 0       # номер полосы (0 — ближняя к оси дороги)
var _to := 0         # перекрёсток, куда едем
var _path := PackedVector3Array()
var _target := 0
var _turning := false
var _committed := false # уже решили проехать перекрёсток
var _ray: RayCast3D

var _base := Vector3.ZERO     # точка на линии полосы (без сдвига на объезд)
var _offset := 0.0            # сдвиг вбок от полосы: минус — влево
var _offset_target := 0.0
var _avoiding: Node3D = null  # что объезжаем
var _blocker: Node3D = null   # что стоит впереди и мешает
var _blocker_gap := INF
var _blocked_time := 0.0
var _scan_phase := 0
var _leader: TrafficCar = null
var _honk_cooldown := 0.0
var _shaken := 0.0            # стоим после удара
var _hit_cooldown := 0.0
var _bump := Vector3.ZERO     # встряска после удара (смещение корпуса)
var _bump_vel := Vector3.ZERO
var _yaw_wobble := 0.0
var _yaw_wobble_vel := 0.0
var _horn: AudioStreamPlayer3D
var _model: Node3D # всё, что рисуется
var model_path := "" # файл модели (чтобы игрок мог сесть в такую же машину)
var _wheels := []  # колёса модели (VehicleModels.find_wheels)
var _wheel_spin := 0.0
var honks := 0 # сколько раз сигналила (для проверок)


func setup(city: CityGrid, from_index: int, dir: int, lane: int, pos: Vector3, color: Color, top_speed: float) -> void:
	grid = city
	max_speed = top_speed
	collision_layer = 4  # слой 3: машины трафика
	collision_mask = 0
	sync_to_physics = false # положение задаёт код, физика только следует за ним
	add_to_group("traffic")
	_build_body(color)
	_enter_lane(from_index, dir, lane)
	heading = CityGrid.DIRS[dir]
	_base = pos
	global_position = pos
	look_at(pos + heading, Vector3.UP)
	_scan_phase = randi() % 3
	_horn = AudioStreamPlayer3D.new()
	_horn.unit_size = 12.0
	_horn.max_distance = 120.0
	_horn.pitch_scale = randf_range(0.85, 1.2)
	add_child(_horn)


func _enter_lane(from_index: int, dir: int, lane: int) -> void:
	_from = from_index
	_dir = dir
	_lane = lane
	_to = grid.neighbor(from_index, dir)
	_path = PackedVector3Array([grid.exit_point(_from, _dir, _lane), grid.stop_point(_to, _dir, _lane)])
	_target = 1
	_turning = false
	_committed = false


## Сигналит (длинно — если очень недоволен).
func honk(long := false) -> void:
	if _honk_cooldown > 0.0 or _horn == null:
		return
	_honk_cooldown = 2.5 if long else 1.8
	honks += 1
	_horn.stream = _long_honk() if long else _short_honk()
	_horn.play()


## Узлы группы на этот кадр физики (общий список для всех машин и людей).
static func group_nodes(tree: SceneTree, group: String) -> Array[Node]:
	var frame := Engine.get_physics_frames()
	if frame != _cache_frame:
		_cache_frame = frame
		_cache.clear()
	if not _cache.has(group):
		_cache[group] = tree.get_nodes_in_group(group)
	return _cache[group]


## Подъезжает ли машина к перекрёстку index (ближе range к стоп-линии):
## направление въезда или -1.
func approaching(index: int, range_m: float) -> int:
	if _turning or _to != index:
		return -1
	return _dir if _base.distance_to(_path[_path.size() - 1]) < range_m else -1


## Стоит ли машина сейчас (для пешеходов, которые решают, можно ли идти).
func is_stopped() -> bool:
	return speed < 0.5


func _physics_process(delta: float) -> void:
	_update_lod()
	# Далеко от камеры считаем через кадр с двойным шагом времени — так дешевле
	if _sim_far and (Engine.get_physics_frames() + get_instance_id()) % 2 == 1:
		_skipped += delta
		return
	delta += _skipped
	_skipped = 0.0
	_honk_cooldown = maxf(_honk_cooldown - delta, 0.0)
	_spin_wheels(delta)
	_hit_cooldown = maxf(_hit_cooldown - delta, 0.0)
	_check_player_hit()

	var desired := max_speed

	# Светофор: решаем, ехать или останавливаться перед зеброй.
	# Решение «проезжаем» принимаем только вблизи, чтобы не проскочить
	# красный, который загорится, пока мы ещё далеко.
	if not _turning and not _committed:
		var stop := _path[_path.size() - 1]
		var dist := _base.distance_to(stop) - STOP_BACK
		var light := grid.intersections[_to].light_for(_dir)
		var braking := speed * speed / (2.0 * DECEL)
		if light == TrafficIntersection.Light.GREEN:
			if dist < braking + 6.0:
				_committed = true
		elif light == TrafficIntersection.Light.YELLOW and braking > dist - 0.5:
			_committed = true
		if not _committed and light != TrafficIntersection.Light.GREEN:
			desired = minf(desired, sqrt(2.0 * DECEL * maxf(dist - 0.2, 0.0)))

	# Машина впереди (кого считать «передним», решаем раз в три кадра)
	if _scan_phase == 1 or (_leader != null and not is_instance_valid(_leader)):
		_leader = _find_leader()
	var gap := _leader_gap(_leader)
	if gap < INF:
		desired = minf(desired, sqrt(2.0 * DECEL * maxf(gap - LENGTH - 2.5, 0.0)))

	# Люди, игрок, его машина (сканируем не каждый кадр — так дешевле)
	_scan_phase = (_scan_phase + 1) % 3
	if _scan_phase == 0:
		_scan_obstacles()
	if _blocker != null and is_instance_valid(_blocker) and _blocker_gap < INF:
		desired = minf(desired, sqrt(2.0 * DECEL * maxf(_blocker_gap - 1.5, 0.0)))

	# Предметы на дороге (ящики и т. п.)
	if _ray.is_colliding() and _avoiding == null:
		var hit := global_position.distance_to(_ray.get_collision_point()) - LENGTH * 0.5
		desired = minf(desired, sqrt(2.0 * DECEL * maxf(hit - 1.5, 0.0)))

	if _avoiding != null or absf(_offset) > 0.3:
		desired = minf(desired, AVOID_SPEED)
		if absf(_offset - _offset_target) > 0.3:
			desired = minf(desired, 2.0) # пока перестраиваемся — ползком
	if _shaken > 0.0:
		_shaken -= delta
		desired = 0.0

	_update_blocked(delta, desired)

	var rate: float = ACCEL if desired > speed else DECEL * 1.5
	speed = move_toward(speed, desired, rate * delta)
	_advance(speed * delta)
	_update_offset(delta)
	_apply_transform(delta)


func _advance(distance: float) -> void:
	var pos := _base
	while distance > 0.0:
		var target := _path[_target]
		var left := pos.distance_to(target)
		if left > distance:
			pos += (target - pos) / left * distance
			distance = 0.0
			break
		pos = target
		distance -= left
		if _target < _path.size() - 1:
			_target += 1
			continue
		# Дошли до конца отрезка пути
		if _turning:
			_enter_lane(_to, _dir, _lane)
		elif _committed:
			_start_turn()
		else:
			distance = 0.0 # ждём зелёный у стоп-линии
			speed = 0.0
	var move := pos - _base
	if move.length() > 0.001:
		var blended := heading.lerp(move.normalized(), 0.35)
		if blended.length() > 0.01:
			heading = blended.normalized()
	_base = pos


## Ставит корпус: точка полосы + сдвиг на объезд + встряска от удара.
func _apply_transform(delta: float) -> void:
	# Пружина встряски
	_bump_vel += (-_bump * 30.0 - _bump_vel * 6.0) * delta
	_bump += _bump_vel * delta
	_yaw_wobble_vel += (-_yaw_wobble * 40.0 - _yaw_wobble_vel * 5.0) * delta
	_yaw_wobble += _yaw_wobble_vel * delta
	var side := CityGrid.right_of(heading)
	var pos := _base + side * _offset + _bump
	var look := heading.rotated(Vector3.UP, _yaw_wobble)
	# При съезде вбок слегка поворачиваем нос в сторону движения
	if speed > 0.5 and absf(_offset - _offset_target) > 0.05:
		look = (look + side * signf(_offset_target - _offset) * 0.25).normalized()
	look_at_from_position(pos, pos + look, Vector3.UP)


func _start_turn() -> void:
	var exits := grid.exits_from(_to, _dir)
	var leaving := exits[grid.rng.randi() % exits.size()]
	var new_lane := grid.lane_after_turn(_to, _dir, leaving, _lane)
	_path = grid.turn_path(_to, _dir, leaving, _lane, new_lane)
	_target = 0
	_turning = true
	_dir = leaving
	_lane = new_lane
	# На перекрёстке объезд заканчиваем
	_avoiding = null
	_offset_target = 0.0


## Ближайшая попутная машина впереди в своей полосе.
func _find_leader() -> TrafficCar:
	var best := INF
	var leader: TrafficCar = null
	for other in grid.cars:
		if other == self:
			continue
		var gap := _leader_gap(other, 30.0)
		if gap < best:
			best = gap
			leader = other
	return leader


## Расстояние до машины other впереди (INF — она не впереди или едет не туда).
func _leader_gap(other: TrafficCar, max_ahead := 25.0) -> float:
	if other == null:
		return INF
	var offset := other.global_position - global_position
	var ahead := offset.dot(heading)
	if ahead <= 0.0 or ahead > max_ahead:
		return INF
	if (offset - heading * ahead).length() > 1.8:
		return INF
	if other.heading.dot(heading) < 0.3:
		return INF # встречные и поперечные машины не мешают
	return ahead


# --- Препятствия: люди, игрок, его машина -------------------------------------

## Ищет ближайшее препятствие на пути машины: смотрим вдоль её траектории
## (на повороте — по дуге), а не просто прямо по носу.
func _scan_obstacles() -> void:
	_blocker = null
	_blocker_gap = INF
	var reach := 8.0 + speed * speed / (2.0 * DECEL) + LENGTH * 0.5
	# При объезде смотрим по той линии, куда съезжаем; а рядом с носом — и по текущей
	var line := _lookahead(reach, _offset_target)
	var near_line := PackedVector3Array()
	if absf(_offset_target - _offset) > 0.3:
		near_line = _lookahead(2.5, _offset)
	var me := global_position
	var reach_sq := (reach + 4.0) * (reach + 4.0)
	var tree := get_tree()
	for group: String in ["pedestrians", "player", "vehicles"]:
		for node in group_nodes(tree, group):
			var body := node as Node3D
			if body == null or not body.is_visible_in_tree():
				continue
			var pos := body.global_position
			pos.y = 0.0
			var offset := pos - Vector3(me.x, 0.0, me.z)
			if offset.length_squared() > reach_sq:
				continue
			var radius := _obstacle_radius(body, heading)
			var width := _obstacle_radius(body, CityGrid.right_of(heading))
			if radius <= 0.0:
				continue
			var gap := _gap_along(line, pos, HALF_WIDTH + width + 0.3)
			if not near_line.is_empty():
				gap = minf(gap, _gap_along(near_line, pos, HALF_WIDTH + width + 0.1))
			# Уже под корпусом (например, человек выбежал сбоку) — тоже стоим
			if gap == INF and offset.dot(heading) > -LENGTH * 0.5 and offset.dot(heading) < LENGTH * 0.5 \
					and absf(offset.dot(CityGrid.right_of(heading))) < HALF_WIDTH + radius:
				gap = 0.0
			if gap - radius < _blocker_gap:
				_blocker_gap = maxf(gap - radius, 0.0)
				_blocker = body


## Траектория на reach метров вперёд от носа машины (на земле, со сдвигом объезда).
func _lookahead(reach: float, offset: float) -> PackedVector3Array:
	var side := CityGrid.right_of(heading) * offset
	var line := PackedVector3Array()
	var pos := _base + side
	pos.y = 0.0
	line.append(pos)
	var left := reach + LENGTH * 0.5
	var k := _target
	while left > 0.0 and k < _path.size():
		var p := _path[k] + side
		p.y = 0.0
		var d := pos.distance_to(p)
		if d > left:
			p = pos + (p - pos) / d * left
			d = left
		line.append(p)
		left -= d
		pos = p
		k += 1
	if left > 0.0:
		var dir := heading
		if line.size() >= 2:
			dir = (line[line.size() - 1] - line[line.size() - 2]).normalized()
		line.append(pos + dir * left)
	return line


## Расстояние вдоль линии до точки, если точка ближе width к линии; иначе INF.
## Отсчёт — от носа машины.
func _gap_along(line: PackedVector3Array, point: Vector3, width: float) -> float:
	var travelled := 0.0
	for k in range(line.size() - 1):
		var a := line[k]
		var b := line[k + 1]
		var seg := b - a
		var length := seg.length()
		if length < 0.001:
			continue
		var t := clampf((point - a).dot(seg) / (length * length), 0.0, 1.0)
		var closest := a + seg * t
		if closest.distance_to(point) < width:
			var along := travelled + length * t - LENGTH * 0.5
			return maxf(along, 0.0)
		travelled += length
	return INF


## Насколько «широко» препятствие вдоль направления axis (0 — не мешает).
## Людей считаем кругами, машину игрока — прямоугольником.
func _obstacle_radius(body: Node3D, axis := Vector3.ZERO) -> float:
	if body is Pedestrian:
		return (body as Pedestrian).obstacle_radius()
	if body is RigidBody3D:
		var half := Pedestrian._car_half(body)
		if axis == Vector3.ZERO:
			return maxf(half.x, half.z)
		var b := body.global_transform.basis
		return absf(b.x.dot(axis)) * half.x + absf(b.z.dot(axis)) * half.z
	return 0.45  # игрок пешком


## Считает, сколько стоим перед препятствием, сигналит и решает объезжать.
func _update_blocked(delta: float, desired: float) -> void:
	var blocked_by_obstacle := _blocker != null and is_instance_valid(_blocker) \
			and desired < 0.6 and _blocker_gap < 4.0
	if not blocked_by_obstacle:
		_blocked_time = 0.0
		if _avoiding != null and (not is_instance_valid(_avoiding) or _passed(_avoiding)):
			_avoiding = null
			_offset_target = 0.0
		return
	_blocked_time += delta
	var is_player := _blocker.is_in_group("player") or _blocker.is_in_group("vehicles")
	if _blocker is Pedestrian and (_blocker as Pedestrian).is_down():
		is_player = false
	if is_player and _blocked_time > BLOCKED_HONK:
		honk(_blocked_time > 5.0)
	if _blocked_time > BLOCKED_AVOID and not _turning and _avoiding == null and _is_static(_blocker):
		_try_start_avoid(_blocker)


## Препятствие стоит на месте (объезжаем только такие).
func _is_static(body: Node3D) -> bool:
	if body is Pedestrian:
		var p := body as Pedestrian
		return p.is_down() or p.is_idle_on_road()
	if body is RigidBody3D:
		return (body as RigidBody3D).linear_velocity.length() < 1.0
	if body is CharacterBody3D:
		return (body as CharacterBody3D).velocity.length() < 0.5
	return false


func _passed(body: Node3D) -> bool:
	var offset := body.global_position - global_position
	return offset.dot(heading) < -LENGTH * 0.5 - _obstacle_radius(body, heading) - 1.0


## Сдвигаемся влево настолько, чтобы пройти мимо, если там не едет встречная машина.
func _try_start_avoid(body: Node3D) -> void:
	var side := CityGrid.right_of(heading)
	var lateral := (body.global_position - _base).dot(side)
	var radius := _obstacle_radius(body, side)
	var needed := lateral - radius - HALF_WIDTH - 0.6
	# Если препятствие у самого левого края — объезжаем справа
	if needed < -7.0:
		needed = lateral + radius + HALF_WIDTH + 0.6
	if absf(needed) > 7.5:
		return
	for other in grid.cars:
		if other == self:
			continue
		var offset := other.global_position - _base
		var ahead := offset.dot(heading)
		var lat := offset.dot(side)
		if ahead > -6.0 and ahead < 35.0 and absf(lat - needed) < 2.6:
			return # там кто-то едет — подождём
	_avoiding = body
	_offset_target = needed


func _update_offset(delta: float) -> void:
	if is_equal_approx(_offset, _offset_target):
		return
	var rate := clampf(speed * 0.5, 0.8, 1.8)
	_offset = move_toward(_offset, _offset_target, rate * delta)


# --- Удары машиной игрока -----------------------------------------------------

func _check_player_hit() -> void:
	if _hit_cooldown > 0.0:
		return
	for node in group_nodes(get_tree(), "vehicles"):
		var car := node as RigidBody3D
		if car == null:
			continue
		var offset := car.global_position - global_position
		if offset.length_squared() > 49.0:
			continue
		var relative := car.linear_velocity - heading * speed
		if relative.length() < 2.5:
			continue
		if not _boxes_touch(car):
			continue
		_on_rammed(car, relative)
		return


## Грубая проверка касания корпусов (по углам прямоугольников сверху).
func _boxes_touch(car: Node3D) -> bool:
	var mine := global_transform
	var theirs := car.global_transform
	var my_half := Vector2(HALF_WIDTH + 0.15, LENGTH * 0.5 + 0.15)
	var their_half := Vector2(1.0, 2.2)
	for sx: float in [-1.0, 0.0, 1.0]:
		for sz: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var corner := theirs * Vector3(sx * their_half.x, 0.6, sz * their_half.y)
			var local := mine.affine_inverse() * corner
			if absf(local.x) < my_half.x and absf(local.z) < my_half.y:
				return true
			var mine_corner := mine * Vector3(sx * my_half.x, 0.6, sz * my_half.y)
			var their_local := theirs.affine_inverse() * mine_corner
			if absf(their_local.x) < their_half.x and absf(their_local.z) < their_half.y:
				return true
	return false


func _on_rammed(car: RigidBody3D, relative: Vector3) -> void:
	_hit_cooldown = 1.5
	_shaken = randf_range(3.0, 5.0)
	var push := relative
	push.y = 0.0
	push = push.limit_length(6.0)
	_bump_vel += push * 0.8
	_yaw_wobble_vel += signf(push.dot(CityGrid.right_of(heading))) * push.length() * 0.12
	speed *= 0.3
	_honk_cooldown = 0.0
	honk(true)


## Колёса крутятся со скоростью машины (только когда машину видно).
func _spin_wheels(delta: float) -> void:
	if _wheels.is_empty() or not _model.visible or speed < 0.05:
		return
	_wheel_spin = fmod(_wheel_spin + speed / VehicleModels.WHEEL_RADIUS * delta, TAU)
	var spin := Basis(Vector3.RIGHT, _wheel_spin)
	for w: Array in _wheels:
		(w[0] as Node3D).basis = spin * (w[3] as Basis)


## Дальше этого от камеры жители и машины считаются через кадр
const SIM_FAR_DISTANCE := 90.0
var _sim_far := false
var _skipped := 0.0


## Далеко от камеры корпус не рисуем (машина продолжает ездить).
func _update_lod() -> void:
	if (Engine.get_physics_frames() + get_instance_id()) % 30 != 0:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var far := camera.global_position.distance_squared_to(global_position) > HIDE_DISTANCE * HIDE_DISTANCE
	_sim_far = camera.global_position.distance_squared_to(global_position) > SIM_FAR_DISTANCE * SIM_FAR_DISTANCE
	if _model != null and _model.visible == far:
		_model.visible = not far


# --- Звук сигнала (собирается кодом, файлы не нужны) ------------------------

static func _short_honk() -> AudioStreamWAV:
	if _honk_short == null:
		_honk_short = _make_honk(0.35)
	return _honk_short


static func _long_honk() -> AudioStreamWAV:
	if _honk_long == null:
		_honk_long = _make_honk(1.0)
	return _honk_long


## Двухтональный автомобильный сигнал (около 400 и 500 Гц).
static func _make_honk(seconds: float) -> AudioStreamWAV:
	var rate := 22050
	var count := int(seconds * rate)
	var data := PackedByteArray()
	data.resize(count * 2)
	for k in count:
		var t := float(k) / rate
		var env := minf(t / 0.02, 1.0) * minf((seconds - t) / 0.05, 1.0)
		var v := 0.0
		for f: float in [405.0, 507.0]:
			# Сглаженный «квадрат»: основной тон и пара гармоник
			v += sin(TAU * f * t) + 0.33 * sin(TAU * f * 3.0 * t) + 0.2 * sin(TAU * f * 5.0 * t)
		var sample := int(clampf(v * 0.22 * env, -1.0, 1.0) * 32000.0)
		data.encode_s16(k * 2, sample)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


# --- Корпус -------------------------------------------------------------------

func _build_body(color: Color) -> void:
	var paint := StandardMaterial3D.new()
	paint.albedo_color = color
	paint.metallic = 0.4
	paint.roughness = 0.4
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.1, 0.13, 0.16)
	glass.roughness = 0.15
	var tire := StandardMaterial3D.new()
	tire.albedo_color = Color(0.06, 0.06, 0.06)

	_model = Node3D.new()
	_model.name = "Look"
	add_child(_model)
	# Настоящая модель, если она задана в vehicle_models.gd; иначе коробка с колёсами
	model_path = VehicleModels.random_traffic_path(randi())
	var model := VehicleModels.traffic_model(model_path)
	if model != null:
		_model.add_child(model)
		_wheels = VehicleModels.find_wheels(model)
	else:
		_add_mesh(_box(Vector3(1.8, 0.6, LENGTH)), Vector3(0, 0.65, 0), paint)
		_add_mesh(_box(Vector3(1.6, 0.55, 2.1)), Vector3(0, 1.22, 0.2), glass)
		var wheel := CylinderMesh.new()
		wheel.top_radius = 0.33
		wheel.bottom_radius = 0.33
		wheel.height = 0.25
		for x: float in [-0.85, 0.85]:
			for z: float in [-1.35, 1.35]:
				var w := _add_mesh(wheel, Vector3(x, 0.33, z), tire)
				w.rotation.z = PI * 0.5

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.8, 1.2, LENGTH)
	shape.shape = box_shape
	shape.position = Vector3(0, 0.85, 0)
	add_child(shape)

	# Луч вперёд (у машины «вперёд» — это -Z): видит ящики и прочие предметы на дороге.
	# Игрока, его машину и людей машина замечает отдельно, в _scan_obstacles.
	_ray = RayCast3D.new()
	_ray.position = Vector3(0, 0.8, -LENGTH * 0.5 - 0.1)
	_ray.target_position = Vector3(0, 0, -9.0)
	_ray.collision_mask = 1
	_ray.add_exception(self)
	add_child(_ray)


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _add_mesh(mesh: Mesh, pos: Vector3, material: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.position = pos
	m.material_override = material
	_model.add_child(m)
	return m
