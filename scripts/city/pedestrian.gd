class_name Pedestrian
extends AnimatableBody3D
## Пешеход.
##
## - Гуляет по тротуару вокруг квартала. На углах иногда переходит дорогу
##   на соседний квартал — только по зебре: на перекрёстке со светофором ждёт
##   зелёного человечка, без светофора — пока рядом не будет машин.
## - Пугается быстрой машины, которая едет на него, и убегает в сторону.
## - Если машина игрока его задела — отлетает (на скорости) или отшатывается
##   (если машина ехала медленно). Сбитый лежит, а через какое-то время,
##   когда игрок уедет, «оживает» в другом месте города.

signal knocked_down(by: Node3D)

enum State { WALK, WAIT_CROSS, CROSS, FLEE, STUMBLE, KNOCKED, DOWN }

const SPRINT_SPEED := 5.5
const CURB_Y := 0.1   ## Высота тротуара
const ROAD_Y := 0.02  ## Высота асфальта
const DANGER_SPEED := 7.0   ## Машина быстрее этого (м/с) пугает
const KNOCK_SPEED := 4.5    ## Удар быстрее этого — человек отлетает
const DOWN_TIME := 25.0     ## Сколько лежит сбитый (дальше — ждёт, пока игрок уедет)
const CROSS_CHANCE := 0.6  ## Как часто на углу переходят дорогу
const GRAVITY := 9.8
const HIDE_DISTANCE := 160.0 ## Дальше этого от камеры человека не рисуем и не анимируем

## Буквы кварталов, где ходят люди
const WALKABLE := {"D": 4, "S": 4, "R": 2, "p": 2, "P": 1, "L": 1, "I": 1}

var speed := 1.4
var state := State.WALK

var grid: CityGrid
var _cell := Vector2i(-1, -1)
var _inset_frac := 0.5    # где на ширине тротуара идёт этот человек (0..1)
var _clockwise := true
var _corner := 0          # к какому углу квартала идём (0 СЗ, 1 СВ, 2 ЮВ, 3 ЮЗ)

var _loop := PackedVector3Array() # запасной вариант, если город не найден
var _target := 0
var _route := PackedVector3Array() # точки перехода через дорогу
var _route_i := 0
var _route_new_cell := Vector2i(-1, -1)
var _route_new_corner := 0
var _crossing: TrafficIntersection
var _crossing_center := Vector3.ZERO
var _cross_time := 0.0

var _waiting := 0.0
var _state_time := 0.0
var _flee_dir := Vector3.ZERO
var _flee_time := 2.0
var _velocity := Vector3.ZERO
var _spin_axis := Vector3.RIGHT
var _spin_total := 0.0
var _flight_time := 0.0
var _flight_elapsed := 0.0
var _danger_check := 0
var _player: Node3D
var _model: Node3D
var _human: Humanoid
var _shape: CollisionShape3D
var _bob := 0.0


func setup(loop: PackedVector3Array, start_corner: int, start_fraction: float, walk_speed: float,
		shirt: Color, skin: Color) -> void:
	_loop = loop
	speed = walk_speed
	collision_layer = 8 # слой 4: пешеходы
	collision_mask = 0
	sync_to_physics = false # положение задаёт код, физика только следует за ним
	add_to_group("pedestrians")
	_build_body(shirt, skin)
	var a := _loop[start_corner]
	var b := _loop[(start_corner + 1) % _loop.size()]
	global_position = a.lerp(b, start_fraction)
	_target = (start_corner + 1) % _loop.size()
	_danger_check = randi() % 4
	grid = get_parent() as CityGrid
	if grid != null:
		_attach_to_city(a, _loop[_target])


## Привязка к кварталу: по углам петли определяем квартал, ширину «дорожки»
## и направление обхода. Дальше человек ходит уже по кварталам города.
func _attach_to_city(corner_a: Vector3, corner_b: Vector3) -> void:
	var center := Vector3.ZERO
	for p in _loop:
		center += p
	center /= _loop.size()
	_cell = _cell_at(center)
	if _cell.x < 0:
		grid = null
		return
	var r := _rect(_cell)
	var sidewalk := _sidewalk(_cell)
	var inset := absf(minf(absf(corner_a.x - r.position.x), absf(corner_a.x - r.end.x)))
	_inset_frac = clampf(inset / sidewalk, 0.15, 0.85)
	var ca := _corner_index(corner_a, r)
	var cb := _corner_index(corner_b, r)
	_clockwise = cb == (ca + 1) % 4
	_corner = cb


