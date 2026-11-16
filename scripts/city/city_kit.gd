class_name CityKit
extends RefCounted
## Модели пака Quaternius «Downtown City MegaKit» (CC0), папка assets/downtown.
##
## Одинаковые детали собираются в MultiMesh: тысячи окон и стен рисуются
## за несколько вызовов отрисовки, и игра не тормозит. Город делится на
## участки по CHUNK метров: участки за спиной камеры не рисуются вовсе,
## а мелочи (кондиционеры, двери, урны) не рисуются дальше SMALL_RANGE.
##
## Окна бывают двух видов: в части окон ночью горит свет (яркость
## WINDOW_LIT_ENERGY), в остальных темно — так ночной город выглядит живым.
## За стеклом — «комната» из шейдера shaders/window_interior.gdshader.

const PATH := "res://assets/downtown/%s.gltf"
const CHUNK := 80.0
const NEAR_RANGE := 220.0  ## Дальше этого вместо детальных стен — упрощённые дома (BuildingBuilder)
const GROUND_RANGE := 900.0 ## Тротуары видны далеко
const SMALL_RANGE := 160.0 ## Дальше этого не рисуются мелкие детали
const LIT_SHARE := 0.45    ## Доля окон, в которых ночью горит свет
const WINDOW_LIT_ENERGY := 1.6
const INTERIOR_MATERIAL := "MI_FakeInterior" ## Материал пака на месте комнаты за окном
const GLASS_MATERIAL := "MI_Glass"
const INTERIOR_SHADER := preload("res://shaders/window_interior.gdshader")

var rng := RandomNumberGenerator.new()

var _pieces := {}  # имя -> [Mesh, Transform3D, Mesh с горящими окнами или null] или []
var _batches := {} # [имя, участок, горит] -> Array[Transform3D]
var _interiors: Array[ShaderMaterial] = [null, null] # [тёмные, горящие ночью]
var _glass_material: StandardMaterial3D


static func available() -> bool:
	return ResourceLoader.exists(PATH % "Building_Small_1")


## Плитка тротуара и разметка: плоские, видны далеко.
static func is_ground(piece_name: String) -> bool:
	return piece_name.begins_with("Sidewalk_") or piece_name.begins_with("Street_")


## Мелкая деталь: не рисуется издалека и не отбрасывает тень.
static func is_small(piece_name: String) -> bool:
	return piece_name.begins_with("Prop_") or piece_name.begins_with("Door_") \
			or piece_name.begins_with("Decal_")


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
	var lit: bool = p[2] != null and rng.randf() < LIT_SHARE
	var chunk := Vector2i(floori(xform.origin.x / CHUNK), floori(xform.origin.z / CHUNK))
	var key := [piece_name, chunk, lit]
	if not _batches.has(key):
		_batches[key] = []
	_batches[key].append(xform * (p[1] as Transform3D))


## Создать MultiMesh для всех поставленных деталей.
func flush(parent: Node3D) -> void:
	for key: Array in _batches:
		var piece_name: String = key[0]
		var lit: bool = key[2]
		var transforms: Array = _batches[key]
		var p := _piece(piece_name)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = p[2] if lit else p[0]
		mm.instance_count = transforms.size()
		for k in transforms.size():
			mm.set_instance_transform(k, transforms[k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Kit_%s_%d_%d%s" % [piece_name, key[1].x, key[1].y, "_lit" if lit else ""]
		mmi.multimesh = mm
		# Тени от стен дают упрощённые коробки домов, поэтому сами детали тень не отбрасывают
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		if is_small(piece_name):
			mmi.visibility_range_end = SMALL_RANGE
			mmi.visibility_range_end_margin = 20.0
		elif is_ground(piece_name):
			mmi.visibility_range_end = GROUND_RANGE
		else:
			mmi.visibility_range_end = NEAR_RANGE
			mmi.visibility_range_end_margin = 30.0
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
			var base: Mesh = _window_variant(mesh_node.mesh, false)
			if base == null:
				base = mesh_node.mesh
			result = [base, _relative_transform(root, mesh_node), _window_variant(mesh_node.mesh, true)]
		root.free()
	else:
		push_warning("Нет модели: " + piece_name)
	_pieces[piece_name] = result
	return result


## Копия модели с нашими материалами окон: «комната за окном» вместо серой
## заливки и светлое стекло. lit — эта копия ночью светится.
## null — в модели нет окон (тогда для lit копия не нужна).
func _window_variant(mesh: Mesh, lit: bool) -> Mesh:
	var array_mesh := mesh as ArrayMesh
	if array_mesh == null:
		return null
	var has_interior := false
	var has_glass := false
	for s in array_mesh.get_surface_count():
		var m := array_mesh.surface_get_material(s)
		if m != null and m.resource_name.begins_with(INTERIOR_MATERIAL):
			has_interior = true
		if m != null and m.resource_name.begins_with(GLASS_MATERIAL):
			has_glass = true
	# Стекло меняем только там, где за ним есть комната; сплошь остеклённые
	# стены оставляем тёмными, иначе дом выглядит прозрачным
	if not has_interior:
		return null
	var copy := array_mesh.duplicate() as ArrayMesh
	for s in copy.get_surface_count():
		var m := copy.surface_get_material(s)
		if m == null:
			continue
		if m.resource_name.begins_with(INTERIOR_MATERIAL):
			copy.surface_set_material(s, _interior(lit))
		elif m.resource_name.begins_with(GLASS_MATERIAL):
			copy.surface_set_material(s, _glass())
	return copy


func _interior(lit: bool) -> ShaderMaterial:
	var index := 1 if lit else 0
	if _interiors[index] == null:
		var m := ShaderMaterial.new()
		m.shader = INTERIOR_SHADER
		m.set_shader_parameter("lit", 1.0 if lit else 0.0)
		NightLights.register_shader(m, WINDOW_LIT_ENERGY)
		_interiors[index] = m
	return _interiors[index]


## Стекло: светлее, чем в паке, с бликом неба, чтобы было видно комнату.
func _glass() -> StandardMaterial3D:
	if _glass_material == null:
		_glass_material = StandardMaterial3D.new()
		_glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glass_material.albedo_color = Color(0.5, 0.6, 0.68, 0.16)
		_glass_material.metallic = 0.0
		_glass_material.roughness = 0.05
	return _glass_material


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
