extends Unit
class_name AiArmsMob
@export var visual_node_3d: Node3D
@export var arms_animation_players : Array[AnimationPlayer]

func _ready():
	for anim in arms_animation_players:
		anim.play('Move')
		anim.seek(randf_range(0, anim.current_animation.length()))
		
func _physics_process(_delta): # Most things happen here.
	if GameManager._game_level.is_game_level_ready == false:
		return
	super._physics_process(_delta)
	visual_node_3d.global_position = visual_node_3d.global_position.lerp(global_position, 10 * _delta)
	# Convert Euler angles to Basis (quaternion) for proper rotation interpolation
	var current_basis = Basis.from_euler(visual_node_3d.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * _delta)
	visual_node_3d.global_rotation = slerped_basis.get_euler()
	velocity = get_gravity()
