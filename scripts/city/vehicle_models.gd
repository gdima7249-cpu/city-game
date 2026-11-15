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
## Насколько поднять модель игрока, чтобы колёса модели касались земли (высота центра колёс 0.5).
const PLAYER_LIFT := 0.15


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
