extends Node3D
## Внешний вид машины игрока: ставит настоящую модель из VehicleModels
## и прячет простые коробки и цилиндры-колёса. Физика и столкновения не меняются.

const PLACEHOLDERS: Array[String] = [
	"Body", "Cabin", "HeadlightLeft", "HeadlightRight",
	"WheelFrontLeft/Mesh", "WheelFrontRight/Mesh", "WheelRearLeft/Mesh", "WheelRearRight/Mesh",
]

var _wheels := [] # колёса модели: [узел модели, узел колеса физики, исходный поворот]


func _ready() -> void:
	var model := VehicleModels.player_model()
	if model == null:
		return
	var car := get_parent()
	for path in PLACEHOLDERS:
		var node := car.get_node_or_null(path) as Node3D
		if node != null:
			node.visible = false
	add_child(model)
	_sit_on_ground(car as Car, model)
	# Колёса модели повторяют колёса физики: крутятся и поворачиваются рулём
	for w: Array in VehicleModels.find_wheels(model):
		var physics_name: String = ("WheelFront" if w[1] else "WheelRear") + ("Left" if w[2] else "Right")
		var physics_wheel := car.get_node_or_null(physics_name) as Node3D
		if physics_wheel != null:
			_wheels.append([w[0], physics_wheel, w[3]])
	set_process(not _wheels.is_empty())


func _process(_delta: float) -> void:
	for w: Array in _wheels:
		(w[0] as Node3D).basis = (w[1] as Node3D).basis * (w[2] as Basis)


## Ставит модель так, чтобы низ её колёс был ровно на дороге,
## когда машина стоит на подвеске (число PLAYER_LIFT больше не нужно).
func _sit_on_ground(car: Car, model: Node3D) -> void:
	if car == null:
		return
	var bottom := INF
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var xform := _relative(mesh)
		var box := xform * mesh.mesh.get_aabb()
		bottom = minf(bottom, box.position.y)
	if bottom == INF:
		return
	model.position.y += car.rest_ground_height() - bottom


## Положение узла относительно этой ноды (Skin).
func _relative(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != self:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
