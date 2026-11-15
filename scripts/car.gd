class_name Car
extends RigidBody3D
## Машина игрока с аркадной физикой: газ, тормоз, руль, ручник, вход и выход,
## вмятины от ударов.
##
## Колёса не настоящие: из каждой точки колеса вниз бьёт луч. Луч работает
## как пружина подвески, а сила сцепления шин считается здесь же, в коде.
## Боковые силы шин прикладываются на высоте центра тяжести, поэтому
## в повороте машину не валит на бок, как бы резко ни крутить руль.
##
## У машины «вперёд» — это ось +Z. Числа с @export можно подбирать
## в инспекторе, выбрав узел Car.

@export_group("Двигатель")
@export var engine_force: float = 7500.0  ## Сила двигателя на старте, Н
@export var reverse_force: float = 3500.0 ## Сила заднего хода
@export var brake_force: float = 14000.0  ## Сила тормоза (S на ходу)
@export var max_speed_kmh: float = 150.0  ## Максимальная скорость вперёд
@export var max_reverse_kmh: float = 30.0

@export_group("Руль")
@export var max_steer_deg: float = 34.0       ## Угол колёс на малой скорости
@export var high_speed_steer_deg: float = 7.0 ## Угол колёс на скорости 120 км/ч
@export var steer_speed: float = 4.0          ## Как быстро крутится руль (радиан в секунду)

@export_group("Шины")
@export var grip: float = 1.25        ## Сцепление шин (больше — меньше заносит)
@export var grip_response: float = 14.0 ## Как быстро шина гасит боковое скольжение
@export var handbrake_rear_grip: float = 0.45 ## Доля сцепления задних колёс на ручнике
@export var rear_drive: float = 0.7  ## Доля тяги на задних колёсах (остальное — на передних)
@export var roll_influence: float = 0.1 ## 0 — машина совсем не кренится от шин, 1 — как в жизни

@export_group("Подвеска")
@export var suspension_rest: float = 0.35  ## Ход подвески от точки колеса до низа колеса, м
@export var wheel_radius: float = 0.35
@export var spring_strength: float = 26000.0
@export var spring_damping: float = 2600.0
@export var downforce: float = 1.5 ## Прижим на скорости: сила = это число × скорость²

@export_group("Устойчивость")
@export var air_upright_strength: float = 6000.0 ## В воздухе машина выравнивается колёсами вниз
@export var auto_recover_time: float = 2.0 ## Через сколько секунд лёжа на боку машина сама встаёт

@export_group("Вмятины")
@export var dent_min_speed: float = 5.0   ## Удар слабее этой скорости (м/с) не оставляет вмятин
@export var dent_radius: float = 0.7
@export var dent_strength: float = 0.03

@export_group("Камера")
@export var mouse_sensitivity: float = 0.003
@export var camera_return_delay: float = 1.5 ## Через сколько секунд камера сама встаёт за машину

const WHEEL_NAMES: Array[String] = ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]

var driver: Player = null

## Управление в этом кадре: газ (-1..1), руль (-1..1), ручник.
var throttle_input := 0.0
var steer_input := 0.0
var handbrake_input := false

var _wheels: Array[Node3D] = []
var _anchors: Array[Vector3] = [] # точки крепления колёс в координатах машины
var _spin: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _contact_count := 0
var _steer := 0.0
var _deformables: Array[DeformableMesh] = []
var _camera_yaw := 0.0
var _camera_pitch := -0.25
var _since_mouse_move := 100.0
var _dent_cooldown := 0.0
var _flipped_time := 0.0

@onready var _camera_rig: Node3D = $CameraRig
@onready var _spring_arm: SpringArm3D = $CameraRig/SpringArm3D
@onready var _camera: Camera3D = $CameraRig/SpringArm3D/Camera3D
@onready var _hud: CanvasLayer = $HUD
@onready var _speed_label: Label = $HUD/Speed


func _ready() -> void:
	add_to_group("vehicles")
	_camera_rig.top_level = true
	_spring_arm.add_excluded_object(get_rid())
	_hud.visible = false
	for node in find_children("*", "MeshInstance3D", true, false):
		if node is DeformableMesh:
			_deformables.append(node as DeformableMesh)
	for wheel_name in WHEEL_NAMES:
		var wheel := get_node(wheel_name) as Node3D
		_wheels.append(wheel)
		_anchors.append(wheel.position)
	_camera_yaw = _behind_yaw()


