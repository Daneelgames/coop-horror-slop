extends RigidBody3D
class_name Interactive

@export var prefab_path_pickup : StringName
@export var prefab_path_weapon : StringName
@export var interactive_name := &"Weapon"

func activate_rigidbody_collisions():
	set_collision_layer_value(3, true)
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, true)
	freeze = false
	
func deactivate_rigidbody_collisions():
	set_collision_layer_value(3, false)
	set_collision_mask_value(1, false)
	set_collision_mask_value(2, false)
	freeze = true
