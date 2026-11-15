extends SceneTree
## Проверка «жизни на улицах» без окна:
##   godot --headless -s res://tests/street_life_check.gd
## Пишет в консоль, сколько людей перешло дорогу, сколько машин стоит,
## не проезжает ли трафик сквозь людей, и что бывает при наезде машиной игрока.

var main: Node
var city: CityGrid
var frame := 0
var crossings := 0
var overlaps := 0
var cells := {}
var phase_seen := false
var victim: Pedestrian
var victim_states := []
var neighbors_fled := 0
var blocked_car: TrafficCar
var rammed: TrafficCar
var blocked_log := []
var max_physics_ms := 0.0
var sum_physics_ms := 0.0


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	city = main.get_node("District") as CityGrid


func _physics_process(_delta: float) -> bool:
	frame += 1
	var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	if frame > 120:
		max_physics_ms = maxf(max_physics_ms, ms)
		sum_physics_ms += ms
	var peds := root.get_tree().get_nodes_in_group("pedestrians")
	for node in peds:
		var p := node as Pedestrian
		if cells.has(p) and cells[p] != p._cell:
			crossings += 1
		cells[p] = p._cell
		# Трафик не должен ехать сквозь людей
		if p.state != Pedestrian.State.KNOCKED and p.state != Pedestrian.State.DOWN:
			for car in city.cars:
				if car.speed > 1.5 and car.global_position.distance_to(p.global_position) < 2.0:
					var local := car.global_transform.affine_inverse() * p.global_position
					if absf(local.x) < 0.9 and absf(local.z) < 2.2:
						overlaps += 1
	for idx in city.intersections:
		if idx != null and idx.walk_time_left() > 0.0:
			phase_seen = true

	if frame % 600 == 0:
		var hist := {}
		for node in peds:
			var key: String = Pedestrian.State.keys()[(node as Pedestrian).state]
			hist[key] = hist.get(key, 0) + 1
		var stopped := 0
		var sum := 0.0
		for car in city.cars:
			sum += car.speed
			if car.speed < 0.5:
				stopped += 1
		print("t=%ds  люди %s  переходов %d  машин стоит %d/%d, средняя %.1f м/с  наездов трафика %d" % [
			frame / 60, hist, crossings, stopped, city.cars.size(), sum / city.cars.size(), overlaps])

	if frame == 2400:
		_start_hit_test(peds)
	if frame > 2400 and frame < 2480:
		_drive_at_victim()
	if victim != null and frame % 20 == 0 and frame < 3200:
		victim_states.append(Pedestrian.State.keys()[victim.state])
	if frame == 3000:
		print("Наезд: состояния сбитого ", victim_states)
		var near := 0
		for node in root.get_tree().get_nodes_in_group("pedestrians"):
			if node.has_meta("near"):
				near += 1
		print("Наезд: рядом было людей %d, разбежались %d" % [near, neighbors_fled])
		_start_block_test()
	if frame > 3000 and blocked_car != null and frame % 30 == 0:
		var pc := main.get_node("Car") as Node3D
		var rel := pc.global_position - blocked_car.global_position
		blocked_log.append("%.1f/%.1f/%d" % [blocked_car.speed, blocked_car._offset, blocked_car.honks])
	if frame == 3900:
		print("Затор: скорость/сдвиг машины за игроком (скорость/сдвиг вбок/гудков) ", blocked_log)
		_start_ram_test()
	if frame > 3900 and frame < 3960 and rammed != null:
		var car := main.get_node("Car") as RigidBody3D
		var to := rammed.global_position - car.global_position
		to.y = 0.0
		car.linear_velocity = to.normalized() * 12.0
	if frame == 4000 and rammed != null:
		print("Таран: машина трафика встала=%s, гудков=%d" % [rammed._shaken > 0.0, rammed.honks])
	if frame == 4000:
		print("Физика: в среднем %.2f мс, максимум %.2f мс за кадр" % [sum_physics_ms / (frame - 120), max_physics_ms])
		print("Пешеходная фаза светофоров была: ", phase_seen)
		quit()
	return false


## Наезд: сначала машина игрока несётся на человека издалека (он должен
## испугаться и отбежать), потом — в упор (увернуться нельзя, он отлетает).
func _start_hit_test(peds: Array) -> void:
	for node in peds:
		var p := node as Pedestrian
		if p.state == Pedestrian.State.WALK and p._waiting <= 0.0:
			victim = p
			break
	var fwd := -victim.global_transform.basis.z
	_place_car(victim.global_position + fwd * 16.0, -fwd)
	for node in peds:
		var p := node as Pedestrian
		if p != victim and p.global_position.distance_to(victim.global_position) < 12.0:
			p.set_meta("near", true)


func _place_car(pos: Vector3, facing: Vector3) -> void:
	var car := main.get_node("Car") as RigidBody3D
	facing.y = 0.0
	car.global_transform = Transform3D(Basis.looking_at(-facing.normalized(), Vector3.UP), pos + Vector3.UP * 0.6)
	car.linear_velocity = facing.normalized() * 15.0


func _drive_at_victim() -> void:
	var car := main.get_node("Car") as RigidBody3D
	if frame == 2440:
		print("Наезд издалека: человек ", Pedestrian.State.keys()[victim.state])
		# Теперь в упор
		var to := victim.global_position - car.global_position
		to.y = 0.0
		_place_car(victim.global_position - to.normalized() * 3.2, to)
	elif frame > 2440 and victim.state != Pedestrian.State.KNOCKED and victim.state != Pedestrian.State.DOWN:
		var to := victim.global_position - car.global_position
		to.y = 0.0
		car.linear_velocity = to.normalized() * 15.0
	if frame == 2479:
		for node in root.get_tree().get_nodes_in_group("pedestrians"):
			var p := node as Pedestrian
			if p.has_meta("near") and p.state == Pedestrian.State.FLEE:
				neighbors_fled += 1


## Таран: машина игрока на 12 м/с въезжает в бок машине трафика.
func _start_ram_test() -> void:
	var car := main.get_node("Car") as RigidBody3D
	for c in city.cars:
		if c != blocked_car and not c._turning:
			rammed = c
			break
	var side := CityGrid.right_of(rammed.heading)
	car.linear_velocity = Vector3.ZERO
	car.global_transform = Transform3D(Basis.looking_at(side, Vector3.UP), rammed.global_position - side * 7.0 + Vector3.UP * 0.6)


## Ставим машину игрока поперёк полосы перед машиной трафика.
func _start_block_test() -> void:
	var car := main.get_node("Car") as RigidBody3D
	for c in city.cars:
		if c.speed > 6.0 and not c._turning:
			var stop := c._path[c._path.size() - 1]
			if c._base.distance_to(stop) > 40.0:
				blocked_car = c
				break
	if blocked_car == null:
		print("Затор: не нашлось подходящей машины")
		return
	car.linear_velocity = Vector3.ZERO
	car.global_transform = Transform3D(Basis.looking_at(CityGrid.right_of(blocked_car.heading), Vector3.UP),
			blocked_car._base + blocked_car.heading * 25.0 + Vector3.UP * 0.6)
