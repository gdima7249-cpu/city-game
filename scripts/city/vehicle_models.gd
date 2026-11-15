class_name VehicleModels
extends RefCounted
## Здесь меняются модели машин трафика. Пока список пустой — машины простые коробки.
##
## Чтобы поставить настоящие модели: положите файлы (.glb/.gltf) в assets/cars и
## впишите пути в TRAFFIC, например:
##   const TRAFFIC: Array[String] = ["res://assets/cars/sedan.glb", "res://assets/cars/van.glb"]
## Каждая машина трафика возьмёт случайную модель из списка.

const TRAFFIC: Array[String] = []

## Если машина на модели смотрит не туда — поверните (градусы вокруг вертикали).
const YAW_DEGREES := 0.0
## Если модель слишком большая или маленькая — масштаб.
const SCALE := 1.0
## Длина модели в метрах после масштаба: нужна, чтобы держать дистанцию (у коробки 4.4).
const LENGTH := 4.4


static func random_traffic_model(rng_value: int) -> Node3D:
	if TRAFFIC.is_empty():
		return null
	var scene := load(TRAFFIC[posmod(rng_value, TRAFFIC.size())]) as PackedScene
	if scene == null:
		return null
	var model := scene.instantiate() as Node3D
	if model != null:
		model.rotation.y = deg_to_rad(YAW_DEGREES)
		model.scale = Vector3.ONE * SCALE
	return model
