extends Node3D
## Внешний вид машины игрока: ставит настоящую модель из VehicleModels
## и прячет простые коробки и цилиндры-колёса. Физика и столкновения не меняются.

const PLACEHOLDERS: Array[String] = [
	"Body", "Cabin", "HeadlightLeft", "HeadlightRight",
	"WheelFrontLeft/Mesh", "WheelFrontRight/Mesh", "WheelRearLeft/Mesh", "WheelRearRight/Mesh",
]


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
