class_name BoxBatch
extends RefCounted
## Много одинаковых простых фигур (коробки, цилиндры) одним MultiMesh на каждый
## материал и участок города. Так тысячи крыш, навесов и скамеек рисуются за
## несколько вызовов отрисовки.

const CHUNK := 240.0

var _shapes := {}  # имя фигуры -> Mesh
var _batches := {} # [имя фигуры, материал, участок, до, от, тень] -> Array[Transform3D]


func _init() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_shapes["box"] = box
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.5
	cylinder.bottom_radius = 0.5
	cylinder.height = 1.0
	cylinder.radial_segments = 10
	cylinder.rings = 1
	_shapes["cylinder"] = cylinder
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_shapes["sphere"] = sphere


## Коробка размера size, центр в xform.origin (xform без масштаба).
func box(xform: Transform3D, size: Vector3, material: Material, draw_range: float = 0.0) -> void:
	add("box", xform, size, material, draw_range)


## Цилиндр: size.x — диаметр, size.y — высота.
func cylinder(xform: Transform3D, size: Vector3, material: Material, draw_range: float = 0.0) -> void:
	add("cylinder", xform, size, material, draw_range)


## range_begin > 0 — фигура видна только издалека (упрощённые дома вместо детальных).
## shadow: -1 — тень, если фигура видна всегда; иначе значение GeometryInstance3D.ShadowCastingSetting.
func add(shape: String, xform: Transform3D, size: Vector3, material: Material, draw_range: float,
		range_begin: float = 0.0, shadow: int = -1) -> void:
	var chunk := Vector2i(floori(xform.origin.x / CHUNK), floori(xform.origin.z / CHUNK))
	var key := [shape, material, chunk, draw_range, range_begin, shadow]
	if not _batches.has(key):
		_batches[key] = []
	_batches[key].append(Transform3D(xform.basis * Basis.from_scale(size), xform.origin))


## draw_range > 0 — дальше этого фигуры не рисуются и не дают тени.
func flush(parent: Node3D, node_name: String) -> void:
	for key: Array in _batches:
		var transforms: Array = _batches[key]
		var mesh := (_shapes[key[0]] as PrimitiveMesh).duplicate() as PrimitiveMesh
		mesh.material = key[1]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = transforms.size()
		for k in transforms.size():
			mm.set_instance_transform(k, transforms[k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = node_name
		mmi.multimesh = mm
		var draw_range: float = key[3]
		var range_begin: float = key[4]
		var shadow: int = key[5]
		if draw_range > 0.0:
			mmi.visibility_range_end = draw_range
			mmi.visibility_range_end_margin = 15.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if range_begin > 0.0:
			mmi.visibility_range_begin = range_begin
			mmi.visibility_range_begin_margin = 30.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if shadow >= 0:
			mmi.cast_shadow = shadow as GeometryInstance3D.ShadowCastingSetting
		parent.add_child(mmi)
	_batches.clear()
