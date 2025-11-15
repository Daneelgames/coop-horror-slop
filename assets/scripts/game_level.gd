extends NavigationRegion3D

@export var is_game_level_ready = false
@export var level_generator : ProceduralDungeon
var players_placed: bool = false

func _ready() -> void:
	is_game_level_ready = false
	players_placed = false
	GameManager._game_level = self
	level_generator.generate_dungeon()
	await level_generator.level_generated
	bake_navigation_mesh()
	await bake_finished
	is_game_level_ready = true