# --- Что видят другие (машины трафика) ---------------------------------------

## Лежит после удара.
func is_down() -> bool:
	return state == State.DOWN or state == State.KNOCKED


## Стоит на проезжей части и никуда не идёт.
func is_idle_on_road() -> bool:
	return state == State.STUMBLE and _on_road()


## Насколько широко объезжать/тормозить (0 — не мешает).
func obstacle_radius() -> float:
	if is_down():
		return 1.1
	return 0.45


## Испугаться: убежать от точки danger_pos (например, рядом кого-то сбили).
func scare(danger_pos: Vector3, along := Vector3.ZERO) -> void:
	if is_down() or state == State.STUMBLE:
		return
	var away := global_position - danger_pos
	away.y = 0.0
	if along.length() > 0.1:
		var line := along.normalized()
		away -= line * away.dot(line)
	if away.length() < 0.1:
		away = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
	_start_flee(away.normalized())


# --- Кадр --------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_update_lod()
	# Далеко от камеры считаем через кадр с двойным шагом времени — так дешевле
	if _sim_far and state != State.KNOCKED and (Engine.get_physics_frames() + get_instance_id()) % 2 == 1:
		_skipped += delta
		return
	delta += _skipped
	_skipped = 0.0
	_state_time += delta
	if state != State.KNOCKED and state != State.DOWN:
		_check_vehicles()
	match state:
		State.WALK: _do_walk(delta)
		State.WAIT_CROSS: _do_wait_cross(delta)
		State.CROSS: _do_route(delta, speed * 1.25) # по зебре идут бодрее
		State.FLEE: _do_flee(delta)
		State.STUMBLE: _do_stumble(delta)
		State.KNOCKED: _do_knocked(delta)
		State.DOWN: _do_down(delta)


func _do_walk(delta: float) -> void:
	if _waiting > 0.0:
		_waiting -= delta
		_play("Idle")
		return
	if grid == null:
		_walk_old_loop(delta)
		return
	var target := _corner_point(_cell, _corner)
	if _move_to(target, speed, delta):
		_on_corner()


## Пришли на угол квартала: идём дальше, задерживаемся или переходим дорогу.
func _on_corner() -> void:
	if randf() < CROSS_CHANCE and _plan_crossing():
		return
	_corner = _next_corner(_corner)
	if randf() < 0.15:
		_waiting = randf_range(1.0, 3.0)


func _do_wait_cross(delta: float) -> void:
	# Сначала доходим до бордюра у зебры
	if _route_i == 0:
		if _move_to(_route[0], speed, delta):
			_route_i = 1
		return
	_face(_route[1] - global_position)
	_play("Idle")
	_crossing.request_walk()
	if _may_cross():
		state = State.CROSS
		_state_time = 0.0
	elif _state_time > 70.0:
		# Надоело ждать — пойдём дальше по своему кварталу
		_resume_walk()


## Можно ли сейчас выходить на зебру.
func _may_cross() -> bool:
	if _crossing.has_lights():
		# Широкий проспект за один зелёный не перейти — выходим только в начале фазы
		var need := minf(_cross_time - TrafficIntersection.WALK_CLEAR_TIME, TrafficIntersection.WALK_TIME - 1.5)
		return _crossing.walk_time_left() > need
	# Без светофора: смотрим, нет ли рядом едущих машин
	for car in grid.cars:
		var offset := _crossing_center - car.global_position
		var dist := offset.length()
		if dist > 30.0:
			continue
		if dist < 7.0:
			return false
		if car.speed > 0.5 and offset.dot(car.heading) > 0.0 and dist < 8.0 + car.speed * 2.5:
			return false
	return true


