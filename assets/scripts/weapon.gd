extends Node3D
class_name Weapon
@export var damage_min_max : Vector2i = Vector2i(30,60)
@export var attack_points : Array[Node3D]
@export var weapon_slot_position : Vector3

var attack_points_prev_positions : Array[Vector3]
var is_dangerous = false
var weapon_owner : Unit = null
var hit_objects_this_attack = []

func set_dangerous(isdngrs, wpnownr):
	if multiplayer.is_server() == false:
		return
	hit_objects_this_attack = []
	weapon_owner = wpnownr
	attack_points_prev_positions = []
	for point in attack_points:
		attack_points_prev_positions.append(point.global_position)
	is_dangerous = isdngrs
	

func _physics_process(_delta: float) -> void:
	if multiplayer.is_server() == false:
		return
	if not is_dangerous:
		# Update positions even when not dangerous
		attack_points_prev_positions = []
		for point in attack_points:
			attack_points_prev_positions.append(point.global_position)
		return
	
	for i in attack_points.size():
		var point = attack_points[i].global_position
		var prev_point = attack_points_prev_positions[i]
		var result = melee_raycast(point, prev_point)
		if result != null:
			# Handle hit - result is a dictionary with collision info
			_handle_melee_hit(result)

	attack_points_prev_positions = []
	for point in attack_points:
		attack_points_prev_positions.append(point.global_position)

func melee_raycast(point: Vector3, prev_point: Vector3):
	if multiplayer.is_server() == false:
		return
		
	if not is_dangerous:
		return null
	
	if weapon_owner == null:
		return null
	
	# Calculate direction and distance
	var direction = point - prev_point
	var distance_squared = direction.length_squared()
	
	# Skip if weapon hasn't moved enough (0.001^2 = 0.000001)
	if distance_squared < 0.000001:
		return null
	
	direction = direction.normalized()
	
	# Create space state for raycast
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(prev_point, point)
	
	# Set collision layers: layer 1 (solids) and layer 2 (units)
	# In Godot, layers are 1-indexed in editor but 0-indexed in code
	# Layer 1 = bit 0, Layer 2 = bit 1
	query.collision_mask = (1 << 0) | (1 << 1)  # layers 1 and 2
	
	# Exclude weapon owner (CharacterBody3D has get_rid())
	var exclude: Array[RID] = []
	if weapon_owner:
		var owner_rid = weapon_owner.get_rid()
		if owner_rid:
			exclude.append(owner_rid)
	
	# Exclude weapon's RigidBody3D children if any (for pickup weapons)
	for child in get_children():
		if child is RigidBody3D:
			var child_rid = child.get_rid()
			if child_rid:
				exclude.append(child_rid)
	
	query.exclude = exclude
	
	# Perform raycast
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		return null
	
	# Return hit information dictionary with keys:
	# - position: Vector3 (hit point)
	# - normal: Vector3 (surface normal)
	# - collider: Object (hit object)
	# - collider_id: RID
	# - rid: RID
	return result

func _handle_melee_hit(hit_result: Dictionary):
	# Process the melee hit
	var collider = hit_result.get("collider")
	if collider == null:
		return
	if hit_objects_this_attack.has(collider):
		return
	# Check if we hit a Unit (player/enemy)
	if collider is Unit:
		var hit_unit = collider as Unit
		# Don't hit the weapon owner
		if hit_unit == weapon_owner:
			return
		# TODO: Apply damage or other effects to hit_unit
		print("[MELEE HIT] Hit unit: ", hit_unit.name, " at position: ", hit_result.get("position"))
		hit_unit.rpc_take_damage(randi_range(damage_min_max.x,damage_min_max.y))
	else:
		# Hit a solid object
		print("[MELEE HIT] Hit solid object: ", collider.name, " at position: ", hit_result.get("position"))
		
	hit_objects_this_attack.append(collider)
