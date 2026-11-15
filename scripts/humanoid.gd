class_name Humanoid
extends Node3D
## Человечек из паков Quaternius (Universal Base Characters + Universal Animation Library).
## Один и тот же скелет у всех персонажей, поэтому анимации из библиотеки подходят любому.
##
## Использование: var h := Humanoid.create(variant); if h: add_child(h); h.play("Walk")
## Если файлов моделей нет — create() вернёт null, и вызывающий код оставит заглушку.

## Модели персонажей. Добавьте сюда новые .gltf с тем же скелетом — они сразу появятся в игре.
const CHARACTERS: Array[String] = [
	"res://assets/people/characters/Superhero_Male_FullBody.gltf",
	"res://assets/people/characters/Superhero_Female_FullBody.gltf",
]
const ANIMATIONS := "res://assets/people/UAL1_Standard.glb"

static var _library: AnimationLibrary

var anim: AnimationPlayer
var _current := ""


static func available() -> bool:
	return ResourceLoader.exists(CHARACTERS[0]) and ResourceLoader.exists(ANIMATIONS)


static func create(variant: int = 0) -> Humanoid:
	if not available():
		return null
	var path := CHARACTERS[posmod(variant, CHARACTERS.size())]
	var scene := load(path) as PackedScene
	var lib := _get_library()
	if scene == null or lib == null:
		return null
	var h := Humanoid.new()
	var model := scene.instantiate()
	# В glTF персонаж смотрит в +Z, а у нас «вперёд» — это -Z.
	model.rotation.y = PI
	h.add_child(model)
	h.anim = AnimationPlayer.new()
	h.anim.name = "AnimationPlayer"
	model.add_child(h.anim)
	h.anim.root_node = NodePath("..")
	h.anim.add_animation_library("", lib)
	return h


static func _get_library() -> AnimationLibrary:
	if _library != null:
		return _library
	var scene := load(ANIMATIONS) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate()
	var src := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if src != null:
		_library = src.get_animation_library("")
		# Библиотека живёт дальше, а сцену-носитель можно освободить.
		src.remove_animation_library("")
	inst.queue_free()
	return _library


## Включить анимацию (если она уже играет — не перезапускать).
func play(anim_name: String, speed: float = 1.0, blend: float = 0.2) -> void:
	if anim == null or not anim.has_animation(anim_name):
		return
	anim.speed_scale = speed
	if _current == anim_name:
		return
	_current = anim_name
	anim.play(anim_name, blend)