func _do_route(delta: float, move_speed: float) -> void:
	if _route_i >= _route.size():
		_finish_route()
		return
	# На зебре не идём в бок машине, которая стоит прямо перед нами
	if _move_to(_route[_route_i], move_speed, delta):
		_route_i += 1
		if _route_i >= _route.size():
			_finish_route()


func _finish_route() -> void:
	if _route_new_cell.x >= 0:
		_cell = _route_new_cell
		_clockwise = randf() < 0.5
		_corner = _next_corner(_route_new_corner)
	_route = PackedVector3Array()
	_route_new_cell = Vector2i(-1, -1)
	state = State.WALK
	_state_time = 0.0


func _do_flee(delta: float) -> void:
	if _state_time > _flee_time:
		_resume_walk()
		return
	if not _route.is_empty():
		# Бежим по зебре к ближнему краю
		_do_route(delta, SPRINT_SPEED)
		if state != State.FLEE:
			state = State.FLEE # пусть добежит положенное время
			_flee_dir = Vector3.ZERO
		return
	if _flee_dir == Vector3.ZERO:
		_play("Idle")
		return
	var pos := global_position + _flee_dir * SPRINT_SPEED * delta
	pos = _keep_on_sidewalk(pos)
	_face(_flee_dir)
	global_position = pos
	_play("Sprint", 1.1)


func _do_stumble(_delta: float) -> void:
	if _state_time > 1.0:
		_start_flee(_flee_dir) # отшатнулись — и бегом от машины


func _do_knocked(delta: float) -> void:
	_flight_elapsed += delta
	_velocity.y -= GRAVITY * delta
	var pos := global_position + _velocity * delta
	var floor_y := _floor_y(pos)
	var landed := pos.y <= floor_y
	if landed:
		pos.y = floor_y
		if _velocity.y < -2.0:
			_velocity.y = -_velocity.y * 0.25 # небольшой отскок
			_velocity.x *= 0.6
			_velocity.z *= 0.6
		else:
			_velocity.y = 0.0
			var horizontal := Vector3(_velocity.x, 0, _velocity.z)
			horizontal = horizontal.move_toward(Vector3.ZERO, 9.0 * delta) # скольжение
			_velocity = horizontal
	global_position = pos
	# Кувырок в воздухе: к приземлению целое число оборотов
	var t := clampf(_flight_elapsed / maxf(_flight_time, 0.1), 0.0, 1.0)
	_model.transform = Transform3D(Basis(_spin_axis, _spin_total * t), Vector3.ZERO)
	if landed and _velocity.length() < 0.3 and _flight_elapsed > _flight_time:
		_model.transform = Transform3D.IDENTITY
		state = State.DOWN
		_state_time = 0.0


func _do_down(_delta: float) -> void:
	if _state_time < DOWN_TIME:
		return
	# «Оживаем» в другом месте, когда игрок далеко и не видит
	var player := _get_player()
	if player != null and player.global_position.distance_to(global_position) < 45.0:
		return
	_respawn()


# --- Машины рядом: испуг и удары ---------------------------------------------

func _check_vehicles() -> void:
	var pos := global_position
	for node in TrafficCar.group_nodes(get_tree(), "vehicles"):
		var car := node as RigidBody3D
		if car == null:
			continue
		var offset := pos - car.global_position
		if offset.length_squared() > 900.0:
			continue
		var vel := car.linear_velocity
		vel.y = 0.0
		if _inside_car(car, pos):
			_on_hit(car, vel)
			return
		_danger_check = (_danger_check + 1) % 4
		if _danger_check == 0 and state != State.FLEE and state != State.STUMBLE:
			_check_danger(offset, vel)
	# Машины трафика тормозят перед людьми, но если человек выбежал прямо
	# под колёса — тоже отлетает (проверяем только тех, кто на дороге)
	if (state == State.CROSS or state == State.FLEE) and grid != null:
		for car in grid.cars:
			if car.speed < 2.0:
				continue
			if pos.distance_squared_to(car.global_position) > 9.0:
				continue
			var local := car.global_transform.affine_inverse() * pos
			if absf(local.x) < TrafficCar.HALF_WIDTH + 0.2 and absf(local.z) < TrafficCar.LENGTH * 0.5 + 0.2:
				_on_hit(car, car.heading * car.speed)
				return


