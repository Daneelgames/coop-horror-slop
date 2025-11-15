extends Unit
class_name AiCharacter
@export var visual_node_3d : Node3D
@export var visible_enemies : Array[Unit] = []
@export var input_dir : Vector2
@export var random_weapons : Array[ResourceWeapon]
var state = 'normal'
@export var rotation_speed: float = 5.0  # How fast the AI rotates towards enemies
@export var debug_ai_combat : bool = true  # Enable debug prints for AI combat
@export var attack_range_multiplier : float = 2.5  # Multiplier for weapon_active_distance to account for character reach
@export var blocking_range_multiplier : float = 3.5  # Multiplier for enemy weapon range when checking if should block (larger than attack range)
@export var base_speed: float = 3.0  # Base movement speed for AI
@export var home_position: Vector3  # Home/spawn position for patrol
@export var patrol_from_home_distance_min_max: Vector2 = Vector2(5.0, 15.0)  # Min and max distance from home for patrol points
@export var combat_from_home_distance_max: float = 30
@export var combat_strafe_distance_max: float = 3.0  # Distance to maintain from enemy when circling in combat
@export var navigation_agent_3d: NavigationAgent3D

# Movement control
var movement_target: Vector3 = Vector3.ZERO
var should_move: bool = false

@onready var weapon_bone_attachment_3d: BoneAttachment3D = %WeaponBoneAttachment3D
@onready var ai_state_machine: AiStateMachine = %AiStateMachine

func _enter_tree():
	# Set multiplayer authority to server (peer ID 1) for AI characters
	if multiplayer.has_multiplayer_peer():
		set_multiplayer_authority(1, true)

func _ready():
	# Wait a frame to ensure node is fully ready and synced across all clients
	await get_tree().process_frame
	print("[AI_WEAPON_SPAWN] %s: Starting weapon spawn process (is_server: %s, has_multiplayer: %s)" % [name, multiplayer.is_server(), multiplayer.has_multiplayer_peer()])
	spawn_random_weapon_to_hands()
	
	# Set home position to current position if not already set
	if home_position == Vector3.ZERO:
		home_position = global_position
	
	# Initialize last position for client-side movement detection
	_last_position = global_position
	
	# Register this AI character with the visibility manager
	if GameManager.ai_visibility_manager:
		GameManager.ai_visibility_manager.register_ai_character(self)
	super._ready()

var _last_position: Vector3 = Vector3.ZERO
var _smoothed_input_dir: Vector2 = Vector2.ZERO

func _physics_process(_delta): # Most things happen here. 
	if GameManager._game_level.is_game_level_ready == false:
		return
	visual_node_3d.global_position = visual_node_3d.global_position.lerp(global_position, 10 * _delta)
	# Convert Euler angles to Basis (quaternion) for proper rotation interpolation
	var current_basis = Basis.from_euler(visual_node_3d.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * _delta)
	visual_node_3d.global_rotation = slerped_basis.get_euler()
	
	# Calculate input_dir for clients based on movement (for animation)
	if not multiplayer.is_server():
		# Calculate movement direction from position change
		var position_delta = global_position - _last_position
		var target_input_dir: Vector2
		
		# Use a larger threshold to prevent jitter from small position changes
		if position_delta.length_squared() > 0.001:  # Increased threshold
			# Normalize and convert to Vector2 for input_dir
			position_delta.y = 0  # Ignore vertical movement
			position_delta = position_delta.normalized()
			target_input_dir = Vector2(position_delta.x, position_delta.z)
		else:
			target_input_dir = Vector2.ZERO
		
		# Smooth the input_dir to prevent rapid changes
		_smoothed_input_dir = _smoothed_input_dir.lerp(target_input_dir, 10.0 * _delta)
		
		# Only update input_dir if change is significant enough
		if _smoothed_input_dir.length_squared() > 0.01:
			input_dir = _smoothed_input_dir.normalized()
		else:
			input_dir = Vector2.ZERO
		
		_last_position = global_position
	
	if mesh_animation_player:
		play_mesh_animation(input_dir, multiplayer.is_server(), state)
	
	# Handle movement using NavigationAgent3D (only on server)
	if multiplayer.is_server() and not is_dead():
		if should_move:
			_handle_movement(_delta)
		else:
			# Still need to apply gravity and move_and_slide even when not moving
			# (e.g., when attacking to apply push velocity)
			_handle_physics(_delta)
		_last_position = global_position

func _exit_tree():
	# Unregister this AI character from the visibility manager when removed
	if GameManager.ai_visibility_manager:
		GameManager.ai_visibility_manager.unregister_ai_character(self)

