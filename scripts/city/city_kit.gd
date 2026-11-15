class_name CityKit
extends RefCounted
## Модели пака Quaternius «Downtown City MegaKit» (CC0), папка assets/downtown.
##
## Одинаковые детали собираются в MultiMesh: тысячи окон и стен рисуются
## за несколько вызовов отрисовки, и игра не тормозит.

const PATH := "res://assets/downtown/%s.gltf"

var _pieces := {}  # имя -> [Mesh, Transform3D] или [] если модели нет
var _batches := {} # имя -> Array[Transform3D]


static func available() -> bool:
	return ResourceLoader.exists(PATH % "Building_Small_1")


## Габариты модели (в её собственных координатах).
func bounds(piece_name: String) -> AABB:
	var p := _piece(piece_name)
	if p.is_empty():
		return AABB(Vector3(-1, 0, -1), Vector3(2, 3, 2))
	var mesh: Mesh = p[0]
	var t: Transform3D = p[1]
	return t * mesh.get_aabb()


## Поставить деталь. xform — где стоит деталь в координатах родителя.
func add(piece_name: String, xform: Transform3D) -> void:
	var p := _piece(piece_name)
	if p.is_empty():
		return
	if not _batches.has(piece_name):
		_batches[piece_name] = []
	_batches[piece_name].append(xform * (p[1] as Transform3D))


## Создать MultiMesh для всех поставленных деталей.
func flush(parent: Node3D) -> void:
	for piece_name in _batches:
		var transforms: Array = _batches[piece_name]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _piece(piece_name)[0]
		mm.instance_count = transforms.size()
		for k in transforms.size():
			mm.set_instance_transform(k, transforms[k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Kit_" + str(piece_name)
		mmi.multimesh = mm
		parent.add_child(mmi)
	_batches.clear()


func _piece(piece_name: String) -> Array:
	if _pieces.has(piece_name):
		return _pieces[piece_name]
	var result := []
	var scene := load(PATH % piece_name) as PackedScene
	if scene != null:
		var root := scene.instantiate()
		var mesh_node := _find_mesh(root)
		if mesh_node != null:
			result = [mesh_node.mesh, _relative_transform(root, mesh_node)]
		root.free()
	else:
		push_warning("Нет модели: " + piece_name)
	_pieces[piece_name] = result
	return result


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _relative_transform(root: Node, node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
