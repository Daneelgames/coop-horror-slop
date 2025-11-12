extends Unit
class_name AiCharacter
@export var visual_node_3d : Node3D
@export var visible_enemies : Array[Unit] = []
@export var input_dir : Vector2
@export var random_weapons_paths : Array[StringName]
var state = 'normal'
@export var rotation_speed: float = 5.0  # How fast the AI rotates towards enemies
@export var debug_ai_combat : bool = true  # Enable debug prints for AI combat
@export var attack_range_multiplier : float = 2.5  # Multiplier for weapon_active_distance to account for character reach
@export var blocking_range_multiplier : float = 3.5  # Multiplier for enemy weapon range when checking if should block (larger than attack range)
@onready var navigation_agent_3d: NavigationAgent3D = %NavigationAgent3D

@onready var weapon_bone_attachment_3d: BoneAttachment3D = %WeaponBoneAttachment3D

func _enter_tree():
	# Set multiplayer authority to server (peer ID 1) for AI characters
	if multiplayer.has_multiplayer_peer():
		set_multiplayer_authority(1, true)

func _ready():
	# Wait a frame to ensure node is fully ready and synced across all clients
	await get_tree().process_frame
	spawn_random_weapon_to_hands()
	
	# Register this AI character with the visibility manager
	if GameManager.ai_visibility_manager:
		GameManager.ai_visibility_manager.register_ai_character(self)
	super._ready()

func _physics_process(_delta): # Most things happen here. 
	visual_node_3d.global_position = visual_node_3d.global_position.lerp(global_position, 10 * _delta)
	# Convert Euler angles to Basis (quaternion) for proper rotation interpolation
	var current_basis = Basis.from_euler(visual_node_3d.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * _delta)
	visual_node_3d.global_rotation = slerped_basis.get_euler()
	if mesh_animation_player:
		play_mesh_animation(input_dir, true, state)
	if is_dead() == false and is_attacking == false and is_taking_damage == false and is_stun_lock == false and is_blocking_react == false and is_blocking == false:
		handle_attacking()
		handle_blocking()
	handle_rotation_towards_enemy(_delta)

func _exit_tree():
	# Unregister this AI character from the visibility manager when removed
	if GameManager.ai_visibility_manager:
		GameManager.ai_visibility_manager.unregister_ai_character(self)

func spawn_random_weapon_to_hands():
	# Only server picks the random weapon to ensure synchronization
	if multiplayer.is_server():
		if random_weapons_paths.is_empty():
			return
		var weapon_index = randi() % random_weapons_paths.size()
		var weapon_path = random_weapons_paths[weapon_index]
		# Pass weapon path string instead of index for better synchronization
		rpc_spawn_weapon.rpc(weapon_path)
	else:
		# If not server and not in multiplayer, spawn locally (for testing)
		if not multiplayer.has_multiplayer_peer():
			if random_weapons_paths.is_empty():
				return
			var weapon_index = randi() % random_weapons_paths.size()
			var weapon_path = random_weapons_paths[weapon_index]
			_spawn_weapon(weapon_path)

@rpc("authority", "call_local", "reliable")
func rpc_spawn_weapon(weapon_path: String):
	_spawn_weapon(weapon_path)

func _spawn_weapon(weapon_path: String):
	# Ensure weapon_bone_attachment_3d is ready
	if not is_node_ready() or weapon_bone_attachment_3d == null:
		await ready
		if weapon_bone_attachment_3d == null:
			push_error("weapon_bone_attachment_3d is not available")
			return
	
	# Remove existing weapon if any
	if item_in_hands != null:
		item_in_hands.queue_free()
		item_in_hands = null
	
	# Validate weapon path
	if weapon_path == null or weapon_path == "":
		return
	
	# Load and instantiate weapon
	var weapon_scene = load(weapon_path)
	if weapon_scene == null:
		push_error("Failed to load weapon scene: " + str(weapon_path))
		return
	
	item_in_hands = weapon_scene.instantiate()
	if item_in_hands == null or not item_in_hands is Weapon:
		push_error("Failed to instantiate weapon or not a Weapon class: " + str(weapon_path))
		if item_in_hands != null:
			item_in_hands.queue_free()
			item_in_hands = null
		return
	
	# Add weapon to bone attachment
	weapon_bone_attachment_3d.add_child(item_in_hands)
	item_in_hands.position = item_in_hands.weapon_slot_position
	item_in_hands.scale = Vector3.ONE * 100

#region Input Handling
func handle_attacking():
	if debug_ai_combat:
		print("[AI_ATTACK] %s: handle_attacking called" % name)
	
	if is_attacking or is_blocking or is_dead() or is_taking_damage:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: Blocked - is_attacking=%s, is_blocking=%s, is_dead=%s, is_taking_damage=%s" % [name, is_attacking, is_blocking, is_dead(), is_taking_damage])
		return
	
	# Only attack on server
	if not multiplayer.is_server():
		if debug_ai_combat:
			print("[AI_ATTACK] %s: Not server, skipping" % name)
		return
	
	# Need a weapon to attack
	if item_in_hands == null:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: No weapon in hands" % name)
		return
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Has weapon, weapon_active_distance=%s" % [name, item_in_hands.weapon_active_distance])
	
	# Find closest visible enemy
	var closest_enemy = _get_closest_visible_enemy()
	if closest_enemy == null:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: No closest visible enemy (visible_enemies.size=%s)" % [name, visible_enemies.size()])
		return
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Found closest enemy: %s" % [name, closest_enemy.name])
	
	# Check if enemy is within weapon attack range
	var distance = global_position.distance_to(closest_enemy.global_position)
	var effective_attack_range = item_in_hands.weapon_active_distance * attack_range_multiplier
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Distance to enemy=%s, weapon_range=%s, effective_range=%s" % [name, distance, item_in_hands.weapon_active_distance, effective_attack_range])
	
	if distance <= effective_attack_range:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: ATTACKING! Distance %s <= effective_range %s" % [name, distance, effective_attack_range])
		rpc_start_attacking.rpc()
	else:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: Too far - Distance %s > effective_range %s" % [name, distance, effective_attack_range])

