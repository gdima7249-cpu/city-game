class_name Car
extends VehicleBody3D
## Машина: газ, тормоз, руль, ручник, вход и выход, вмятины от ударов.
##
## У VehicleBody3D «вперёд» — это ось +Z. Числа с @export можно
## подбирать в инспекторе, выбрав узел Car.

@export_group("Двигатель")
@export var engine_power: float = 3500.0   ## Сила двигателя
@export var reverse_power: float = 1800.0  ## Сила заднего хода
@export var brake_power: float = 6000.0    ## Сила тормоза (S на ходу)
@export var max_speed_kmh: float = 140.0   ## Максимальная скорость вперёд
@export var max_reverse_kmh: float = 30.0

@export_group("Руль")
@export var max_steer_deg: float = 32.0          ## Максимальный угол поворота колёс
@export var steer_speed: float = 3.0             ## Как быстро крутится руль
@export var high_speed_steer_factor: float = 0.4 ## Руль на большой скорости (меньше = стабильнее)

@export_group("Ручник")
@export var handbrake_force: float = 40.0
@export var handbrake_rear_grip: float = 1.2 ## Сцепление задних колёс на ручнике (меньше = больше занос)

@export_group("Вмятины")
@export var dent_min_speed: float = 3.0   ## Удар слабее этой скорости (м/с) не оставляет вмятин
@export var dent_radius: float = 0.7
@export var dent_strength: float = 0.03

@export_group("Камера")
@export var mouse_sensitivity: float = 0.003
@export var camera_return_delay: float = 1.5 ## Через сколько секунд камера сама встаёт за машину

var driver: Player = null

var _rear_wheels: Array[VehicleWheel3D] = []
var _deformables: Array[DeformableMesh] = []
var _rear_grip: float = 10.5
var _camera_yaw := 0.0
var _camera_pitch := -0.25
var _since_mouse_move := 100.0
var _dent_cooldown := 0.0

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
	for child in get_children():
		var wheel := child as VehicleWheel3D
		if wheel != null and wheel.use_as_traction and not wheel.use_as_steering:
			_rear_wheels.append(wheel)
	if not _rear_wheels.is_empty():
		_rear_grip = _rear_wheels[0].wheel_friction_slip
	_camera_yaw = _behind_yaw()


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
	engine_force = 0.0
	steering = 0.0
	_set_handbrake(false)
	brake = 2.0
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
	var forward_speed := linear_velocity.dot(global_transform.basis.z)

	if driver == null:
		return

	# Газ и тормоз
	var throttle := Input.get_axis("move_back", "move_forward")
	var force := 0.0
	if throttle > 0.0:
		force = engine_power * throttle if forward_speed > -1.0 else brake_power * throttle
		if forward_speed * 3.6 > max_speed_kmh:
			force = 0.0
	elif throttle < 0.0:
		force = brake_power * throttle if forward_speed > 1.0 else reverse_power * throttle
		if -forward_speed * 3.6 > max_reverse_kmh:
			force = 0.0
	engine_force = force
	brake = 0.0 if throttle != 0.0 else 1.0

	# Руль: на скорости поворачиваем меньше, чтобы машину не кидало
	var speed_factor := clampf(absf(forward_speed) / 30.0, 0.0, 1.0)
	var max_steer := deg_to_rad(max_steer_deg) * lerpf(1.0, high_speed_steer_factor, speed_factor)
	var steer_input := Input.get_axis("move_right", "move_left")
	steering = move_toward(steering, steer_input * max_steer, steer_speed * delta)

	_set_handbrake(Input.is_action_pressed("handbrake"))


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


## Угол камеры, при котором она смотрит машине в спину.
func _behind_yaw() -> float:
	var f := global_transform.basis.z
	return atan2(f.x, f.z) + PI


func _set_handbrake(on: bool) -> void:
	for wheel in _rear_wheels:
		wheel.brake = handbrake_force if on else 0.0
		wheel.wheel_friction_slip = handbrake_rear_grip if on else _rear_grip


## Ставит перевёрнутую машину на колёса (клавиша R).
func _flip_upright() -> void:
	var yaw := atan2(global_transform.basis.z.x, global_transform.basis.z.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 1.5)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