## Едет ли быстрая машина прямо на нас.
func _check_danger(offset: Vector3, vel: Vector3) -> void:
	var v2 := vel.length_squared()
	if v2 < DANGER_SPEED * DANGER_SPEED:
		return
	# Через сколько секунд машина будет ближе всего и насколько близко
	var t := offset.dot(vel) / v2
	if t < 0.0 or t > 2.2:
		return
	var miss := offset - vel * t
	miss.y = 0.0
	if miss.length() < 3.5:
		var away := miss
		if away.length() < 0.3:
			away = vel.cross(Vector3.UP) * (1.0 if randf() < 0.5 else -1.0)
		_start_flee(away.normalized())
		_scare_neighbors(global_position, vel)


func _inside_car(car: RigidBody3D, pos: Vector3) -> bool:
	var half := _car_half(car)
	var local := car.global_transform.affine_inverse() * (pos + Vector3.UP * 0.9)
	return absf(local.x) < half.x + 0.25 and absf(local.z) < half.z + 0.25 and local.y < half.y + 1.2


## Половина габаритов машины игрока (по её коллизии корпуса).
static func _car_half(car: Node3D) -> Vector3:
	if car.has_meta("ped_half"):
		return car.get_meta("ped_half")
	var half := Vector3(1.0, 0.8, 2.2)
	var body := car.get_node_or_null("BodyCollision") as CollisionShape3D
	if body != null and body.shape is BoxShape3D:
		var size := (body.shape as BoxShape3D).size
		half = Vector3(size.x * 0.5, size.y * 0.5 + body.position.y, size.z * 0.5)
	car.set_meta("ped_half", half)
	return half


func _on_hit(car: Node3D, car_vel: Vector3) -> void:
	var rel := car_vel
	rel.y = 0.0
	var hit_speed := rel.length()
	if hit_speed < 1.0:
		# Машина почти стоит и упёрлась — просто отходим
		var away := global_position - car.global_position
		away.y = 0.0
		global_position += away.normalized() * 0.05
		return
	if hit_speed < KNOCK_SPEED:
		# Толкнули: отшатнуться в сторону
		var side := (global_position - car.global_position).slide(rel.normalized())
		side.y = 0.0
		if side.length() < 0.1:
			side = rel.cross(Vector3.UP)
		global_position += side.normalized() * 0.6 + rel.normalized() * 0.3
		_flee_dir = side.normalized()
		_face(-rel)
		state = State.STUMBLE
		_state_time = 0.0
		_play("Hit_Chest", 1.0, 0.05)
		_scare_neighbors(global_position, rel)
		return
	_knock(car, rel)


## Сбили: летим, кувыркаемся, падаем.
func _knock(car: Node3D, rel: Vector3) -> void:
	var hit_speed := rel.length()
	var dir := rel / hit_speed
	var side := (global_position - car.global_position).slide(dir)
	side.y = 0.0
	_velocity = dir * hit_speed * randf_range(0.7, 0.95) + side.normalized() * randf_range(0.5, 2.0)
	_velocity.y = 1.5 + hit_speed * 0.22
	_flight_time = 2.0 * _velocity.y / GRAVITY
	_flight_elapsed = 0.0
	_face(-dir)
	_spin_axis = dir.cross(Vector3.UP).normalized()
	# Внутри модели ось поворота задаётся в её координатах
	_spin_axis = (global_transform.basis.inverse() * _spin_axis).normalized()
	_spin_total = -TAU * float(roundi(hit_speed / 14.0))
	state = State.KNOCKED
	_state_time = 0.0
	_set_solid(false)
	if _human != null:
		_human.play("Death01", 1.0, 0.05)
	else:
		_model.rotation.x = -PI * 0.5
	# Машина игрока чуть теряет скорость от удара
	if car is RigidBody3D:
		(car as RigidBody3D).apply_central_impulse(-dir * 75.0 * hit_speed * 0.4)
	_scare_neighbors(global_position, rel)
	knocked_down.emit(car)


