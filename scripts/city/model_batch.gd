class_name ModelBatch
extends RefCounted
## Много копий готовых моделей (например, припаркованных машин) одним MultiMesh
## на каждую деталь модели. Сотня машин рисуется за десяток вызовов отрисовки.

var draw_range := 0.0 ## Дальше этого модели не рисуются (0 — всегда)

var _parts := {}   # путь -> Array[[Mesh, Transform3D]]
var _batches := {} # [Mesh] -> Array[Transform3D]
var _multimeshes := {} # Mesh -> MultiMesh (после flush)
var _copies: Array = [] # номер копии -> Array[[Mesh, номер в MultiMesh]]


## Поставить модель из файла path. extra — поворот и масштаб внутри модели.
## Возвращает номер копии (для hide).
func add(path: String, xform: Transform3D, extra: Transform3D = Transform3D()) -> int:
	var parts := []
	for part: Array in _get_parts(path):
		var mesh: Mesh = part[0]
		if not _batches.has(mesh):
			_batches[mesh] = []
		parts.append([mesh, _batches[mesh].size()])
		_batches[mesh].append(xform * extra * (part[1] as Transform3D))
	_copies.append(parts)
	return _copies.size() - 1


## Убрать копию модели (например, в припаркованную машину сел игрок).
func hide(copy: int) -> void:
	if copy < 0 or copy >= _copies.size():
		return
	for part: Array in _copies[copy]:
		var mm: MultiMesh = _multimeshes.get(part[0])
		if mm != null:
			mm.set_instance_transform(part[1], Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	_copies[copy] = []


func flush(parent: Node3D, node_name: String) -> void:
	for mesh: Mesh in _batches:
		var transforms: Array = _batches[mesh]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = transforms.size()
		for k in transforms.size():
			mm.set_instance_transform(k, transforms[k])
		_multimeshes[mesh] = mm
		var mmi := MultiMeshInstance3D.new()
		mmi.name = node_name
		mmi.multimesh = mm
		if draw_range > 0.0:
			mmi.visibility_range_end = draw_range
			mmi.visibility_range_end_margin = 20.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(mmi)
	_batches.clear()


func _get_parts(path: String) -> Array:
	if _parts.has(path):
		return _parts[path]
	var result := []
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene != null:
			var root := scene.instantiate() as Node3D
			for node in root.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				if mi.mesh != null:
					result.append([mi.mesh, _relative(root, mi)])
			root.free()
	_parts[path] = result
	return result


func _relative(root: Node, node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
