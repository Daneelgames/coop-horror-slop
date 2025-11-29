@tool
extends Path3D

@export var distance_between_planks = 1.0:
	set(value):
		distance_between_planks = value
		is_dirty = true
@export var local_y_rotation_degrees = 0.0:
	set(value):
		local_y_rotation_degrees = value
		is_dirty = true
@export var upd = false:
	set(value):
		upd = false
		_update_multimesh()
	
var is_dirty = false

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if is_dirty:
		_update_multimesh()

		is_dirty = false

func _update_multimesh():
	var path_length: float = curve.get_baked_length()
	var count = floor(path_length / distance_between_planks)

	var mm: MultiMesh = $MultiMeshInstance3D.multimesh
	mm.instance_count = count
	var offset = distance_between_planks/2.0

	for i in range(0, count):
		var curve_distance = offset + distance_between_planks * i
		var position = curve.sample_baked(curve_distance, true)

		var basis = Basis()
		
		var up = curve.sample_baked_up_vector(curve_distance, true)
		var forward = position.direction_to(curve.sample_baked(curve_distance + 0.1, true))

		basis.y = up
		basis.x = forward.cross(up).normalized()
		basis.z = -forward

		# Apply local Y rotation
		basis = basis.rotated(basis.y, deg_to_rad(local_y_rotation_degrees))

		var transform = Transform3D(basis, position)
		mm.set_instance_transform(i, transform)


func _on_curve_changed():
	is_dirty = true
