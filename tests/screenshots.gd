extends SceneTree
## Снимки города для отчёта (нужно окно, не --headless):
##   godot -s res://tests/screenshots.gd -- <папка> [имя_снимка ...]
## Сохраняет PNG из нескольких точек, днём, на закате и ночью,
## и пишет в консоль число вызовов отрисовки и треугольников на кадр.

var out_dir := "user://shots"
var only: Array[String] = []
var main: Node3D
var cam: Camera3D
var frame := 0
var step := 0
var shots: Array = []
const FRAMES := 6 ## Кадров на снимок: успевают обновиться тени и освещение


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	for k in range(1, args.size()):
		only.append(args[k])
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	cam = Camera3D.new()
	cam.far = 1500.0
	main.add_child(cam)


func _plan() -> void:
	var car := main.get_node("Car") as Node3D
	var player := main.get_node("Player") as Node3D
	var c := car.global_position
	var p := player.global_position
	# [имя, час, позиция камеры, куда смотрит; null = камера игрока]
	shots = [
		["player_view", 10.0, null, null],
		["car_side", 10.0, c + Vector3(0, 1.2, 6.5), c + Vector3(0, 0.5, 0)],
		["car_wheels", 10.0, c + Vector3(2.5, 0.5, 3.5), c + Vector3(0, 0.2, 0)],
		["facade", 11.0, p + Vector3(0, 1.7, 9), p + Vector3(0, 4, -20)],
		["windows_close", 14.0, p + Vector3(2, 2.5, 14), p + Vector3(-6, 4.0, 30)],
		["street_day", 14.0, p + Vector3(-25, 2, 12), p + Vector3(60, 3, 12)],
		["aerial", 13.0, p + Vector3(-160, 140, 220), p + Vector3(40, 0, -40)],
		["street_dusk", 19.6, p + Vector3(-25, 2, 12), p + Vector3(60, 3, 12)],
		["street_night", 23.0, p + Vector3(-25, 2, 12), p + Vector3(60, 3, 12)],
		["aerial_night", 23.0, p + Vector3(-160, 140, 220), p + Vector3(40, 0, -40)],
	]
	if not only.is_empty():
		shots = shots.filter(func(s: Array) -> bool: return only.has(s[0]))


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 10:
		_plan()
	if frame < 10 or shots.is_empty():
		return false
	var phase := (frame - 10) % FRAMES
	var shot: Array = shots[step]
	if phase == 0:
		var dn := main.get_node("DayNight")
		dn.day_minutes = 100000.0
		dn.hour = shot[1]
		if shot[2] == null:
			cam.current = false
			(main.get_node("Player/CameraPivot/SpringArm3D/Camera3D") as Camera3D).current = true
		else:
			cam.current = true
			cam.look_at_from_position(shot[2], shot[3])
	elif phase == FRAMES - 1:
		var img := root.get_texture().get_image()
		img.save_png(out_dir.path_join(shot[0] + ".png"))
		print("%s: вызовов отрисовки %d, треугольников %d, объектов %d" % [shot[0],
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])
		step += 1
		if step >= shots.size():
			return true
	return false
