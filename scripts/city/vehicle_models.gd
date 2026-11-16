class_name VehicleModels
extends RefCounted
## Здесь меняются модели машин: трафика и машины игрока.
## Модели — Kenney «Car Kit» (CC0), файлы в assets/cars.
##
## Чтобы поставить свои: положите .glb в assets/cars и поменяйте пути ниже.
## Если список пуст или файл не найден — вместо модели остаются простые коробки.
## Физику это не затрагивает: меняется только внешний вид.

## Машины трафика: каждая берёт случайную модель из списка.
const TRAFFIC: Array[String] = [
	"res://assets/cars/sedan.glb",
	"res://assets/cars/sedan-sports.glb",
	"res://assets/cars/hatchback-sports.glb",
	"res://assets/cars/suv.glb",
	"res://assets/cars/suv-luxury.glb",
	"res://assets/cars/taxi.glb",
	"res://assets/cars/van.glb",
	"res://assets/cars/delivery.glb",
	"res://assets/cars/truck.glb",
]

## Машина игрока.
const PLAYER := "res://assets/cars/sedan-sports.glb"

## Модели Kenney смотрят носом в +Z. Машина игрока тоже едет в +Z, а машины трафика — в -Z.
const PLAYER_YAW_DEGREES := 0.0
const TRAFFIC_YAW_DEGREES := 180.0
## Модели маленькие (седан около 2.5 м), поэтому увеличиваем под размер игры.
const SCALE := 1.5
## Модель игрока сама встаёт колёсами на дорогу (см. car_skin.gd), поэтому подъём 0.
const PLAYER_LIFT := 0.0
## Колёса модели крутятся и поворачиваются, если их узлы называются с этого слова
## (у Kenney: wheel-front-left, wheel-back-right). Для другого пака поменяйте слова;
## если колёс с такими именами нет, модель просто едет с неподвижными колёсами.
const WHEEL_PREFIX := "wheel"
const WHEEL_FRONT_WORD := "front"
const WHEEL_LEFT_WORD := "left"
## Радиус колеса модели после увеличения, м (нужен, чтобы колёса крутились без проскальзывания)
const WHEEL_RADIUS := 0.45


static func random_traffic_model(rng_value: int) -> Node3D:
	if TRAFFIC.is_empty():
		return null
	return _load(TRAFFIC[posmod(rng_value, TRAFFIC.size())], TRAFFIC_YAW_DEGREES, 0.0)


static func player_model() -> Node3D:
	if PLAYER.is_empty():
		return null
	return _load(PLAYER, PLAYER_YAW_DEGREES, PLAYER_LIFT)


static func _load(path: String, yaw_degrees: float, lift: float) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var model := scene.instantiate() as Node3D
	if model != null:
		model.rotation.y = deg_to_rad(yaw_degrees)
		model.scale = Vector3.ONE * SCALE
		model.position.y = lift
	return model


## Колёса модели: [[узел, переднее?, левое?, исходный поворот], ...].
static func find_wheels(model: Node) -> Array:
	var result := []
	for node in model.find_children(WHEEL_PREFIX + "*", "Node3D", true, false):
		var n := node as Node3D
		var lower := n.name.to_lower()
		result.append([n, lower.contains(WHEEL_FRONT_WORD), lower.contains(WHEEL_LEFT_WORD), n.basis])
	return result
