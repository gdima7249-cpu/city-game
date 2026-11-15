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
