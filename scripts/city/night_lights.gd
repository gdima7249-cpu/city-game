class_name NightLights
extends RefCounted
## Всё, что светится ночью: окна, вывески, плафоны фонарей и сами фонари.
##
## Материалы регистрируются здесь вместе с яркостью, которую они дают в полной
## темноте. Смена дня и ночи (day_night.gd) вызывает set_amount(): 0 — день,
## 1 — ночь, и вся подсветка города плавно включается или гаснет.
## Источники света (OmniLight3D) кладутся в группу GROUP.

const GROUP := &"night_lights"

static var amount := 0.0
static var _materials: Array[StandardMaterial3D] = []
static var _energies: Array[float] = []
static var _shaders: Array[ShaderMaterial] = []
static var _shader_energies: Array[float] = []


## Забыть старые материалы (город построен заново).
static func clear() -> void:
	_materials.clear()
	_energies.clear()
	_shaders.clear()
	_shader_energies.clear()


## Материал будет светиться ночью с яркостью energy.
static func register(material: StandardMaterial3D, energy: float) -> void:
	material.emission_enabled = true
	if material.emission == Color(0, 0, 0, 1):
		material.emission = material.albedo_color
	material.emission_energy_multiplier = energy * amount
	_materials.append(material)
	_energies.append(energy)


## То же для шейдера с параметром night_energy.
static func register_shader(material: ShaderMaterial, energy: float) -> void:
	material.set_shader_parameter("night_energy", energy * amount)
	_shaders.append(material)
	_shader_energies.append(energy)


## Насколько сейчас темно: 0 — день, 1 — ночь.
static func set_amount(value: float, tree: SceneTree) -> void:
	amount = clampf(value, 0.0, 1.0)
	for k in _materials.size():
		_materials[k].emission_energy_multiplier = _energies[k] * amount
	for k in _shaders.size():
		_shaders[k].set_shader_parameter("night_energy", _shader_energies[k] * amount)
	for node in tree.get_nodes_in_group(GROUP):
		var light := node as Light3D
		if light == null:
			continue
		light.visible = amount > 0.05
		light.light_energy = float(light.get_meta("energy", 1.0)) * amount


## Светящийся материал (вывеска, плафон, огонёк), сразу зарегистрированный.
static func glowing(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission = color
	m.roughness = 0.5
	register(m, energy)
	return m
