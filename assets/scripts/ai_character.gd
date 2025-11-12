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
@export var base_speed: float = 3.0  # Base movement speed for AI
@export var home_position: Vector3  # Home/spawn position for patrol
@export var patrol_from_home_distance_min_max: Vector2 = Vector2(5.0, 15.0)  # Min and max distance from home for patrol points
@export var combat_from_home_distance_max: float = 30
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
	spawn_random_weapon_to_hands()
	
	# Set home position to current position if not already set
	if home_position == Vector3.ZERO:
		home_position = global_position
	
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
	
	# Handle movement using NavigationAgent3D (only on server)
	if multiplayer.is_server() and should_move and not is_dead():
		_handle_movement(_delta)

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
	if is_attacking or is_blocking or is_taking_damage or is_stun_lock or is_blocking_react:
		return
	
	# Check if navigation is finished
	if navigation_agent_3d.is_navigation_finished():
		# Reached target, stop moving
		velocity.x = 0
		velocity.z = 0
		input_dir = Vector2.ZERO
		return
	
	# Get next path position from navigation agent
	var next_path_position = navigation_agent_3d.get_next_path_position()
	var current_agent_position = global_position
	
	# Calculate direction to next path position
	var direction = (next_path_position - current_agent_position).normalized()
	
	# Set velocity for movement
	velocity.x = direction.x * base_speed
	velocity.z = direction.z * base_speed
	
	# Apply gravity
	var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0
	
	# Move the character
	move_and_slide()
	
	# Update input_dir for animation
	input_dir = Vector2(direction.x, direction.z)
	
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
