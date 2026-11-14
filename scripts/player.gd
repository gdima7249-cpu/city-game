class_name Player
extends CharacterBody3D
## Персонаж от третьего лица: ходьба, бег, прыжок, камера мышью.
##
## Числа с @export можно менять прямо в редакторе: выберите узел Player
## и смотрите панель «Инспектор» справа.

@export_group("Движение")
@export var walk_speed: float = 4.0        ## Скорость шага, м/с
@export var run_speed: float = 8.0         ## Скорость бега (Shift), м/с
@export var acceleration: float = 10.0     ## Как быстро набирается скорость
@export var air_control: float = 0.3       ## Управление в воздухе (0..1)
@export var turn_speed: float = 12.0       ## Как быстро персонаж поворачивается

@export_group("Прыжок")
@export var jump_velocity: float = 5.5     ## Сила прыжка
@export var coyote_time: float = 0.12      ## Можно прыгнуть чуть позже, сойдя с края
@export var jump_buffer: float = 0.12      ## Нажатие чуть раньше приземления тоже сработает

@export_group("Камера")
@export var mouse_sensitivity: float = 0.003
@export var min_pitch_deg: float = -75.0   ## Насколько можно смотреть сверху вниз
@export var max_pitch_deg: float = 40.0    ## Насколько можно смотреть снизу вверх
@export var min_zoom: float = 2.0
@export var max_zoom: float = 7.0

@export_group("Машины")
@export var interact_distance: float = 3.5 ## С какого расстояния можно сесть в машину

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _coyote_timer := 0.0
var _jump_buffer_timer := 0.0
var _spawn_position := Vector3.ZERO

@onready var _model: Node3D = $Model
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var _collision: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	_spawn_position = global_position
	# Камера не должна «упираться» в самого персонажа.
	_spring_arm.add_excluded_object(get_rid())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		var vehicle := _find_nearest_vehicle()
		if vehicle != null:
			get_viewport().set_input_as_handled()
			vehicle.enter(self)
		return

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_spring_arm.spring_length = maxf(min_zoom, _spring_arm.spring_length - 0.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_spring_arm.spring_length = minf(max_zoom, _spring_arm.spring_length + 0.5)
	elif event is InputEventMouseMotion:
		_camera_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		_camera_pivot.rotation.x = clampf(
			_camera_pivot.rotation.x - event.relative.y * mouse_sensitivity,
			deg_to_rad(min_pitch_deg),
			deg_to_rad(max_pitch_deg)
		)


## Прячет персонажа, когда он садится в машину, и возвращает при выходе.
func set_in_vehicle(in_vehicle: bool, exit_position: Vector3 = Vector3.ZERO, camera_yaw: float = 0.0) -> void:
	visible = not in_vehicle
	_collision.set_deferred("disabled", in_vehicle)
	process_mode = Node.PROCESS_MODE_DISABLED if in_vehicle else Node.PROCESS_MODE_INHERIT
	velocity = Vector3.ZERO
	if not in_vehicle:
		global_position = exit_position
		_camera_pivot.rotation = Vector3(-0.2, camera_yaw, 0.0)
		_model.rotation.y = camera_yaw
		_camera.make_current()


func _find_nearest_vehicle() -> Car:
	var nearest: Car = null
	var best := interact_distance
	for node in get_tree().get_nodes_in_group("vehicles"):
		var car := node as Car
		if car == null:
			continue
		var distance := global_position.distance_to(car.global_position)
		if distance < best:
			best = distance
			nearest = car
	return nearest


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()

	# Гравитация
	if not on_floor:
		velocity.y -= gravity * delta

	# Прыжок с «прощением» на краю и ранним нажатием
	_coyote_timer = coyote_time if on_floor else _coyote_timer - delta
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = jump_buffer
	else:
		_jump_buffer_timer -= delta
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
	# Короткое нажатие пробела даёт прыжок пониже
	if Input.is_action_just_released("jump") and velocity.y > 0.0:
		velocity.y *= 0.5

	# Направление движения считается относительно камеры
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis := _camera_pivot.global_transform.basis
	var forward := Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()
	var direction := right * input_dir.x - forward * input_dir.y
	if direction.length() > 1.0:
		direction = direction.normalized()

	var speed: float = run_speed if Input.is_action_pressed("sprint") else walk_speed
	var control: float = 1.0 if on_floor else air_control
	var weight := 1.0 - exp(-acceleration * control * delta)
	velocity.x = lerpf(velocity.x, direction.x * speed, weight)
	velocity.z = lerpf(velocity.z, direction.z * speed, weight)

	# Модель плавно поворачивается туда, куда идёт персонаж
	if direction.length() > 0.1:
		var target_yaw := atan2(-direction.x, -direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, 1.0 - exp(-turn_speed * delta))

	move_and_slide()

	# Упал с карты: вернуть на точку старта
	if global_position.y < -30.0:
		global_position = _spawn_position
		velocity = Vector3.ZERO
