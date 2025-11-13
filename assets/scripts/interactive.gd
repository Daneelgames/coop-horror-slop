extends RigidBody3D
class_name Interactive

@export var weapon_resource : ResourceWeapon
@onready var visual_parent: Node3D = %VisualParent

func _ready() -> void:
	if weapon_resource:
		weapon_resource = weapon_resource.duplicate()

func _process(delta: float) -> void:
	visual_parent.global_position = visual_parent.global_position.lerp(global_position, 10 * delta)
	var current_basis = Basis.from_euler(visual_parent.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * delta)
	visual_parent.global_rotation = slerped_basis.get_euler()
	
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