func spawn_random_weapon_to_hands():
	print("[AI_WEAPON_SPAWN] %s: spawn_random_weapon_to_hands called (is_server: %s, has_multiplayer: %s)" % [name, multiplayer.is_server(), multiplayer.has_multiplayer_peer()])
	print("[AI_WEAPON_SPAWN] %s: random_weapons array size: %d" % [name, random_weapons.size()])
	
	if random_weapons.is_empty():
		print("[AI_WEAPON_SPAWN] %s: ERROR - random_weapons array is empty!" % name)
		return
	
	# Use deterministic seed based on mob name and dungeon seed to ensure same weapon selection on all clients
	# Mob name format is "Mob_{x}_{y}_{z}_{index}" which is consistent across all peers
	# Combine dungeon_seed with name hash for more reliable determinism
	var name_hash = name.hash()
	var combined_seed = GameManager.dungeon_seed + name_hash
	var weapon_rng = RandomNumberGenerator.new()
	weapon_rng.seed = combined_seed
	
	# Pick weapon using seeded RNG (same result on all clients)
	var weapon_index = weapon_rng.randi() % random_weapons.size()
	var weapon = random_weapons[weapon_index]
	print("[AI_WEAPON_SPAWN] %s: Selected weapon index %d (seed: %d), weapon_resource: %s" % [name, weapon_index, combined_seed, weapon])
	
	if weapon == null:
		print("[AI_WEAPON_SPAWN] %s: ERROR - Selected weapon is null!" % name)
		return
	
	# Spawn weapon directly on all clients (no RPC needed since selection is deterministic)
	# This ensures all clients spawn the same weapon for the same mob
	_spawn_weapon(weapon)

@rpc("authority", "call_local", "reliable")
func rpc_spawn_weapon(weapon_data: Dictionary):
	print("[AI_WEAPON_SPAWN] %s: rpc_spawn_weapon RPC received (is_server: %s)" % [name, multiplayer.is_server()])
	# Deserialize weapon resource from data
	var weapon_resource = GameManager.deserialize_weapon_resource(weapon_data)
	if weapon_resource == null:
		print("[AI_WEAPON_SPAWN] %s: ERROR - Failed to deserialize weapon_resource from RPC!" % name)
		return
	_spawn_weapon(weapon_resource)


func _spawn_weapon(weapon_resource: ResourceWeapon):
	print("[AI_WEAPON_SPAWN] %s: _spawn_weapon called with weapon_resource: %s" % [name, weapon_resource])
	
	if weapon_resource == null:
		print("[AI_WEAPON_SPAWN] %s: ERROR - weapon_resource parameter is null!" % name)
		return
	
	# Ensure weapon_bone_attachment_3d is ready
	print("[AI_WEAPON_SPAWN] %s: Checking weapon_bone_attachment_3d (is_node_ready: %s, weapon_bone_attachment_3d: %s)" % [name, is_node_ready(), weapon_bone_attachment_3d])
	if not is_node_ready() or weapon_bone_attachment_3d == null:
		print("[AI_WEAPON_SPAWN] %s: Waiting for node to be ready..." % name)
		await ready
		if weapon_bone_attachment_3d == null:
			print("[AI_WEAPON_SPAWN] %s: ERROR - weapon_bone_attachment_3d is not available after ready!" % name)
			push_error("weapon_bone_attachment_3d is not available")
			return
	
	print("[AI_WEAPON_SPAWN] %s: weapon_bone_attachment_3d is ready: %s" % [name, weapon_bone_attachment_3d])
	
	# Remove existing weapon if any
	if item_in_hands != null:
		print("[AI_WEAPON_SPAWN] %s: Removing existing weapon: %s" % [name, item_in_hands])
		item_in_hands.queue_free()						
		item_in_hands = null
	
	# Validate weapon path
	print("[AI_WEAPON_SPAWN] %s: Checking weapon_prefab_path: '%s'" % [name, weapon_resource.weapon_prefab_path])
	if weapon_resource.weapon_prefab_path == null or weapon_resource.weapon_prefab_path == "":
		print("[AI_WEAPON_SPAWN] %s: ERROR - weapon_prefab_path is null or empty!" % name)
		return
	
	# Load and instantiate weapon
	print("[AI_WEAPON_SPAWN] %s: Loading weapon scene from path: %s" % [name, weapon_resource.weapon_prefab_path])
	var weapon_scene = load(weapon_resource.weapon_prefab_path)
	if weapon_scene == null:
		print("[AI_WEAPON_SPAWN] %s: ERROR - Failed to load weapon scene: %s" % [name, weapon_resource.weapon_prefab_path])
		push_error("Failed to load weapon scene: " + str(weapon_resource.weapon_prefab_path))
		return
	
	print("[AI_WEAPON_SPAWN] %s: Weapon scene loaded successfully, instantiating..." % name)
	item_in_hands = weapon_scene.instantiate()
	item_in_hands.weapon_owner = self
	if item_in_hands == null:
		print("[AI_WEAPON_SPAWN] %s: ERROR - Failed to instantiate weapon (item_in_hands is null)" % name)
		push_error("Failed to instantiate weapon or not a Weapon class: " + str(weapon_resource.weapon_prefab_path))
		return
	
	if not item_in_hands is Weapon:
		print("[AI_WEAPON_SPAWN] %s: ERROR - Instantiated object is not a Weapon class (type: %s)" % [name, item_in_hands.get_class()])
		push_error("Failed to instantiate weapon or not a Weapon class: " + str(weapon_resource.weapon_prefab_path))
		item_in_hands.queue_free()
		item_in_hands = null
		return
	
	print("[AI_WEAPON_SPAWN] %s: Weapon instantiated successfully: %s" % [name, item_in_hands])
	
	# Add weapon to bone attachment
	print("[AI_WEAPON_SPAWN] %s: Adding weapon to bone attachment..." % name)
	weapon_bone_attachment_3d.add_child(item_in_hands)
	
	if item_in_hands.weapon_resource == null:
		print("[AI_WEAPON_SPAWN] %s: WARNING - weapon.weapon_resource is null, setting from parameter" % name)
		item_in_hands.weapon_resource = weapon_resource.duplicate()
	else:
		print("[AI_WEAPON_SPAWN] %s: Duplicating existing weapon_resource..." % name)
		item_in_hands.weapon_resource = item_in_hands.weapon_resource.duplicate()
	
	item_in_hands.position = item_in_hands.weapon_slot_position
	item_in_hands.scale = Vector3.ONE * 100
	print("[AI_WEAPON_SPAWN] %s: SUCCESS - Weapon spawned and attached! (position: %s, scale: %s)" % [name, item_in_hands.position, item_in_hands.scale])

