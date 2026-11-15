class_name TrafficCar
extends AnimatableBody3D
## Машина городского трафика. Едет по своей полосе, слушается светофоров,
## держит дистанцию до машины впереди и тормозит перед игроком.

const LENGTH := 4.4
const ACCEL := 3.5
const DECEL := 7.0

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


func setup(city: CityGrid, from_index: int, dir: int, lane: int, pos: Vector3, color: Color, top_speed: float) -> void:
	grid = city
	max_speed = top_speed
	collision_layer = 4  # слой 3: машины трафика
	collision_mask = 0
	_build_body(color)
	_enter_lane(from_index, dir, lane)
	heading = CityGrid.DIRS[dir]
	global_position = pos
	look_at(pos + heading, Vector3.UP)


func _enter_lane(from_index: int, dir: int, lane: int) -> void:
	_from = from_index
	_dir = dir
	_lane = lane
	_to = grid.neighbor(from_index, dir)
	_path = PackedVector3Array([grid.exit_point(_from, _dir, _lane), grid.stop_point(_to, _dir, _lane)])
	_target = 1
	_turning = false
	_committed = false


func _physics_process(delta: float) -> void:
	var desired := max_speed

	# Светофор: решаем, ехать или останавливаться у стоп-линии
	if not _turning:
		var stop := _path[_path.size() - 1]
		var to_stop := global_position.distance_to(stop)
		if not _committed:
			var light := grid.intersections[_to].light_for(_dir)
			var braking := speed * speed / (2.0 * DECEL)
			if light == TrafficIntersection.Light.GREEN:
				_committed = true
			elif light == TrafficIntersection.Light.YELLOW and braking > to_stop - 0.5:
				_committed = true
		if not _committed:
			desired = minf(desired, sqrt(2.0 * DECEL * maxf(to_stop - 0.2, 0.0)))

	# Машина впереди
	var gap := _gap_to_leader()
	if gap < INF:
		desired = minf(desired, sqrt(2.0 * DECEL * maxf(gap - LENGTH - 2.5, 0.0)))

	# Игрок, его машина или предмет на дороге
	if _ray.is_colliding():
		var hit := global_position.distance_to(_ray.get_collision_point()) - LENGTH * 0.5
		desired = minf(desired, sqrt(2.0 * DECEL * maxf(hit - 1.5, 0.0)))

	var rate: float = ACCEL if desired > speed else DECEL * 1.5
	speed = move_toward(speed, desired, rate * delta)
	_advance(speed * delta)


func _advance(distance: float) -> void:
	var pos := global_position
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
	var move := pos - global_position
	if move.length() > 0.001:
		heading = heading.slerp(move.normalized(), 0.35).normalized()
		look_at_from_position(pos, pos + heading, Vector3.UP)
	else:
		global_position = pos


func _start_turn() -> void:
	var exits := grid.exits_from(_to, _dir)
	var leaving := exits[grid.rng.randi() % exits.size()]
	var new_lane := grid.lane_after_turn(_to, _dir, leaving, _lane)
	_path = grid.turn_path(_to, _dir, leaving, _lane, new_lane)
	_target = 0
	_turning = true
	_dir = leaving
	_lane = new_lane


func _gap_to_leader() -> float:
	var best := INF
	for other in grid.cars:
		if other == self:
			continue
		var offset := other.global_position - global_position
		var ahead := offset.dot(heading)
		if ahead <= 0.0 or ahead > 25.0:
			continue
		if (offset - heading * ahead).length() > 1.8:
			continue
		if other.heading.dot(heading) < 0.3:
			continue # встречные и поперечные машины не мешают
		best = minf(best, ahead)
	return best


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

	# Настоящая модель, если она задана в vehicle_models.gd; иначе коробка с колёсами
	var model := VehicleModels.random_traffic_model(randi())
	if model != null:
		add_child(model)
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

	# Луч вперёд (у машины «вперёд» — это -Z): видит игрока и его машину
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
	add_child(m)
	return m