@rpc("call_local", "reliable")
func rpc_start_attacking():
	if is_attacking:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: Already attacking, skipping" % name)
		return
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Starting attack!" % name)
	
	is_attacking = true
	
	# Choose attack animation similar to character.gd
	var attack_string = ''
	if input_dir.y != 0:
		attack_string = 'attack_vertical'
	elif input_dir.x != 0:
		attack_string = 'attack_horizontal'
	else:
		attack_string = ['attack_vertical', 'attack_horizontal'].pick_random()
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Playing attack animation: %s" % [name, attack_string])
	
	mesh_animation_player.play(attack_string, 0.1)
	if item_in_hands and multiplayer.is_server():
		item_in_hands.set_dangerous(true, self)
	await mesh_animation_player.animation_finished
	if item_in_hands and multiplayer.is_server():
		item_in_hands.set_dangerous(false, self)
	is_attacking = false
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Attack finished" % name)

func handle_blocking():
	if debug_ai_combat:
		print("[AI_BLOCK] %s: handle_blocking called" % name)
	
	if is_blocking or is_attacking or is_dead() or is_taking_damage:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Blocked - is_blocking=%s, is_attacking=%s, is_dead=%s, is_taking_damage=%s" % [name, is_blocking, is_attacking, is_dead(), is_taking_damage])
		return
	
	# Only block on server
	if not multiplayer.is_server():
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Not server, skipping" % name)
		return
	
	# Find closest visible enemy
	var closest_enemy = _get_closest_visible_enemy()
	if closest_enemy == null:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: No closest visible enemy" % name)
		return
	
	if debug_ai_combat:
		print("[AI_BLOCK] %s: Found closest enemy: %s, is_attacking=%s" % [name, closest_enemy.name, closest_enemy.is_attacking])
	
	# Only block if enemy is attacking and within their weapon range
	if not closest_enemy.is_attacking:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Enemy not attacking" % name)
		return
	
	# Check if enemy has a weapon
	if closest_enemy.item_in_hands == null:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Enemy has no weapon" % name)
		return
	
	# Check if distance is around enemy's weapon active distance
	var distance = global_position.distance_to(closest_enemy.global_position)
	var enemy_weapon_range = closest_enemy.item_in_hands.weapon_active_distance
	var enemy_effective_blocking_range = enemy_weapon_range * blocking_range_multiplier
	
	if debug_ai_combat:
		print("[AI_BLOCK] %s: Distance to enemy=%s, enemy_weapon_range=%s, enemy_effective_blocking_range=%s" % [name, distance, enemy_weapon_range, enemy_effective_blocking_range])
	
	if distance <= enemy_effective_blocking_range:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: BLOCKING! Distance %s <= enemy effective_blocking_range %s" % [name, distance, enemy_effective_blocking_range])
		# Use RPC to sync animation across all clients
		rpc_start_blocking.rpc()
	else:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Too far - Distance %s > enemy effective_blocking_range %s" % [name, distance, enemy_effective_blocking_range])

@rpc("call_local", "reliable")
func rpc_start_blocking():
	if is_blocking:
		if debug_ai_combat:
			print("[AI_BLOCK] %s: Already blocking, skipping" % name)
		return
	
	if debug_ai_combat:
		print("[AI_BLOCK] %s: Starting block!" % name)
	
	is_blocking = true
	mesh_animation_player.play('block', 0.1)
	await mesh_animation_player.animation_finished
	is_blocking = false
	
	if debug_ai_combat:
		print("[AI_BLOCK] %s: Block finished" % name)

func handle_rotation_towards_enemy(delta: float) -> void:
	# Only rotate on server
	if not multiplayer.is_server():
		return
	
	# Don't rotate if dead, attacking, or taking damage
	if is_dead() or is_attacking or is_taking_damage:
		return
	
	# Find closest visible enemy
	var closest_enemy = _get_closest_visible_enemy()
	if closest_enemy == null:
		return
	
	# Calculate direction to enemy
	var enemy_pos = closest_enemy.global_position
	var my_pos = global_position
	
	# Calculate direction vector (ignore Y for horizontal rotation)
	var direction = Vector3(my_pos.x - enemy_pos.x, 0, my_pos.z - enemy_pos.z)
	if direction.length_squared() < 0.0001:
		return  # Too close or same position
	
	direction = direction.normalized()
	
	# Calculate target rotation angle
	var target_angle = atan2(direction.x, direction.z)
	
	# Smoothly rotate towards target angle
	var current_angle = rotation.y
	var new_angle = lerp_angle(current_angle, target_angle, rotation_speed * delta)
	rotation.y = new_angle

func _get_closest_visible_enemy() -> Unit:
	if visible_enemies.is_empty():
		return null
	
	var closest_enemy: Unit = null
	var closest_distance_squared: float = INF
	
	for enemy in visible_enemies:
		if not is_instance_valid(enemy) or enemy.is_dead():
			continue
		
		var distance_squared = global_position.distance_squared_to(enemy.global_position)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			closest_enemy = enemy
	
	return closest_enemy
	
