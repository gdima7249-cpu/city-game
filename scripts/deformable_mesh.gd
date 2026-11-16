class_name DeformableMesh
extends MeshInstance3D
## Сетка, которая мнётся от ударов (простые вмятины).
##
## В инспекторе этому узлу задаётся обычная BoxMesh с подразделениями
## (subdivide). При запуске она превращается в редактируемую сетку,
## и метод dent() вдавливает вершины рядом с точкой удара.

@export var max_depth: float = 0.25 ## Насколько глубоко может промяться корпус, м

var _surfaces: Array = []          # массивы вершин каждой поверхности
var _original: Array[PackedVector3Array] = []
var _original_normals: Array[PackedVector3Array] = []
var _array_mesh: ArrayMesh


func _ready() -> void:
	if mesh == null:
		return
	_array_mesh = ArrayMesh.new()
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		_surfaces.append(arrays)
		_original.append((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate())
		_original_normals.append((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate())
	var material := get_active_material(0)
	mesh = _array_mesh
	_rebuild()
	if material != null:
		set_surface_override_material(0, material)


## Вдавливает корпус. point и push_toward — точки в мировых координатах:
## место удара и центр машины, куда «вмять» металл.
func dent(point: Vector3, push_toward: Vector3, radius: float, depth: float) -> void:
	if _array_mesh == null:
		return
	var local_point := to_local(point)
	var local_target := to_local(push_toward)
	var push_dir := (local_target - local_point).normalized()
	var changed := false

	for s in _surfaces.size():
		var vertices: PackedVector3Array = _surfaces[s][Mesh.ARRAY_VERTEX]
		var original := _original[s]
		for v in vertices.size():
			var distance := vertices[v].distance_to(local_point)
			if distance > radius:
				continue
			var falloff := 1.0 - distance / radius
			var moved := vertices[v] + push_dir * depth * falloff * falloff
			var offset := moved - original[v]
			if offset.length() > max_depth:
				offset = offset.normalized() * max_depth
			vertices[v] = original[v] + offset
			changed = true
		_surfaces[s][Mesh.ARRAY_VERTEX] = vertices
		_recalculate_normals(s)

	if changed:
		_rebuild()


## Убирает все вмятины.
func repair() -> void:
	for s in _surfaces.size():
		_surfaces[s][Mesh.ARRAY_VERTEX] = _original[s].duplicate()
		_surfaces[s][Mesh.ARRAY_NORMAL] = _original_normals[s].duplicate()
	_rebuild()


func _rebuild() -> void:
	_array_mesh.clear_surfaces()
	for arrays in _surfaces:
		_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## Пересчитывает нормали, чтобы вмятины было видно по свету и теням.
func _recalculate_normals(s: int) -> void:
	if _surfaces[s][Mesh.ARRAY_INDEX] == null:
		return
	var vertices: PackedVector3Array = _surfaces[s][Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = _surfaces[s][Mesh.ARRAY_INDEX]
	var reference := _original_normals[s]
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for t in range(0, indices.size() - 2, 3):
		var a := indices[t]
		var b := indices[t + 1]
		var c := indices[t + 2]
		var face := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
	for v in normals.size():
		var n := normals[v].normalized()
		# Направление (наружу) берём по исходной нормали
		if n.dot(reference[v]) < 0.0:
			n = -n
		normals[v] = n if n != Vector3.ZERO else reference[v]
	_surfaces[s][Mesh.ARRAY_NORMAL] = normals
