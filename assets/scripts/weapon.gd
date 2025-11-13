extends Node3D
class_name Weapon
@export var weapon_resource : ResourceWeapon
@export var attack_points : Array[Node3D]
@export var weapon_slot_position : Vector3
var weapon_active_distance : float = 0
var attack_points_prev_positions : Array[Vector3]
var is_dangerous = false
var weapon_owner : Unit = null
var hit_objects_this_attack = []
var time_since_set_dangerous : float = 0.0
var time_to_actual_dangerous : float = 0.2

func _ready() -> void:
	weapon_active_distance = attack_points[0].global_position.distance_to(attack_points.back().global_position) * 100

func set_dangerous(isdngrs, wpnownr):
	if multiplayer.is_server() == false:
		return
	time_since_set_dangerous = 0.0
	hit_objects_this_attack = []
	weapon_owner = wpnownr
	attack_points_prev_positions = []
	for point in attack_points:
		attack_points_prev_positions.append(point.global_position)
	is_dangerous = isdngrs
	

func _physics_process(_delta: float) -> void:
	if multiplayer.is_server() == false:
		return
	
	# Debug: Check conditions for durability reduction
	if weapon_resource == null:
		return
	
	if is_dangerous and (weapon_owner.is_dead() or weapon_owner.is_blocking or weapon_owner.is_taking_damage or weapon_owner.is_blocking_react or weapon_owner.is_stun_lock):
		is_dangerous = false
	
	var should_reduce = weapon_owner is PlayerCharacter and weapon_resource.reducing_durability_when_in_hands
	
	# Debug output when conditions are met
	if should_reduce:
		var old_durability = weapon_resource.weapon_durability_current
		var reduction_amount = weapon_resource.in_hands_reduce_durability_speed * _delta
		
		# Multiply by delta to make it frame-rate independent (durability per second)
		weapon_resource.weapon_durability_current -= reduction_amount
		weapon_resource.weapon_durability_current = max(0.0, weapon_resource.weapon_durability_current)
		
		# Sync durability to clients when it changes (every frame for smooth updates)
		# Only sync if durability actually changed
		if abs(old_durability - weapon_resource.weapon_durability_current) > 0.001:
			if weapon_owner is PlayerCharacter:
				weapon_owner.rpc_sync_weapon_durability.rpc(weapon_resource.weapon_durability_current)
		
		# Detailed debug output every frame (can be throttled if too verbose)
		# var owner_name = "null"
		# if weapon_owner != null:
		# 	owner_name = str(weapon_owner.name)
		# var durability_percent = 0.0
		# if weapon_resource.weapon_durability_max > 0:
		# 	durability_percent = weapon_resource.weapon_durability_current / weapon_resource.weapon_durability_max * 100.0
		# print("[WEAPON DURABILITY] %s | Owner: %s | Delta: %.4f | Speed: %.2f/sec | Reduction: %.4f | %.2f -> %.2f (%.1f%%)" % [
		# 	str(weapon_resource.weapon_name),
		# 	owner_name,
		# 	_delta,
		# 	weapon_resource.in_hands_reduce_durability_speed,
		# 	reduction_amount,
		# 	old_durability,
		# 	weapon_resource.weapon_durability_current,
		# 	durability_percent
		# ])
		
		if weapon_resource.weapon_durability_current <= 0:
			print("[WEAPON BROKE] %s durability reached 0! Calling weapon_broke()" % weapon_resource.weapon_name)
			weapon_broke()
			return
	elif weapon_owner is PlayerCharacter:
		#print("cant reduce durability, weapon_resource.reducing_durability_when_in_hands is false")
		pass
		
	if not is_dangerous:
		# Update positions even when not dangerous
		attack_points_prev_positions = []
		for point in attack_points:
			attack_points_prev_positions.append(point.global_position)
		return

	if time_since_set_dangerous < time_to_actual_dangerous:
		time_since_set_dangerous += _delta
		return

	for i in attack_points.size():
		var point = attack_points[i].global_position
		var prev_point = attack_points_prev_positions[i]
		var result = melee_raycast(point, prev_point)
		if result != null:
			# Handle hit - result is a dictionary with collision info
			_handle_melee_hit(result, prev_point, point)

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
	if weapon_owner.is_dead():
		is_dangerous = false
		return
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

func _handle_melee_hit(hit_result: Dictionary, prev_point, point):
	# Process the melee hit
	var collider = hit_result.get("collider")
	if collider == null:
		return
	if hit_objects_this_attack.has(collider):
		return
	var hit_position = hit_result['position']
	var owner_position = weapon_owner.global_position
	# Check if we hit a Unit (player/enemy)
	if collider is Unit:
		var hit_unit = collider as Unit
		# Don't hit the weapon owner
		if hit_unit == weapon_owner:
			return
		# TODO: Apply damage or other effects to hit_unit
		print("[MELEE HIT] Hit unit: ", hit_unit.name, " at position: ", hit_result.get("position"))
		# if attack_was_blocked(hit_unit, hit_position) == false:
		if attack_was_blocked(hit_unit, owner_position) == false:
			hit_unit.rpc_take_damage.rpc(randi_range(weapon_resource.damage_min_max.x,weapon_resource.damage_min_max.y))
			var danger_direction = point.direction_to(prev_point)
			GameManager.particles_manager.spawn_blood_hit_particle.rpc(hit_position + hit_position.direction_to(owner_position) * 0.2, danger_direction)
		else:
			hit_unit.rpc_take_attack_blocked.rpc()
			weapon_owner.rpc_stun_lock_on_blocked_attack.rpc()
			GameManager.particles_manager.spawn_solid_hit_particle.rpc(hit_position + hit_position.direction_to(owner_position) * 0.2)
			weapon_owner.rpc_play_hit_solid.rpc()
	else:
		# Hit a solid object
		print("[MELEE HIT] Hit solid object: ", collider.name, " at position: ", hit_result.get("position"))
		GameManager.particles_manager.spawn_solid_hit_particle.rpc(hit_position + hit_position.direction_to(owner_position) * 0.2)
		weapon_owner.rpc_play_hit_solid.rpc()
		
	hit_objects_this_attack.append(collider)

