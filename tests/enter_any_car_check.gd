extends SceneTree
## Проверка «сесть в любую машину» без окна:
##   godot --headless -s res://tests/enter_any_car_check.gd
## Игрок садится в машину трафика, потом в припаркованную; машины должны
## встать на дорогу и не проваливаться.

var main: Node3D
var city: CityGrid
var player: Player
var frame := 0
var taken: Array[Car] = []
var ok := true


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	city = main.get_node("District") as CityGrid
	player = main.get_node("Player") as Player


func _check(cond: bool, text: String) -> void:
	print(("OK   " if cond else "FAIL ") + text)
	if not cond:
		ok = false


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 60:
		var before := city.cars.size()
		var target := city.cars[0]
		var model := target.model_path
		player.global_position = target.global_position + target.global_transform.basis.x * 1.5
		var car := city.take_car_near(player.global_position, player.interact_distance)
		_check(car != null, "машина трафика рядом найдена")
		if car != null:
			car.enter(player)
			_check(car.driver == player, "игрок за рулём машины трафика")
			_check(car.model_path == model, "модель та же: " + model.get_file())
			_check(city.cars.size() == before - 1, "машина ушла из трафика (%d -> %d)" % [before, city.cars.size()])
			taken.append(car)
	if frame == 200 and not taken.is_empty():
		var car := taken[0]
		_check(car.global_position.y > -0.5 and car.global_position.y < 2.0, "машина трафика стоит на дороге (y = %.2f)" % car.global_position.y)
		_check(car.global_transform.basis.y.dot(Vector3.UP) > 0.9, "машина трафика не перевернулась")
		car.exit_vehicle()
		_check(car.driver == null and player.visible, "игрок вышел")
		var props: StreetProps = city._props
		var before := props.parked.size()
		var spot := city.to_global((props.parked[0][0] as Transform3D).origin)
		player.global_position = spot + Vector3(1.5, 0.3, 0)
		var parked := city.take_car_near(player.global_position, player.interact_distance)
		_check(parked != null, "припаркованная машина рядом найдена")
		if parked != null:
			parked.enter(player)
			_check(parked.driver == player, "игрок за рулём припаркованной машины")
			_check(props.parked.size() == before - 1, "место на парковке освободилось")
			taken.append(parked)
	if frame == 340:
		if taken.size() > 1:
			var car := taken[1]
			_check(car.global_position.y > -0.5 and car.global_position.y < 2.0, "припаркованная машина стоит на дороге (y = %.2f)" % car.global_position.y)
			_check(car.global_transform.basis.y.dot(Vector3.UP) > 0.9, "припаркованная машина не перевернулась")
		var far := city.take_car_near(Vector3(10000, 0, 10000), player.interact_distance)
		_check(far == null, "вдали от машин сесть нельзя")
		print("ИТОГ: " + ("всё работает" if ok else "есть ошибки"))
		return true
	return false
