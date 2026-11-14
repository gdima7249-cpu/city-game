extends Node
## Назначает клавиши управления при запуске игры.
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
	_bind("release_mouse", [KEY_ESCAPE])


func _bind(action: StringName, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)