func _scare_neighbors(where: Vector3, along: Vector3) -> void:
	for node in get_tree().get_nodes_in_group("pedestrians"):
		var p := node as Pedestrian
		if p == null or p == self:
			continue
		if p.global_position.distance_squared_to(where) < 196.0:
			p.scare(where, along)


func _start_flee(direction: Vector3) -> void:
	if state == State.KNOCKED or state == State.DOWN:
		return
	state = State.FLEE
	_state_time = 0.0
	_flee_time = randf_range(1.6, 2.8)
	_waiting = 0.0
	if not _route.is_empty() and _route_i >= 1 and _on_road():
		# На дороге бежим к ближнему краю зебры
		var back := PackedVector3Array([_route[1], _route[0]])
		var ahead := _route.slice(_route_i)
		var to_back := global_position.distance_to(_route[0])
		var to_ahead := global_position.distance_to(_route[3])
		if to_back < to_ahead:
			_route = back
			_route_new_cell = Vector2i(-1, -1)
		else:
			_route = ahead
		_route_i = 0
		return
	_route = PackedVector3Array()
	_route_new_cell = Vector2i(-1, -1)
	_flee_dir = direction


## Вернуться к обычной прогулке по своему кварталу.
func _resume_walk() -> void:
	state = State.WALK
	_state_time = 0.0
	_route = PackedVector3Array()
	_route_new_cell = Vector2i(-1, -1)
	if grid == null:
		return
	var cell := _cell_at(global_position)
	if cell.x >= 0:
		_cell = cell
	# Идём к концу ближайшей стороны квартала
	var best := INF
	for k in 4:
		var a := _corner_point(_cell, k)
		var b := _corner_point(_cell, (k + 1) % 4)
		var d := global_position.distance_to(Geometry3D.get_closest_point_to_segment(global_position, a, b))
		if d < best:
			best = d
			_corner = (k + 1) % 4 if _clockwise else k


func _respawn() -> void:
	var player := _get_player()
	for attempt in 30:
		var cell := Vector2i(randi() % grid.land_columns, randi() % grid.nz)
		if not WALKABLE.has(grid.cell_type(cell.x, cell.y)):
			continue
		var corner := randi() % 4
		var pos := _corner_point(cell, corner).lerp(_corner_point(cell, (corner + 1) % 4), randf())
		if player != null and player.global_position.distance_to(pos) < 60.0:
			continue
		_cell = cell
		_clockwise = randf() < 0.5
		_corner = (corner + 1) % 4 if _clockwise else corner
		global_position = pos
		_model.transform = Transform3D.IDENTITY
		_set_solid(true)
		state = State.WALK
		_state_time = 0.0
		_play("Walk")
		return


# --- Переход через дорогу ----------------------------------------------------

## Выбирает, через какую дорогу перейти с этого угла, и строит путь по зебре.
func _plan_crossing() -> bool:
	# Для каждого угла: [смещение перекрёстка, [сторона, ветка перекрёстка, сосед, угол у соседа] x2]
	var options: Array = []
	match _corner:
		0: options = [[Vector2i(0, 0), 1, Vector2i(0, -1), 3], [Vector2i(0, 0), 2, Vector2i(-1, 0), 1]]
		1: options = [[Vector2i(1, 0), 3, Vector2i(0, -1), 2], [Vector2i(1, 0), 2, Vector2i(1, 0), 0]]
		2: options = [[Vector2i(1, 1), 3, Vector2i(0, 1), 1], [Vector2i(1, 1), 0, Vector2i(1, 0), 3]]
		_: options = [[Vector2i(0, 1), 1, Vector2i(0, 1), 0], [Vector2i(0, 1), 0, Vector2i(-1, 0), 2]]
	options.shuffle()
	for opt: Array in options:
		var corner_ij: Vector2i = _cell + (opt[0] as Vector2i)
		var arm: int = opt[1]
		var other: Vector2i = _cell + (opt[2] as Vector2i)
		var index := grid.index_of(corner_ij.x, corner_ij.y)
		if index < 0 or grid.neighbor(index, arm) == -1:
			continue
		if other.x < 0 or other.x >= grid.land_columns or not WALKABLE.has(grid.cell_type(other.x, other.y)):
			continue
		var node := grid.intersections[index]
		if node == null or not node.has_lights():
			continue # переходим только по зебрам, а они есть у светофоров
		var across: Vector3 = Vector3(other.x - _cell.x, 0, other.y - _cell.y)
		var along := CityGrid.DIRS[arm]
		var half := grid.road_width(index, arm) * 0.5
		var mid := node.crosswalk_center(arm) + along * randf_range(-1.1, 1.1)
		mid.y = 0.0
		_route = PackedVector3Array([
			mid - across * (half + 0.6) + Vector3.UP * CURB_Y,
			mid - across * (half - 0.2) + Vector3.UP * ROAD_Y,
			mid + across * (half - 0.2) + Vector3.UP * ROAD_Y,
			mid + across * (half + 0.6) + Vector3.UP * CURB_Y,
		])
		_route_i = 0
		_route_new_cell = other
		_route_new_corner = opt[3]
		_crossing = node
		_crossing_center = mid
		_cross_time = (half * 2.0 + 1.0) / (speed * 1.25) + 0.5
		state = State.WAIT_CROSS
		_state_time = 0.0
		return true
	return false


