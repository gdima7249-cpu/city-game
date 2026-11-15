extends Node
## Назначает клавиши управления и следит за курсором мыши.
##
## Клавиши привязаны к физическому положению на клавиатуре, поэтому
## управление работает и при русской раскладке (W = Ц и т.д.).

func _enter_tree() -> void:
	_bind("move_forward", [KEY_W, KEY_UP])
	_bind("move_back", [KEY_S, KEY_DOWN])
	_bind("move_left", [KEY_A, KEY_LEFT])
	_bind("move_right", [KEY_D, KEY_RIGHT])
	_bind("sprint", [KEY_SHIFT])
	_bind("jump", [KEY_SPACE])
	_bind("handbrake", [KEY_SPACE])
	_bind("interact", [KEY_E, KEY_F])
	_bind("reset_vehicle", [KEY_R])
	_bind("release_mouse", [KEY_ESCAPE])
	_bind("time_skip", [KEY_T])


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# Esc показывает курсор, клик мышью снова прячет его
	if event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _bind(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)