#region RPC Methods for Combat
# These RPC methods are called by the combat state to sync animations across clients
@rpc("call_local", "reliable")
func rpc_start_attacking():
	if is_attacking:
		if debug_ai_combat:
			print("[AI_ATTACK] %s: Already attacking, skipping" % name)
		return
	
	if debug_ai_combat:
		print("[AI_ATTACK] %s: Starting attack!" % name)
	
	is_attacking = true
	
	# Apply forward push when attacking (only on server)
	if multiplayer.is_server() and item_in_hands != null:
		var push_force = item_in_hands.weapon_resource.push_forward_on_attack_force
		if push_force > 0:
			# Get direction towards closest enemy (where AI is looking)
			var closest_enemy = _get_closest_visible_enemy()
			if closest_enemy != null:
				var direction_to_enemy = (closest_enemy.global_position - global_position).normalized()
				# Ignore Y component for horizontal push
				direction_to_enemy.y = 0
				direction_to_enemy = direction_to_enemy.normalized()
				velocity += direction_to_enemy * push_force
			else:
				# Fallback to forward direction if no enemy
				var forward_direction = -transform.basis.z.normalized()
				velocity += forward_direction * push_force
	
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
#endregion

#region Movement
## Set a movement target for the AI. States should call this to set where the AI should move.
func set_movement_target(target: Vector3):
	movement_target = target
	navigation_agent_3d.target_position = target
	should_move = true

## Stop movement. States can call this to stop the AI from moving.
func stop_movement():
	should_move = false
	velocity.x = 0
	velocity.z = 0
	input_dir = Vector2.ZERO

## Internal movement handler using NavigationAgent3D
func _handle_movement(delta: float):
	if navigation_agent_3d == null:
		return
	
	# Don't move if attacking, blocking, taking damage, or in stun lock
	# But still apply physics (gravity, move_and_slide) to preserve push velocity
	#if is_attacking or is_blocking or is_taking_damage or is_stun_lock or is_blocking_react:
	if is_attacking or is_taking_damage or is_stun_lock or is_blocking_react:
		_handle_physics(delta)
		return
	
	# Check if navigation is finished
	if navigation_agent_3d.is_navigation_finished():
		# Reached target, stop moving
		velocity.x = 0
		velocity.z = 0
		input_dir = Vector2.ZERO
		_handle_physics(delta)
		return
	
	# Get next path position from navigation agent
	var next_path_position = navigation_agent_3d.get_next_path_position()
	var current_agent_position = global_position
	
	# Calculate direction to next path position
	var direction = (next_path_position - current_agent_position).normalized()
	if is_blocking:
		velocity.x = 0
		velocity.z = 0
		input_dir = Vector2(0, 0)
	else:
		# Set velocity for movement
		velocity.x = direction.x * base_speed
		velocity.z = direction.z * base_speed
		input_dir = Vector2(direction.x, direction.z)
	
	# Apply physics (gravity and move_and_slide)
	_handle_physics(delta)
	
	# Rotate towards movement direction (but not if in combat - combat state handles rotation)
	# Check if we have visible enemies to determine if we're in combat
	var has_visible_enemies = false
	for enemy in visible_enemies:
		if is_instance_valid(enemy) and not enemy.is_dead():
			has_visible_enemies = true
			break
	
	# Only rotate towards movement if not in combat
	if not has_visible_enemies and direction.length_squared() > 0.0001:
		var target_angle = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_angle, rotation_speed * delta)

## Handle physics (gravity and movement) - called separately to preserve push velocity during attacks
func _handle_physics(delta: float):
	# Apply gravity
	var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0
	
	# Move the character (this applies any velocity including push from attacks)
	move_and_slide()
#endregion

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
	
@export var resurrect_after_death_seconds : float = -1

func death():
	super.death()
	if resurrect_after_death_seconds > 0:
		await get_tree().create_timer(resurrect_after_death_seconds).timeout
		# Only server can call this RPC since AI has server authority
		if multiplayer.is_server():
			rpc_full_heal_and_resurrect.rpc()