func _on_road() -> bool:
	return grid != null and _cell_at(global_position).x < 0


# --- Геометрия кварталов ------------------------------------------------------

func _rect(cell: Vector2i) -> Rect2:
	var r := grid.cell_rect(cell.x, cell.y)
	r.position += Vector2(grid.global_position.x, grid.global_position.z)
	return r


func _sidewalk(cell: Vector2i) -> float:
	return CityLayout.SIDEWALK.get(grid.cell_type(cell.x, cell.y), 3.0)


## Квартал под точкой (без дорог); (-1, -1) — точка на дороге или вне города.
func _cell_at(pos: Vector3) -> Vector2i:
	var local := pos - grid.global_position
	for i in grid.land_columns:
		for j in grid.nz:
			if grid.cell_rect(i, j).has_point(Vector2(local.x, local.z)):
				return Vector2i(i, j) if WALKABLE.has(grid.cell_type(i, j)) else Vector2i(-1, -1)
	return Vector2i(-1, -1)


func _corner_index(p: Vector3, r: Rect2) -> int:
	var east := p.x > r.get_center().x
	var south := p.z > r.get_center().y
	if south:
		return 2 if east else 3
	return 1 if east else 0


func _corner_point(cell: Vector2i, corner: int) -> Vector3:
	var r := _rect(cell)
	var inset := _sidewalk(cell) * _inset_frac
	var x := r.end.x - inset if corner == 1 or corner == 2 else r.position.x + inset
	var z := r.end.y - inset if corner >= 2 else r.position.y + inset
	return Vector3(x, CURB_Y, z)


func _next_corner(corner: int) -> int:
	return (corner + 1) % 4 if _clockwise else (corner + 3) % 4


## Не даём убегающему зайти в дома и выбежать на дорогу.
func _keep_on_sidewalk(pos: Vector3) -> Vector3:
	if grid == null or _cell.x < 0:
		return pos
	var r := _rect(_cell)
	var sidewalk := _sidewalk(_cell)
	pos.x = clampf(pos.x, r.position.x + 0.3, r.end.x - 0.3)
	pos.z = clampf(pos.z, r.position.y + 0.3, r.end.y - 0.3)
	var inner := r.grow(-sidewalk + 0.3)
	if inner.has_point(Vector2(pos.x, pos.z)):
		# Ближайший край внутренней части — обратно на тротуар
		var dl := pos.x - inner.position.x
		var dr := inner.end.x - pos.x
		var dt := pos.z - inner.position.y
		var db := inner.end.y - pos.z
		var m := minf(minf(dl, dr), minf(dt, db))
		if m == dl: pos.x = inner.position.x
		elif m == dr: pos.x = inner.end.x
		elif m == dt: pos.z = inner.position.y
		else: pos.z = inner.end.y
	pos.y = CURB_Y
	return pos


func _floor_y(pos: Vector3) -> float:
	if grid == null:
		return CURB_Y
	return CURB_Y if _cell_at(pos).x >= 0 else ROAD_Y


# --- Движение и анимация ------------------------------------------------------