## Высота дороги под машиной (в её координатах), когда она стоит на подвеске.
func rest_ground_height() -> float:
	var anchor_y := _anchors[0].y if not _anchors.is_empty() else 0.5
	var compression := mass * 9.8 * 0.25 / spring_strength
	return anchor_y - (suspension_rest + wheel_radius) + compression


## Игрок садится в машину.
func enter(player: Player) -> void:
	driver = player
	player.set_in_vehicle(true)
	_camera_yaw = _behind_yaw()
	_since_mouse_move = 100.0
	_camera.make_current()
	_hud.visible = true


## Игрок выходит. Ставим его слева от машины (у водительской двери).
func exit_vehicle() -> void:
	if driver == null:
		return
	var exit_position := global_transform * Vector3(1.8, 0.3, 0.0)
	driver.set_in_vehicle(false, exit_position, _camera_yaw)
	driver = null
	_hud.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if driver == null:
		return
	if event.is_action_pressed("interact"):
		get_viewport().set_input_as_handled()
		if linear_velocity.length() < 4.0:
			exit_vehicle()
		return
	if event.is_action_pressed("reset_vehicle"):
		_flip_upright()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * mouse_sensitivity
		_camera_pitch = clampf(_camera_pitch - event.relative.y * mouse_sensitivity, -1.2, 0.3)
		_since_mouse_move = 0.0


func _physics_process(delta: float) -> void:
	_dent_cooldown -= delta
	if driver != null:
		throttle_input = Input.get_axis("move_back", "move_forward")
		steer_input = Input.get_axis("move_right", "move_left")
		handbrake_input = Input.is_action_pressed("handbrake")
	else:
		# Без водителя машина стоит на ручнике
		throttle_input = 0.0
		steer_input = 0.0
		handbrake_input = true

	var b := global_transform.basis
	var forward_speed := linear_velocity.dot(b.z)

	# Руль: чем быстрее едем, тем меньше угол колёс
	var speed_factor := clampf(absf(forward_speed) / 33.0, 0.0, 1.0)
	var max_steer := deg_to_rad(lerpf(max_steer_deg, high_speed_steer_deg, speed_factor))
	_steer = move_toward(_steer, steer_input * max_steer, steer_speed * delta)

	_contact_count = 0
	for k in _wheels.size():
		_update_wheel(k, delta, forward_speed)

	if _contact_count > 0:
		# Прижим и сопротивление воздуха
		apply_central_force(-b.y * downforce * linear_velocity.length_squared())
	apply_central_force(-linear_velocity * linear_velocity.length() * 0.45)
	_stabilize(delta)


