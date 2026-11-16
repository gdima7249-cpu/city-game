class_name DayNight
extends Node
## Смена дня и ночи: солнце ходит по небу, цвет неба, свет и туман меняются,
## ночью светит луна, загораются окна, вывески и фонари.
## Часы — в правом верхнем углу. Зажмите T, чтобы время шло быстрее.

@export var sun_path: NodePath = ^"../Sun"
@export var environment_path: NodePath = ^"../WorldEnvironment"
@export_range(0.0, 24.0) var start_hour: float = 10.0
@export var day_minutes: float = 24.0  ## Сколько реальных минут длятся игровые сутки
@export var fast_forward: float = 60.0 ## Во сколько раз быстрее идёт время, пока зажата T

const SUNRISE := 6.0
const SUNSET := 20.0
const MAX_ELEVATION := 62.0

const SKY_TOP_DAY := Color(0.3, 0.55, 0.88)
const SKY_TOP_NIGHT := Color(0.03, 0.05, 0.12)
const HORIZON_DAY := Color(0.78, 0.84, 0.9)
const HORIZON_DUSK := Color(0.98, 0.58, 0.32)
const HORIZON_NIGHT := Color(0.08, 0.08, 0.11)
const FOG_DAY := Color(0.8, 0.84, 0.9)
const FOG_NIGHT := Color(0.06, 0.07, 0.11)
const AMBIENT_DAY := Color(0.66, 0.64, 0.6)
const AMBIENT_NIGHT := Color(0.17, 0.17, 0.2)

var hour := 10.0

var _sun: DirectionalLight3D
var _env: Environment
var _sky: ProceduralSkyMaterial
var _label: Label
var _last_night := -1.0


func _ready() -> void:
	hour = start_hour
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	var world := get_node_or_null(environment_path) as WorldEnvironment
	if world != null:
		_env = world.environment
		if _env != null and _env.sky != null:
			_sky = _env.sky.sky_material as ProceduralSkyMaterial
	_build_clock()
	_apply()


func _process(delta: float) -> void:
	var speed := 24.0 / maxf(day_minutes * 60.0, 1.0)
	if InputMap.has_action("time_skip") and Input.is_action_pressed("time_skip"):
		speed *= fast_forward
	hour = fposmod(hour + delta * speed, 24.0)
	_apply()


## Высота солнца над горизонтом в градусах (ночью отрицательная).
func sun_elevation() -> float:
	if hour >= SUNRISE and hour <= SUNSET:
		return sin((hour - SUNRISE) / (SUNSET - SUNRISE) * PI) * MAX_ELEVATION
	var night_length := 24.0 - (SUNSET - SUNRISE)
	var t := fposmod(hour - SUNSET, 24.0) / night_length
	return -sin(t * PI) * 30.0


func _apply() -> void:
	var elevation := sun_elevation()
	var daylight := smoothstep(-4.0, 12.0, elevation)  # 0 ночью, 1 днём
	var dusk := clampf(1.0 - absf(elevation - 3.0) / 14.0, 0.0, 1.0) # закат и рассвет
	var night := 1.0 - smoothstep(-2.0, 7.0, elevation)

	if _sun != null:
		if elevation > -1.0:
			# Солнце: с востока (утро) на запад (вечер)
			var t := clampf((hour - SUNRISE) / (SUNSET - SUNRISE), 0.0, 1.0)
			var azimuth := deg_to_rad(lerpf(-110.0, 110.0, t))
			_sun.rotation = Vector3(-deg_to_rad(maxf(elevation, 1.0)), azimuth, 0.0)
			_sun.light_color = Color(1.0, 0.96, 0.9).lerp(Color(1.0, 0.62, 0.35), dusk)
			_sun.light_energy = 0.95 * daylight
		else:
			# Луна
			_sun.rotation = Vector3(-deg_to_rad(40.0), deg_to_rad(30.0), 0.0)
			_sun.light_color = Color(0.86, 0.88, 0.95)
			_sun.light_energy = 0.07

	if _sky != null:
		_sky.sky_top_color = SKY_TOP_NIGHT.lerp(SKY_TOP_DAY, daylight)
		var horizon := HORIZON_NIGHT.lerp(HORIZON_DAY, daylight).lerp(HORIZON_DUSK, dusk * 0.8)
		_sky.sky_horizon_color = horizon
		# Низ неба того же цвета, что дымка у горизонта: за краем земли нет серой полосы
		_sky.ground_horizon_color = horizon
		_sky.ground_bottom_color = horizon.darkened(0.1)
	if _env != null:
		_env.ambient_light_color = AMBIENT_NIGHT.lerp(AMBIENT_DAY, daylight)
		_env.ambient_light_energy = lerpf(0.35, 0.7, daylight)
		_env.fog_light_color = FOG_NIGHT.lerp(FOG_DAY, daylight).lerp(HORIZON_DUSK.darkened(0.2), dusk * 0.5)
		_env.tonemap_exposure = lerpf(1.35, 0.85, daylight)

	if absf(night - _last_night) > 0.01 or (night == 0.0) != (_last_night == 0.0):
		_last_night = night
		NightLights.set_amount(night, get_tree())

	if _label != null:
		_label.text = "%02d:%02d" % [int(hour), int(fmod(hour, 1.0) * 60.0)]


func _build_clock() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.anchor_left = 1.0
	_label.anchor_right = 1.0
	_label.offset_left = -200.0
	_label.offset_right = -24.0
	_label.offset_top = 12.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", 30)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_label)
	var hint := Label.new()
	hint.anchor_left = 1.0
	hint.anchor_right = 1.0
	hint.offset_left = -300.0
	hint.offset_right = -24.0
	hint.offset_top = 52.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.text = "T — ускорить время"
	hint.add_theme_color_override("font_color", Color.WHITE)
	hint.add_theme_color_override("font_outline_color", Color.BLACK)
	hint.add_theme_constant_override("outline_size", 4)
	layer.add_child(hint)
