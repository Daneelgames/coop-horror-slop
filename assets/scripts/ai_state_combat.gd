extends AiState
class_name AiStateCombat

# try moving around closest enemy, changing target offset to enemy from time to time
# also this state should handle blocking and attacking 

var ai_character: AiCharacter
var movement_target_update_timer: float = 0.0
var movement_target_update_interval: float = 1.0  # Update movement target every second
var current_target_offset_angle: float = 0.0  # Current angle offset around enemy

func _ready():
	# Get reference to AI character (state -> state machine -> ai character)
	ai_character = get_parent().get_parent() as AiCharacter
	if ai_character == null:
		push_error("AiStateCombat: Could not find AiCharacter parent")

func enter_state():
	# When entering combat, initialize movement
	if ai_character:
		movement_target_update_timer = 0.0
		current_target_offset_angle = randf() * TAU  # Random starting angle

func exit_state():
	# When exiting combat, clear movement
	if ai_character:
		ai_character.stop_movement()

func _physics_process(_delta):
	if ai_character == null:
		return
	
	# Only process combat logic if character is alive and not in other states
	if ai_character.is_dead() == false and ai_character.is_attacking == false and ai_character.is_taking_damage == false and ai_character.is_stun_lock == false and ai_character.is_blocking_react == false and ai_character.is_blocking == false:
		handle_movement_target(_delta)
		handle_attacking()
		handle_blocking()
		handle_rotation_towards_enemy(_delta)

func handle_attacking():
	if ai_character.debug_ai_combat:
		print("[AI_ATTACK] %s: handle_attacking called" % ai_character.name)
	
	if ai_character.is_attacking or ai_character.is_blocking or ai_character.is_dead() or ai_character.is_taking_damage:
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: Blocked - is_attacking=%s, is_blocking=%s, is_dead=%s, is_taking_damage=%s" % [ai_character.name, ai_character.is_attacking, ai_character.is_blocking, ai_character.is_dead(), ai_character.is_taking_damage])
		return
	
	# Only attack on server
	if not multiplayer.is_server():
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: Not server, skipping" % ai_character.name)
		return
	
	# Need a weapon to attack
	if ai_character.item_in_hands == null:
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: No weapon in hands" % ai_character.name)
		return
	
	if ai_character.debug_ai_combat:
		print("[AI_ATTACK] %s: Has weapon, weapon_active_distance=%s" % [ai_character.name, ai_character.item_in_hands.weapon_active_distance])
	
	# Find closest visible enemy
	var closest_enemy = ai_character._get_closest_visible_enemy()
	if closest_enemy == null:
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: No closest visible enemy (visible_enemies.size=%s)" % [ai_character.name, ai_character.visible_enemies.size()])
		return
	
	if ai_character.debug_ai_combat:
		print("[AI_ATTACK] %s: Found closest enemy: %s" % [ai_character.name, closest_enemy.name])
	
	# Check if enemy is within weapon attack range
	var distance = ai_character.global_position.distance_to(closest_enemy.global_position)
	var effective_attack_range = ai_character.item_in_hands.weapon_active_distance * ai_character.attack_range_multiplier
	if ai_character.debug_ai_combat:
		print("[AI_ATTACK] %s: Distance to enemy=%s, weapon_range=%s, effective_range=%s" % [ai_character.name, distance, ai_character.item_in_hands.weapon_active_distance, effective_attack_range])
	
	if distance <= effective_attack_range:
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: ATTACKING! Distance %s <= effective_range %s" % [ai_character.name, distance, effective_attack_range])
		ai_character.rpc_start_attacking.rpc()
	else:
		if ai_character.debug_ai_combat:
			print("[AI_ATTACK] %s: Too far - Distance %s > effective_range %s" % [ai_character.name, distance, effective_attack_range])

