extends NavigationRegion3D

@export var is_game_level_ready = false
@export var level_generator : ProceduralDungeon
var players_placed: bool = false
@onready var world_environment: WorldEnvironment = %WorldEnvironment

func _ready() -> void:
	is_game_level_ready = false
	players_placed = false
	GameManager._game_level = self
	level_generator.generate_dungeon()
	await level_generator.level_generated
	bake_navigation_mesh()
	await bake_finished
	is_game_level_ready = true


func _process(delta: float) -> void:
	if Input.is_key_label_pressed(KEY_G) and Input.is_key_label_pressed(KEY_Z) and Input.is_key_label_pressed(KEY_M):
		toggle_cheat_environment()

var is_dark_env = true
var cheat_env_cooldown = false
func toggle_cheat_environment():
	if cheat_env_cooldown:
		return
	is_dark_env = !is_dark_env
	if is_dark_env:
		world_environment.environment = load('res://game_darkness_environment.tres')
	else:
		world_environment.environment = load('res://game_light_environment.tres')
	cheat_env_cooldown = true
	await get_tree().create_timer(0.2).timeout
	cheat_env_cooldown = false