## Шаг к точке. Возвращает true, когда дошли.
func _move_to(target: Vector3, move_speed: float, delta: float) -> bool:
	var pos := global_position
	var to_target := target - pos
	var distance := to_target.length()
	if distance < 0.05:
		return true
	var dir := to_target / distance
	if _player_in_way(dir):
		_play("Idle")
		return false
	var step := minf(move_speed * delta, distance)
	pos += dir * step
	_face(dir)
	global_position = pos
	if move_speed > 3.0:
		_play("Sprint", move_speed / SPRINT_SPEED)
	else:
		_play("Walk", move_speed / 1.3)
	if _human == null:
		_bob += step * 6.0
		_model.position.y = absf(sin(_bob)) * 0.05
	return step >= distance


func _face(dir: Vector3) -> void:
	dir.y = 0.0
	if dir.length() < 0.01:
		return
	var pos := global_position
	look_at_from_position(pos, pos + dir.normalized(), Vector3.UP)


func _player_in_way(dir: Vector3) -> bool:
	var player := _get_player()
	if player == null or not player.visible:
		return false
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	return to_player.length() < 1.6 and to_player.dot(dir) > 0.3


func _get_player() -> Node3D:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
	return _player


## Дальше этого от камеры жители и машины считаются через кадр
const SIM_FAR_DISTANCE := 90.0
var _sim_far := false
var _skipped := 0.0


## Далеко от камеры: не рисуем и не считаем анимацию (сам человек продолжает ходить).
func _update_lod() -> void:
	if (Engine.get_physics_frames() + get_instance_id()) % 30 != 0:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var near := camera.global_position.distance_squared_to(global_position) < HIDE_DISTANCE * HIDE_DISTANCE
	_sim_far = camera.global_position.distance_squared_to(global_position) > SIM_FAR_DISTANCE * SIM_FAR_DISTANCE
	if _model.visible != near:
		_model.visible = near
		if _human != null:
			_human.anim.active = near


func _set_solid(on: bool) -> void:
	if _shape != null:
		_shape.set_deferred("disabled", not on)


func _play(anim_name: String, anim_speed := -1.0, blend := 0.2) -> void:
	if _human == null:
		return
	if anim_speed < 0.0:
		anim_speed = 1.0 if anim_name == "Idle" else speed / 1.3
	_human.play(anim_name, anim_speed, blend)


## Старое поведение (если пешеход создан не городом): просто по петле.
func _walk_old_loop(delta: float) -> void:
	if _move_to(_loop[_target], speed, delta):
		_target = (_target + 1) % _loop.size()
		if randf() < 0.25:
			_waiting = randf_range(1.0, 4.0)


# --- Тело ---------------------------------------------------------------------

func _build_body(shirt: Color, skin: Color) -> void:
	_model = Node3D.new()
	add_child(_model)
	_add_collision()
	# Настоящая модель человека; если файлов нет — простые фигуры ниже.
	_human = Humanoid.create(randi())
	if _human != null:
		_model.add_child(_human)
		_play("Walk")
		_human.anim.advance(randf()) # чтобы все не шагали в ногу
		return
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = shirt
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = skin
	var pants_mat := StandardMaterial3D.new()
	pants_mat.albedo_color = Color(0.2, 0.22, 0.3)

	var legs := MeshInstance3D.new()
	var legs_mesh := CapsuleMesh.new()
	legs_mesh.radius = 0.17
	legs_mesh.height = 0.9
	legs.mesh = legs_mesh
	legs.position.y = 0.45
	legs.material_override = pants_mat
	_model.add_child(legs)

	var torso := MeshInstance3D.new()
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.22
	torso_mesh.height = 0.75
	torso.mesh = torso_mesh
	torso.position.y = 1.2
	torso.material_override = shirt_mat
	_model.add_child(torso)

	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.13
	head_mesh.height = 0.26
	head.mesh = head_mesh
	head.position.y = 1.67
	head.material_override = skin_mat
	_model.add_child(head)


func _add_collision() -> void:
	_shape = CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.25
	capsule.height = 1.8
	_shape.shape = capsule
	_shape.position.y = 0.9
	add_child(_shape)
