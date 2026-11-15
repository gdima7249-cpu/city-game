class_name Pedestrian
extends AnimatableBody3D
## Пешеход: гуляет по тротуару вокруг квартала и останавливается,
## если перед ним стоит игрок.

var speed := 1.4
var _loop := PackedVector3Array()
var _target := 0
var _waiting := 0.0
var _player: Node3D
var _model: Node3D
var _human: Humanoid
var _bob := 0.0


func setup(loop: PackedVector3Array, start_corner: int, start_fraction: float, walk_speed: float,
		shirt: Color, skin: Color) -> void:
	_loop = loop
	speed = walk_speed
	collision_layer = 8 # слой 4: пешеходы
	collision_mask = 0
	_build_body(shirt, skin)
	var a := _loop[start_corner]
	var b := _loop[(start_corner + 1) % _loop.size()]
	global_position = a.lerp(b, start_fraction)
	_target = (start_corner + 1) % _loop.size()


func _play(anim_name: String) -> void:
	if _human != null:
		_human.play(anim_name, 1.0 if anim_name == "Idle" else speed / 1.3)


func _physics_process(delta: float) -> void:
	if _waiting > 0.0:
		_waiting -= delta
		_play("Idle")
		return
	var pos := global_position
	var target := _loop[_target]
	var to_target := target - pos
	var distance := to_target.length()
	if distance < 0.05:
		_target = (_target + 1) % _loop.size()
		# Иногда задерживаемся на углу
		if randf() < 0.25:
			_waiting = randf_range(1.0, 4.0)
		return
	var dir := to_target / distance

	if _player == null:
		_player = get_tree().get_first_node_in_group("player") as Node3D

	# Не идём сквозь игрока
	if _player != null and _player.visible:
		var to_player := _player.global_position - pos
		to_player.y = 0.0
		if to_player.length() < 1.6 and to_player.dot(dir) > 0.3:
			_play("Idle")
			return

	var step := minf(speed * delta, distance)
	pos += dir * step
	look_at_from_position(pos, pos + dir, Vector3.UP)
	_play("Walk")
	if _human == null:
		# Лёгкое покачивание при ходьбе (только у заглушки)
		_bob += step * 6.0
		_model.position.y = absf(sin(_bob)) * 0.05


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
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.25
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