func handle_blocking():
	if ai_character.debug_ai_combat:
		print("[AI_BLOCK] %s: handle_blocking called" % ai_character.name)
	
	if ai_character.is_blocking or ai_character.is_attacking or ai_character.is_dead() or ai_character.is_taking_damage:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: Blocked - is_blocking=%s, is_attacking=%s, is_dead=%s, is_taking_damage=%s" % [ai_character.name, ai_character.is_blocking, ai_character.is_attacking, ai_character.is_dead(), ai_character.is_taking_damage])
		return
	
	# Only block on server
	if not multiplayer.is_server():
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: Not server, skipping" % ai_character.name)
		return
	
	# Find closest visible enemy
	var closest_enemy = ai_character._get_closest_visible_enemy()
	if closest_enemy == null:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: No closest visible enemy" % ai_character.name)
		return
	
	if ai_character.debug_ai_combat:
		print("[AI_BLOCK] %s: Found closest enemy: %s, is_attacking=%s" % [ai_character.name, closest_enemy.name, closest_enemy.is_attacking])
	
	# Only block if enemy is attacking and within their weapon range
	if not closest_enemy.is_attacking:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: Enemy not attacking" % ai_character.name)
		return
	
	# Check if enemy has a weapon
	if closest_enemy.item_in_hands == null:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: Enemy has no weapon" % ai_character.name)
		return
	
	# Check if distance is around enemy's weapon active distance
	var distance = ai_character.global_position.distance_to(closest_enemy.global_position)
	var enemy_weapon_range = closest_enemy.item_in_hands.weapon_active_distance
	var enemy_effective_blocking_range = enemy_weapon_range * ai_character.blocking_range_multiplier
	
	if ai_character.debug_ai_combat:
		print("[AI_BLOCK] %s: Distance to enemy=%s, enemy_weapon_range=%s, enemy_effective_blocking_range=%s" % [ai_character.name, distance, enemy_weapon_range, enemy_effective_blocking_range])
	
	if distance <= enemy_effective_blocking_range:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: BLOCKING! Distance %s <= enemy effective_blocking_range %s" % [ai_character.name, distance, enemy_effective_blocking_range])
		# Use RPC to sync animation across all clients
		ai_character.rpc_start_blocking.rpc()
	else:
		if ai_character.debug_ai_combat:
			print("[AI_BLOCK] %s: Too far - Distance %s > enemy effective_blocking_range %s" % [ai_character.name, distance, enemy_effective_blocking_range])

func handle_movement_target(delta: float):
	# Only update movement on server
	if not multiplayer.is_server():
		return
	
	# Find closest visible enemy
	var closest_enemy = ai_character._get_closest_visible_enemy()
	if closest_enemy == null:
		return
	
	# Check distance from home
	var distance_from_home = ai_character.global_position.distance_to(ai_character.home_position)
	var max_combat_distance = ai_character.combat_from_home_distance_max
	
	# If outside combat range from home, move back towards home
	if distance_from_home > max_combat_distance:
		# Calculate direction back to home
		var direction_to_home = (ai_character.home_position - ai_character.global_position).normalized()
		# Set target position slightly inside the combat range (90% of max range)
		var target_distance_from_home = max_combat_distance * 0.9
		# Position is at target_distance_from_home from home, along the direction from current to home
		var target_position = ai_character.home_position - direction_to_home * target_distance_from_home
		ai_character.set_movement_target(target_position)
		return
	
	# Update movement target periodically
	movement_target_update_timer += delta
	if movement_target_update_timer >= movement_target_update_interval:
		movement_target_update_timer = 0.0
		
		# Calculate position around enemy
		# Use a circular offset around the enemy
		var strafe_distance = ai_character.combat_strafe_distance_max  # Distance to maintain from enemy
		var enemy_pos = closest_enemy.global_position
		var my_pos = ai_character.global_position
		
		# Calculate angle to enemy
		var to_enemy = (enemy_pos - my_pos)
		var base_angle = atan2(to_enemy.x, to_enemy.z)
		
		# Add offset angle and rotate it slightly each time for circling
		current_target_offset_angle += deg_to_rad(45)  # Rotate 45 degrees each update
		if current_target_offset_angle >= TAU:
			current_target_offset_angle -= TAU
		
		# Calculate offset position around enemy
		var offset_x = cos(base_angle + current_target_offset_angle) * randf_range(strafe_distance * 0.1, strafe_distance)
		var offset_z = sin(base_angle + current_target_offset_angle) * randf_range(strafe_distance * 0.1, strafe_distance)
		var target_position = enemy_pos + Vector3(offset_x, 0, offset_z)
		
		# Ensure target is still within combat range from home
		var target_distance_from_home = target_position.distance_to(ai_character.home_position)
		if target_distance_from_home > max_combat_distance:
			# Clamp target to be within range
			var direction_from_home = (target_position - ai_character.home_position).normalized()
			target_position = ai_character.home_position + direction_from_home * max_combat_distance * 0.9
		
		# Set movement target
		ai_character.set_movement_target(target_position)

func handle_rotation_towards_enemy(delta: float) -> void:
	# Only rotate on server
	if not multiplayer.is_server():
		return
	
	# Don't rotate if dead, attacking, or taking damage
	if ai_character.is_dead() or ai_character.is_attacking or ai_character.is_taking_damage:
		return
	
	# Find closest visible enemy
	var closest_enemy = ai_character._get_closest_visible_enemy()
	if closest_enemy == null:
		return
	
	# Calculate direction to enemy
	var enemy_pos = closest_enemy.global_position
	var my_pos = ai_character.global_position
	
	# Calculate direction vector (ignore Y for horizontal rotation)
	var direction = Vector3(my_pos.x - enemy_pos.x, 0, my_pos.z - enemy_pos.z)
	if direction.length_squared() < 0.0001:
		return  # Too close or same position
	
	direction = direction.normalized()
	
	# Calculate target rotation angle
	var target_angle = atan2(direction.x, direction.z)
	
	# Smoothly rotate towards target angle
	var current_angle = ai_character.rotation.y
	var new_angle = lerp_angle(current_angle, target_angle, ai_character.rotation_speed * delta)
	ai_character.rotation.y = new_angle