func attack_was_blocked(attack_target, hit_pos):
	if attack_target is Unit and attack_target.is_blocking:
		# Calculate direction from target to hit position
		var target_pos = attack_target.global_position
		var attack_direction = (hit_pos - target_pos).normalized()
		
		# Target's forward direction (negative Z is forward in Godot)
		var target_forward = -attack_target.basis.z.normalized()
		
		# Calculate angle between forward direction and attack direction
		var angle_rad = target_forward.angle_to(attack_direction)
		var angle_deg = rad_to_deg(angle_rad)
		
		# If target has a weapon (PlayerCharacter), check blocking angle
		if attack_target.item_in_hands != null:
			var item_in_hands = attack_target.item_in_hands
			# weapon_blocking_angle is the total arc (e.g., 160 = 80 degrees on each side)
			if angle_deg <= item_in_hands.weapon_resource.weapon_blocking_angle / 2.0:
				return true
		else:
			# For units without weapons (like AI), allow blocking from front hemisphere
			# Default blocking angle: 180 degrees total (90 degrees on each side)
			var blocking_angle = 180.0
			if angle_deg <= blocking_angle / 2.0:
				return true
	return false

func weapon_broke():
	# this is used for when torch is out of fuel - weapon should be destroyed, and should be removed from weapon_owner item_in_hands and carrying_items
	# make sure this gets synced across all clients
	# Only server should process this logic
	if multiplayer.is_server() == false:
		return
	
	if weapon_owner == null:
		queue_free()
		return
	
	# Only PlayerCharacter has carrying_items
	if not weapon_owner is PlayerCharacter:
		# For non-player characters (like AI), use RPC to destroy weapon on all clients
		if weapon_owner.item_in_hands == self:
			var weapon_path = get_path()
			weapon_owner.rpc_destroy_weapon.rpc(weapon_path)
			weapon_owner.item_in_hands = null
		else:
			queue_free()
		return
	
	var player_owner = weapon_owner as PlayerCharacter
	
	# Find the matching item in carrying_items
	# Since the weapon is currently in hands, it should be the selected item
	var item_keys = player_owner.carrying_items.keys()
	var item_key_to_remove = null
	
	# Check if current selected item matches
	if item_keys.size() > player_owner.current_selected_item_index and player_owner.current_selected_item_index >= 0:
		var selected_key = item_keys[player_owner.current_selected_item_index]
		var selected_resource = player_owner.carrying_items[selected_key]
		# Compare by weapon_name and weapon_type to find the match
		if selected_resource != null and selected_resource.weapon_name == weapon_resource.weapon_name and selected_resource.weapon_type == weapon_resource.weapon_type:
			item_key_to_remove = selected_key
	
	# If not found by selected index, search all items
	if item_key_to_remove == null:
		for key in item_keys:
			var resource = player_owner.carrying_items[key]
			if resource != null and resource.weapon_name == weapon_resource.weapon_name and resource.weapon_type == weapon_resource.weapon_type:
				item_key_to_remove = key
				break
	
	# Remove from carrying_items if found
	if item_key_to_remove != null:
		player_owner.carrying_items.erase(item_key_to_remove)
	
	# Clamp selected index
	player_owner._clamp_selected_index()
	
	# Update inventory UI
	if player_owner.inventory_slots_panel_container:
		player_owner.inventory_slots_panel_container.update_inventory_items_ui(player_owner.carrying_items, player_owner.current_selected_item_index)
	
	# Update item in hands for all clients (this will also free the old weapon on all clients)
	var new_item_keys = player_owner.carrying_items.keys()
	if new_item_keys.size() > player_owner.current_selected_item_index and player_owner.current_selected_item_index >= 0:
		var selected_item_resource = player_owner.carrying_items[new_item_keys[player_owner.current_selected_item_index]]
		var selected_weapon_data = GameManager.serialize_weapon_resource(selected_item_resource)
		player_owner.rpc_update_item_in_hands.rpc(player_owner.current_selected_item_index, selected_weapon_data)
	else:
		player_owner.rpc_update_item_in_hands.rpc(-1, {})  # No item selected - this will free the weapon on all clients
	
	# Update inventory on owner's client if not server
	if player_owner.get_multiplayer_authority() != 1:  # Owner is not server
		var owner_peer_id = player_owner.get_multiplayer_authority()
		# Serialize inventory dictionary for RPC
		var serialized_inventory: Dictionary = {}
		for key in player_owner.carrying_items.keys():
			serialized_inventory[key] = GameManager.serialize_weapon_resource(player_owner.carrying_items[key])
		player_owner.rpc_update_inventory.rpc_id(owner_peer_id, serialized_inventory)
	
	# Note: Don't call queue_free() or clear item_in_hands here - rpc_update_item_in_hands already handles 
	# freeing the weapon and clearing item_in_hands on all clients