## Одно колесо: пружина подвески, тяга, тормоз и боковое сцепление.
func _update_wheel(k: int, delta: float, forward_speed: float) -> void:
	var b := global_transform.basis
	var up := b.y
	var anchor := global_transform * _anchors[k]
	var max_length := suspension_rest + wheel_radius
	var query := PhysicsRayQueryParameters3D.create(anchor, anchor - up * max_length, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var front := k < 2
	var rear := not front
	var wheel: Node3D = _wheels[k]

	var distance := max_length
	if not hit.is_empty():
		distance = anchor.distance_to(hit["position"])
	# Колесо стоит там, где кончился луч
	var steer_angle := _steer if front else 0.0
	wheel.position = _anchors[k] - Vector3.UP * (distance - wheel_radius)
	_spin[k] += forward_speed / wheel_radius * delta
	wheel.basis = Basis(Vector3.UP, steer_angle) * Basis(Vector3.RIGHT, _spin[k])
	if hit.is_empty():
		return
	_contact_count += 1

	var contact: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var com := global_transform * center_of_mass
	var point_velocity := linear_velocity + angular_velocity.cross(contact - com)

	# Пружина и амортизатор
	var compression := max_length - distance
	var spring := spring_strength * compression - spring_damping * point_velocity.dot(up)
	spring = clampf(spring, 0.0, mass * 9.8 * 2.0)
	apply_force(normal * spring, contact - global_position)

	# Направления колеса по поверхности дороги
	var wheel_forward := b.z.rotated(up, steer_angle)
	wheel_forward = (wheel_forward - normal * wheel_forward.dot(normal)).normalized()
	var wheel_right := normal.cross(wheel_forward).normalized()
	var v_long := point_velocity.dot(wheel_forward)
	var v_lat := point_velocity.dot(wheel_right)
	var wheel_mass := mass * 0.25

	var friction := grip * spring
	var lateral_rate := grip_response
	if rear and handbrake_input:
		friction *= handbrake_rear_grip
		lateral_rate *= handbrake_rear_grip

	# Сила вдоль колеса: газ, тормоз, ручник, сопротивление качению
	var longitudinal := -v_long * 40.0
	if throttle_input > 0.0:
		if forward_speed < -1.0:
			longitudinal = -signf(v_long) * brake_force * 0.25
		elif forward_speed * 3.6 < max_speed_kmh:
			var share := rear_drive if rear else 1.0 - rear_drive
			var taper := 1.0 - 0.6 * clampf(forward_speed * 3.6 / max_speed_kmh, 0.0, 1.0)
			longitudinal = engine_force * throttle_input * share * 0.5 * taper
	elif throttle_input < 0.0:
		if forward_speed > 1.0:
			longitudinal = -signf(v_long) * brake_force * 0.25
		elif -forward_speed * 3.6 < max_reverse_kmh:
			var share := rear_drive if rear else 1.0 - rear_drive
			longitudinal = reverse_force * throttle_input * share * 0.5
	if handbrake_input and (rear or driver == null):
		longitudinal = -signf(v_long) * minf(absf(v_long) * wheel_mass / delta, friction)
	# Тормоз не должен толкать машину назад, когда она уже стоит
	if absf(v_long) < 0.5 and throttle_input == 0.0:
		longitudinal = -v_long * wheel_mass / delta * 0.5

	# Боковая сила: шина гасит скольжение вбок
	var lateral := -v_lat * wheel_mass * lateral_rate

	# Круг трения: вместе обе силы не больше сцепления шины
	var total := Vector2(longitudinal, lateral)
	if total.length() > friction:
		total = total.normalized() * friction

	# Силы шин прикладываем почти на высоте центра тяжести — машина не кренится и не опрокидывается
	var offset := contact - com
	offset -= up * offset.dot(up) * (1.0 - roll_influence)
	apply_force(wheel_forward * total.x + wheel_right * total.y, com + offset - global_position)


func _process(delta: float) -> void:
	# Камера следует за машиной. Если мышь не трогали — сама встаёт сзади.
	_camera_rig.global_position = global_position + Vector3.UP * 1.4
	_since_mouse_move += delta
	if driver != null and _since_mouse_move > camera_return_delay and linear_velocity.length() > 2.0:
		_camera_yaw = lerp_angle(_camera_yaw, _behind_yaw(), 1.0 - exp(-3.0 * delta))
	_camera_rig.global_rotation = Vector3(_camera_pitch, _camera_yaw, 0.0)

	if driver != null:
		var kmh := absf(linear_velocity.dot(global_transform.basis.z)) * 3.6
		_speed_label.text = "%d км/ч" % roundi(kmh)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# Ищем сильные удары корпусом и оставляем вмятины
	if _dent_cooldown > 0.0:
		return
	for i in state.get_contact_count():
		var hit_speed := state.get_contact_impulse(i).length() / mass
		if hit_speed < dent_min_speed:
			continue
		var point := state.get_contact_local_position(i)
		var depth := (hit_speed - dent_min_speed) * dent_strength
		for mesh in _deformables:
			mesh.dent(point, global_position + Vector3.UP * 0.8, dent_radius, depth)
		_dent_cooldown = 0.15
		break


## В воздухе мягко поворачивает машину колёсами вниз, чтобы она
## приземлялась на колёса. Если машина всё же легла на бок или крышу
## и почти не движется, через пару секунд ставит её на колёса.
func _stabilize(delta: float) -> void:
	var up := global_transform.basis.y
	if _contact_count == 0:
		var tilt_axis := up.cross(Vector3.UP)
		var roll_rate := angular_velocity - Vector3.UP * angular_velocity.dot(Vector3.UP)
		apply_torque(tilt_axis * air_upright_strength - roll_rate * air_upright_strength * 0.3)

	if up.dot(Vector3.UP) < 0.3 and linear_velocity.length() < 3.0:
		_flipped_time += delta
		if _flipped_time > auto_recover_time:
			_flip_upright()
	else:
		_flipped_time = 0.0


## Угол камеры, при котором она смотрит машине в спину.
func _behind_yaw() -> float:
	var f := global_transform.basis.z
	return atan2(f.x, f.z) + PI


## Ставит перевёрнутую машину на колёса (клавиша R).
func _flip_upright() -> void:
	_flipped_time = 0.0
	var yaw := atan2(global_transform.basis.z.x, global_transform.basis.z.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 1.5)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
