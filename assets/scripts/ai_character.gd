extends Unit
class_name AiCharacter
@export var input_dir : Vector2
var state = 'normal'
 
func _physics_process(delta): # Most things happen here.
	if mesh_animation_player:
		play_mesh_animation(input_dir, true, state)
