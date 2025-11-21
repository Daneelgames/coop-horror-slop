extends Unit
class_name AiArmsMob
@export var visual_node_3d: Node3D
@export var arms_animation_players : Array[AnimationPlayer]

func _ready():
	for anim in arms_animation_players:
		anim.play('Move')
		anim.seek(randf_range(0, anim.current_animation.length()))
