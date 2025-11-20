# COPYRIGHT Colormatic Studios
# MIT license
# Quality Godot First Person Controller v2


extends Unit
class_name PlayerCharacter

#region Character Export Group

## The settings for the character's movement and feel.
@export var carrying_items: Dictionary[StringName, ResourceWeapon] = {}
@export var inventory_slots_max: int = 5
@export var current_selected_item_index: int = 0
@onready var interaction_ray_cast_3d: RayCast3D = %InteractionRayCast3D
@export var vaulting_raycasts: Array[RayCast3D]
@onready var inventory_slots_panel_container: PlayerInventorySlotsPanelContainer = %InventorySlotsPanelContainer
@export_category("Character")
## The speed that the character moves at without crouching or sprinting.
@export var base_speed: float = 3.0
@export var crouch_speed: float = 1.0
## The speed that the character moves at when sprinting.
@export var sprint_speed: float = 6.0
@export var vaulting_threshold: float = 1.5

## How fast the character speeds up and slows down when Motion Smoothing is on.
@export var acceleration: float = 10.0
## How high the player jumps.
@export var jump_velocity: float = 4.5
## How far the player turns when the mouse is moved.
@export var mouse_sensitivity: float = 0.1
@export var camera_clamp: Vector2 = Vector2(-80, 80)
## How fast the camera rotation smooths (higher = faster). Set to 0 to disable smoothing.
@export var rotation_smoothing_speed: float = 20.0
## Invert the X axis input for the camera.
@export var invert_camera_x_axis: bool = false
## Invert the Y axis input for the camera.
@export var invert_camera_y_axis: bool = false
@export var fov_sprint: float = 80
@export var fov_idle: float = 50
## Whether the player can use movement inputs. Does not stop outside forces or jumping. See Jumping Enabled.
@export var immobile: bool = false
## The reticle file to import at runtime. By default are in res://addons/fpc/reticles/. Set to an empty string to remove.
@export_file var default_reticle

#endregion

#region Nodes Export Group

@export_group("Nodes")
## A reference to the camera for use in the character script. This is the parent node to the camera and is rotated instead of the camera for mouse input.
@export var HEAD: Node3D
## A reference to the camera for use in the character script.
@export var CAMERA: Camera3D
## A reference to the headbob animation for use in the character script.

@export var HEADBOB_ANIMATION: AnimationPlayer
## A reference to the jump animation for use in the character script.
@export var JUMP_ANIMATION: AnimationPlayer
## A reference to the the player's collision shape for use in the character script.
@export var COLLISION_MESH: CollisionShape3D
@export var visual_node_3d: Node3D
@export var skeleton_3d: Skeleton3D
#endregion

#region Controls Export Group
@export var head_height_idle = 1.5
@export var head_height_crouch = 1.0
@export var is_crouching = false
# We are using UI controls because they are built into Godot Engine so they can be used right away
@export_group("Controls")
## Use the Input Map to map a mouse/keyboard input to an action and add a reference to it to this dictionary to be used in the script.
@export var controls: Dictionary = {
	LEFT = "move_left",
	RIGHT = "move_right",
	FORWARD = "move_up",
	BACKWARD = "move_down",
	JUMP = "jump",
	CROUCH = "crouch",
	SPRINT = "sprint",
	PAUSE = "ui_cancel",
	INTERACTION = 'interaction',
	BLOCK = 'block',
	DROP_ITEM = 'drop_item'
	}
@export_subgroup("Controller Specific")
## This only affects how the camera is handled, the rest should be covered by adding controller inputs to the existing actions in the Input Map.
@export var controller_support: bool = false
## Use the Input Map to map a controller input to an action and add a reference to it to this dictionary to be used in the script.
@export var controller_controls: Dictionary = {
	LOOK_LEFT = "look_left",
	LOOK_RIGHT = "look_right",
	LOOK_UP = "look_up",
	LOOK_DOWN = "look_down"
	}
## The sensitivity of the analog stick that controls camera rotation. Lower is less sensitive and higher is more sensitive.
@export_range(0.001, 1, 0.001) var look_sensitivity: float = 0.035

#endregion

#region Feature Settings Export Group
@export_group("Feature Settings")
@export var collision_idle_height: float = 1.6
@export var collision_crouch_height: float = 1.0
## Enable or disable jumping. Useful for restrictive storytelling environments.
@export var jumping_enabled: bool = true
## Whether the player can move in the air or not.
@export var in_air_momentum: bool = true
## Smooths the feel of walking.
@export var motion_smoothing: bool = true
## Enables or disables sprinting.
@export var sprint_enabled: bool = true
## Toggles the sprinting state when button is pressed or requires the player to hold the button down to remain sprinting.
@export_enum("Hold to Sprint", "Toggle Sprint") var sprint_mode: int = 0
## Enables or disables crouching.
@export var crouch_enabled: bool = true
## Toggles the crouch state when button is pressed or requires the player to hold the button down to remain crouched.
@export_enum("Hold to Crouch", "Toggle Crouch") var crouch_mode: int = 0
## Wether sprinting should effect FOV.
@export var dynamic_fov: bool = true
## If the player holds down the jump button, should the player keep hopping.
@export var continuous_jumping: bool = true
## Enables the view bobbing animation.
@export var view_bobbing: bool = true
## Enables an immersive animation when the player jumps and hits the ground.
@export var jump_animation: bool = true
## This determines wether the player can use the pause button, not wether the game will actually pause.
@export var pausing_enabled: bool = true
## Use with caution.
@export var gravity_enabled: bool = true
## If your game changes the gravity value during gameplay, check this property to allow the player to experience the change in gravity.
@export var dynamic_gravity: bool = false

#endregion


@export var debug_authority: bool = true

#region Member Variable Initialization

# These are variables used in this script that don't need to be exposed in the editor.
var speed: float = base_speed
var current_speed: float = 0.0
# States: normal, sprinting, crouching
# CRITICAL: Must NOT be @export! State is synchronized ONLY via RPC calls (rpc_enter_crouch_state, etc)
# If @export is added, MultiplayerSynchronizer will sync it automatically, causing all players to share state
var state: String = "normal"
var low_ceiling: bool = false # This is for when the ceiling is too low and the player needs to crouch.
var was_on_floor: bool = true # Was the player on the floor last frame (for landing animation)
var attack_push_velocity: Vector3 = Vector3.ZERO # Store push velocity from attacks

# Vaulting 
var is_vaulting: bool = false
var vault_target_height: float = 0.0
var vault_target_pos: Vector3 = Vector3.ZERO
var vault_start_pos: Vector3 = Vector3.ZERO
var vault_progress: float = 0.0

# The reticle should always have a Control node as the root
var RETICLE: Control

# Get the gravity from the project settings to be synced with RigidBody nodes
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity") # Don't set this as a const, see the gravity section in _physics_process

# Stores mouse input for rotating the camera in the physics process
var mouseInput: Vector2 = Vector2(0, 0)

# Target rotations for smoothing
var target_head_rotation_x: float = 0.0
var target_character_rotation_y: float = 0.0

# Tracks whether this instance is allowed to process local player input.
var _has_input_authority: bool = false
var _debug_last_should_control: bool = false
var _debug_last_has_input: bool = false
var _debug_last_blocked_reason: String = ""
# Cached peer ID to avoid parsing name every frame
var _cached_peer_id: int = -1
# Cached local peer ID to avoid calling get_unique_id() every frame
var _cached_local_peer_id: int = -1

#endregion
@onready var dust_gpu_particles_3d: GPUParticles3D = %DustGPUParticles3D
var is_moving_by_elevator = false

#region Main Control Flow

func _enter_tree():
	# Set multiplayer authority on this node (recursively sets authority for child nodes including MultiplayerSynchronizer)
	if multiplayer.has_multiplayer_peer():
		# Extract peer ID from character name format: "Player_{peer_id}"
		var name_parts = name.split("_")
		if name_parts.size() >= 2:
			_cached_peer_id = name_parts[1].to_int()
			set_multiplayer_authority(_cached_peer_id, true)
			if debug_authority:
				_debug_print("Set multiplayer authority to %d in _enter_tree" % _cached_peer_id)
	call_deferred("_refresh_authority_state", true)


func _ready():
	_debug_print("Character ready, name=%s, multiplayer_peer=%s, debug_authority=%s" % [name, str(multiplayer.has_multiplayer_peer()), str(debug_authority)])

	# Cache local peer ID if in multiplayer
	if multiplayer.has_multiplayer_peer():
		_cached_local_peer_id = multiplayer.get_unique_id()
	
	# Register this character in GameManager._player_nodes
	# This ensures all clients have all players registered, not just the server
	_register_self_in_game_manager()

	for key in carrying_items.keys():
		carrying_items[key] = carrying_items[key].duplicate()

	# If the controller is rotated in a certain direction for game design purposes, redirect this rotation into the head.
	HEAD.rotation.y = rotation.y
	rotation.y = 0
	
	# Initialize target rotations to match current rotations
	target_head_rotation_x = HEAD.rotation.x
	target_character_rotation_y = rotation.y
	COLLISION_MESH.shape = COLLISION_MESH.shape.duplicate()
	initialize_animations()
	check_controls()
	enter_normal_state()

	if OS.get_name() == "Web":
		Input.set_use_accumulated_input(false)
	super._ready()
	if _has_input_authority == false:
		dust_gpu_particles_3d.emitting = false
		dust_gpu_particles_3d.visible = false

func _register_self_in_game_manager():
	# Ensure GameManager exists
	if not is_instance_valid(GameManager):
		push_warning("Character._register_self_in_game_manager: GameManager is not valid")
		return
	
	# Extract peer ID from character name format: "Player_{peer_id}"
	var name_parts = name.split("_")
	if name_parts.size() >= 2:
		var peer_id = name_parts[1].to_int()
		# Register this character in GameManager._player_nodes
		# This ensures all clients have all players, not just the server
		if not GameManager._player_nodes.has(peer_id):
			GameManager._player_nodes[peer_id] = self
			if debug_authority:
				_debug_print("Registered self in GameManager._player_nodes with peer_id=%d" % peer_id)
		elif GameManager._player_nodes[peer_id] != self:
			# Update if it's a different instance (shouldn't happen, but just in case)
			GameManager._player_nodes[peer_id] = self
			if debug_authority:
				_debug_print("Updated GameManager._player_nodes entry for peer_id=%d" % peer_id)
		else:
			# Already registered correctly
			if debug_authority:
				_debug_print("Already registered in GameManager._player_nodes with peer_id=%d" % peer_id)
	else:
		push_warning("Character._register_self_in_game_manager: Could not extract peer ID from name '%s'" % name)

@rpc("any_peer", "call_local", "reliable")
func rpc_teleport_to_position(position: Vector3):
	# Телепортировать игрока на указанную позицию
	# Эта функция вызывается сервером для всех клиентов через RPC
	# На клиентах она устанавливает позицию через RPC, предотвращая локальный оверрайд
	# Проверяем что вызывается только сервером (peer_id 1) или локально
	var sender_id = multiplayer.get_remote_sender_id()
	if multiplayer.has_multiplayer_peer() and sender_id != 0 and sender_id != 1:
		push_warning("rpc_teleport_to_position: Rejected RPC from non-server peer %d" % sender_id)
		return
	
	global_position = position
	# Также сбросить velocity чтобы предотвратить движение после телепортации
	# Character наследуется от Unit (CharacterBody3D), который имеет свойство velocity
	velocity = Vector3.ZERO
	var instance_type = "HOST" if multiplayer.is_server() else "CLIENT"
	var my_peer_id = multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0
	print("[%s] Character %s teleported to position %s [peer_id=%d, authority=%d, sender=%d]" % [
		instance_type,
		name,
		position,
		my_peer_id,
		get_multiplayer_authority(),
		sender_id
	])

func _process(_delta):
	if GameManager._game_level.is_game_level_ready == false:
		return
	cheat_codes()
	_ensure_authority_state()
	if !_has_input_authority:
		visual_node_3d.top_level = true
		visual_node_3d.global_position = visual_node_3d.global_position.lerp(global_position, 10 * _delta)
		visual_node_3d.global_rotation.y = lerp_angle(visual_node_3d.global_rotation.y, global_rotation.y, 10 * _delta)
		_debug_report_input_block("_process")
		return
	visual_node_3d.top_level = false
	visual_node_3d.global_position = global_position
	_debug_clear_block_reason("_process")
	if pausing_enabled:
		handle_pausing()

	update_debug_menu_per_frame()

@export var input_dir = Vector2.ZERO

func _physics_process(delta): # Most things happen here.
	if GameManager._game_level.is_game_level_ready == false:
		return
	super._physics_process(delta)
	_ensure_authority_state()
	#if mesh_animation_player and _has_input_authority:
	if mesh_animation_player:
		#print("[ANIMATION] %s: Calling play_mesh_animation - state='%s', has_input=%s, input_dir=%s" % [name, state, _has_input_authority, input_dir])
		play_mesh_animation(input_dir, _has_input_authority, state)
	if !_has_input_authority:
		return
	# Gravity
	if dynamic_gravity:
		gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
	if not is_on_floor() and gravity and gravity_enabled:
		velocity.y -= gravity * delta
	if is_moving_by_elevator == false and is_taking_damage == false and is_attacking == false and is_dead() == false and is_blocking == false and is_stun_lock == false and is_blocking_react == false:
	#if is_taking_damage == false and is_attacking == false and is_dead() == false and is_blocking == false and is_stun_lock == false and is_blocking_react == false:
		handle_attacking()
		handle_blocking()
		handle_crouching()
		handle_vaulting()
		handle_jumping()
		handle_interaction()
		handle_dropping_item()

	input_dir = Vector2.ZERO

	if is_moving_by_elevator == false:
		if not immobile and is_dead() == false and is_stun_lock == false and is_blocking == false and is_blocking_react == false and is_attacking == false:
			input_dir = Input.get_vector(controls.LEFT, controls.RIGHT, controls.FORWARD, controls.BACKWARD)

	#if not immobile and is_dead() == false and is_stun_lock == false and is_blocking == false and is_blocking_react == false and is_attacking == false:
		#input_dir = Input.get_vector(controls.LEFT, controls.RIGHT, controls.FORWARD, controls.BACKWARD)
			
	if is_vaulting:
		process_vault_climb(delta)
	elif is_moving_by_elevator == false:
		handle_movement(delta, input_dir)
	else:
		# Когда лифт движется, сбросить горизонтальную скорость чтобы предотвратить движение
		velocity.x = 0.0
		velocity.z = 0.0

	handle_head_rotation()
	apply_rotation_smoothing(delta)
	
	# Handle head height interpolation based on state
	# The state is synchronized via RPC, so this applies correctly to all characters
	var target_head_height = head_height_idle
	var target_collision_height = collision_idle_height
	if state == "crouching" and _has_input_authority:
		target_head_height = head_height_crouch
		target_collision_height = collision_crouch_height
	
	# Only modify HEAD for characters with input authority (camera is attached to HEAD)
	if _has_input_authority:
		HEAD.position.y = lerp(HEAD.position.y, target_head_height, 10 * delta)
	
	# Handle collision height interpolation for ALL characters based on their state
	if COLLISION_MESH and COLLISION_MESH.shape is CapsuleShape3D:
		var current_height = COLLISION_MESH.shape.height
		var new_height = lerp(current_height, target_collision_height, 10 * delta)
		COLLISION_MESH.shape.height = new_height
		COLLISION_MESH.position.y = new_height / 2.0

	# The player is not able to stand up if the ceiling is too low
	low_ceiling = $CrouchCeilingDetection.is_colliding()

	# Track state changes
	var prev_state = state
	handle_state(input_dir)
	if prev_state != state:
		print("[STATE CHANGE] %s: state changed from '%s' to '%s' (has_input=%s, authority=%d)" % [name, prev_state, state, _has_input_authority, get_multiplayer_authority()])
	if dynamic_fov and _has_input_authority: # This may be changed to an AnimationPlayer
		update_camera_fov()

	if view_bobbing and _has_input_authority:
		play_headbob_animation(input_dir)

	if jump_animation and _has_input_authority:
		play_jump_animation()


	update_debug_menu_per_tick()
	
	# Update inventory UI durability display if torch is losing durability
	if item_in_hands != null and item_in_hands.weapon_resource != null:
		if item_in_hands.weapon_resource.reducing_durability_when_in_hands:
			# Sync durability from item_in_hands back to carrying_items
			_sync_weapon_durability_to_inventory()
			# Update UI durability display
			if inventory_slots_panel_container:
				inventory_slots_panel_container.update_durability_display(carrying_items)

	was_on_floor = is_on_floor() # This must always be at the end of physics_process

#endregion

#region Input Handling
func handle_blocking():
	if is_blocking:
		return
	if Input.is_action_just_pressed(controls.BLOCK):
		rpc_block.rpc()

@rpc("call_local")
func rpc_block():
	if is_crouching:
		if !low_ceiling:
			enter_normal_state()
		else:
			return
	if is_blocking:
		return
	is_blocking = true
	mesh_animation_player.play('block', 0.1)
	await mesh_animation_player.animation_finished
	is_blocking = false
	
func handle_dropping_item():
	if !_has_input_authority:
		return
	if Input.is_action_just_pressed(controls.DROP_ITEM):
		rpc_drop_item.rpc(current_selected_item_index)


@rpc("authority", 'call_local', "reliable")
func rpc_drop_item(selected_item_index):
	# Get requesting peer ID - if called directly (server), use server's peer ID (1)
	var requesting_peer_id = multiplayer.get_unique_id()
	if multiplayer.get_remote_sender_id() != 0:
		requesting_peer_id = multiplayer.get_remote_sender_id()
	
	# Get the requesting player's character
	var root = get_tree().root
	var player_path = root.get_node_or_null("Main/GameRoot/Players/PlayerSpawner/Player_%d" % requesting_peer_id)
	var requesting_player = player_path
	
	if requesting_player == null:
		# Try searching all nodes for the player
		var all_players = get_tree().get_nodes_in_group("players")
		for player in all_players:
			if player.name == "Player_%d" % requesting_peer_id:
				requesting_player = player
				break
	
	if requesting_player == null:
		return
	
	# Only server processes inventory changes and validation
	if multiplayer.is_server():
		# Check if there's an item to drop
		var item_keys = requesting_player.carrying_items.keys()
		if item_keys.size() == 0 or selected_item_index < 0 or selected_item_index >= item_keys.size():
			return
		
		# Get the weapon resource from the selected item
		var item_key = item_keys[selected_item_index]
		var weapon_resource = requesting_player.carrying_items[item_key]
		
		if weapon_resource == null or weapon_resource.pickup_prefab_path == null or weapon_resource.pickup_prefab_path == "":
			return
		
		# Calculate drop position in front of player
		var drop_distance = 1.5 # Distance in front of player
		var forward_direction = - requesting_player.CAMERA.global_transform.basis.z # Forward is negative Z
		var drop_position = requesting_player.global_position + forward_direction * drop_distance
		drop_position.y = requesting_player.global_position.y + 0.5 # Slightly above ground
		
		# Check if drop position is inside a wall (layer 1 - solids)
		var space_state = requesting_player.get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(requesting_player.global_position, drop_position)
		# Check only layer 1 (solids) - bit 0
		query.collision_mask = (1 << 0) # layer 1 only
		var result = space_state.intersect_ray(query)
		if result:
			# Collision detected, can't drop here
			return
		
		# Serialize weapon resource for RPC
		var weapon_data = GameManager.serialize_weapon_resource(weapon_resource)
		
		# Tell all clients to spawn the pickup - must call from server's perspective
		# Call from requesting_player node so it broadcasts to all clients
		print("[DROP ITEM] Server spawning pickup at %s with weapon_data: %s" % [drop_position, weapon_data])
		requesting_player.rpc_spawn_dropped_pickup.rpc(drop_position, weapon_data)
		
		# Remove item from inventory
		requesting_player.carrying_items.erase(item_key)
		
		# Clamp selected index if needed
		requesting_player._clamp_selected_index()
		
		# Update inventory UI
		if requesting_player.inventory_slots_panel_container:
			requesting_player.inventory_slots_panel_container.update_inventory_items_ui(requesting_player.carrying_items, requesting_player.current_selected_item_index)
		
		# Update item in hands for all clients
		var new_item_keys = requesting_player.carrying_items.keys()
		if new_item_keys.size() > requesting_player.current_selected_item_index and requesting_player.current_selected_item_index >= 0:
			var selected_item_resource = requesting_player.carrying_items[new_item_keys[requesting_player.current_selected_item_index]]
			var selected_weapon_data = GameManager.serialize_weapon_resource(selected_item_resource)
			requesting_player.rpc_update_item_in_hands.rpc(requesting_player.current_selected_item_index, selected_weapon_data)
		else:
			requesting_player.rpc_update_item_in_hands.rpc(-1, {}) # No item selected
		
		# Update inventory on requesting client if not server
		if requesting_peer_id != 1:
			# Serialize inventory dictionary for RPC
			var serialized_inventory: Dictionary = {}
			for key in requesting_player.carrying_items.keys():
				serialized_inventory[key] = GameManager.serialize_weapon_resource(requesting_player.carrying_items[key])
			requesting_player.rpc_update_inventory.rpc_id(requesting_peer_id, serialized_inventory)

# Spawn dropped pickup using MultiplayerSpawner for synchronization
@rpc("any_peer", "call_local", "reliable")
func rpc_spawn_dropped_pickup(drop_position: Vector3, weapon_data: Dictionary):
	# Only server spawns pickups
	if not multiplayer.is_server():
		return
	
	print("[DROP ITEM] Server spawning pickup at %s" % drop_position)
	# Deserialize weapon resource from data
	var weapon_resource = GameManager.deserialize_weapon_resource(weapon_data)
	if weapon_resource == null:
		print("[DROP ITEM] Failed to deserialize weapon_resource!")
		return
	
	# Use GameManager's spawner to spawn the pickup (ensures synchronization)
	var game_root = GameManager._game_level
	if game_root == null:
		print("[DROP ITEM] ERROR: GameManager._game_level is null!")
		return
	
	var game_spawner = GameManager._game_spawner
	if game_spawner == null:
		print("[DROP ITEM] ERROR: GameManager._game_spawner is null!")
		return
	
	# Register the pickup prefab with the spawner
	# The spawn function should already be set in GameManager._ensure_game_spawner()
	var pickup_prefab_path = weapon_resource.pickup_prefab_path
	if pickup_prefab_path == null or pickup_prefab_path == "":
		print("[DROP ITEM] ERROR: pickup_prefab_path is empty!")
		return
	
	game_spawner.add_spawnable_scene(pickup_prefab_path)
	
	# Temporarily set spawn_path to GameLevel for dropped items
	# (procedurally spawned items use DungeonTiles)
	var original_spawn_path = game_spawner.spawn_path
	var game_level_path = game_spawner.get_path_to(game_root)
	if game_level_path == NodePath():
		print("[DROP ITEM] ERROR: Failed to get path to game_root!")
		return
	game_spawner.spawn_path = game_level_path
	
	# Spawn using MultiplayerSpawner - this ensures all clients get synchronized copies
	# Use string path directly - _spawn_game_object handles both String and Dictionary
	print("[DROP ITEM] Spawning pickup from path: %s" % pickup_prefab_path)
	
	# Spawn the pickup - MultiplayerSpawner will call _spawn_game_object
	# The spawn function creates it with a name like "Pickup_%d_%d" which is consistent across clients
	var pickup_instance = game_spawner.spawn(pickup_prefab_path)
	
	# Restore original spawn_path immediately after spawn
	game_spawner.spawn_path = original_spawn_path
	
	if pickup_instance == null:
		print("[DROP ITEM] ERROR: spawn() returned null!")
		return
	
	if not pickup_instance is InteractivePickup:
		print("[DROP ITEM] ERROR: Spawned object is not InteractivePickup! Type: %s" % pickup_instance.get_class())
		return
	
	var pickup = pickup_instance as InteractivePickup
	
	# Configure pickup properties
	pickup.weapon_resource = weapon_resource.duplicate()
	pickup.global_position = drop_position
	pickup.set_multiplayer_authority(1)
	pickup.snap_visual()
	
	# Don't rename - use the name that was set during spawn (Pickup_%d_%d)
	# This name is consistent across all clients because it's set before the object is added to scene tree
	print("[DROP ITEM] Pickup spawned successfully: %s at %s" % [pickup.name, drop_position])

@onready var interaction_feedback_label_3d: Label3D = %InteractionFeedbackLabel3D

func handle_interaction():
	if !_has_input_authority:
		return
		
	if !interaction_ray_cast_3d.is_colliding():
		interaction_feedback_label_3d.visible = false
		return
		
	var col = interaction_ray_cast_3d.get_collider()
	if is_instance_valid(col) == false:
		return
	
	if col is InteractivePickup:
		if col.weapon_resource:
			interaction_feedback_label_3d.text = col.weapon_resource.weapon_name
		else:
			interaction_feedback_label_3d.text = 'INTERACT'
		interaction_feedback_label_3d.visible = true
		interaction_feedback_label_3d.global_position = interaction_ray_cast_3d.get_collision_point()
			
		if Input.is_action_just_pressed(controls.INTERACTION):
			# Use GameManager to avoid path resolution issues
			# The pickup name might not be synchronized yet, so we use the current name
			# GameManager will search for the pickup by name in multiple locations
			# Also pass pickup position as fallback for better matching
			var pickup_name = col.name
			var pickup_position = col.global_position
			if multiplayer.is_server():
				# Server can call directly through GameManager
				if is_instance_valid(GameManager):
					GameManager.rpc_request_pickup_by_name_and_position(pickup_name, pickup_position)
			else:
				# Client sends RPC to server via GameManager (which always exists)
				if is_instance_valid(GameManager):
					GameManager.rpc_request_pickup_by_name_and_position.rpc_id(1, pickup_name, pickup_position)
	elif col is InteractiveDoor:
		# Show interaction feedback for door
		var door_state_text = ""
		match col.state:
			InteractiveDoor.STATE.CLOSED:
				door_state_text = "OPEN"
			InteractiveDoor.STATE.OPENED_INSIDE, InteractiveDoor.STATE.OPENED_OUTSIDE:
				door_state_text = "CLOSE"
		
		interaction_feedback_label_3d.text = door_state_text
		interaction_feedback_label_3d.visible = true
		interaction_feedback_label_3d.global_position = interaction_ray_cast_3d.get_collision_point()
		
		if Input.is_action_just_pressed(controls.INTERACTION):
			# Get player position for door to determine which side to open
			var player_position = global_position
			
			if multiplayer.is_server():
				# Server can directly call toggle on the door
				col.rpc_request_toggle(player_position)
			else:
				# Client sends RPC directly to the door (will route to server)
				col.rpc_request_toggle.rpc_id(1, player_position)
	elif col is InteractiveButton:
		interaction_feedback_label_3d.text = 'INTERACT'
		interaction_feedback_label_3d.visible = true
		interaction_feedback_label_3d.global_position = interaction_ray_cast_3d.get_collision_point()
		
		if Input.is_action_just_pressed(controls.INTERACTION):
			col.rpc_request_interaction.rpc()
	else:
		interaction_feedback_label_3d.visible = false
			

@onready var items_bag: Node3D = %ItemsBag
	
# Server tells all clients to destroy the weapon
# This RPC can be called by the server from any character node
@rpc("any_peer", "call_local", "reliable")
func rpc_destroy_weapon(weapon_path: NodePath):
	# Only process if called from server
	if !multiplayer.is_server() and multiplayer.get_remote_sender_id() != 1:
		return
	var weapon_node = get_node_or_null(weapon_path)
	if weapon_node != null:
		weapon_node.queue_free()

@rpc("any_peer", "call_local", "reliable")
func rpc_destroy_weapon_by_position(weapon_position: Vector3):
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	# Find and destroy weapon by position
	var game_root = GameManager._game_level
	if game_root == null:
		return
	
	var search_radius = 0.5 # Search within 0.5 units
	for child in game_root.get_children():
		if child is InteractivePickup:
			var distance = child.global_position.distance_to(weapon_position)
			if distance < search_radius:
				print("[DESTROY WEAPON] Destroying pickup at position %s" % weapon_position)
				child.queue_free()
				return
	
	print("[DESTROY WEAPON] Could not find pickup at position %s to destroy" % weapon_position)

# Server tells requesting client to update their inventory UI
# This RPC can be called by the server from any character node
@rpc("any_peer", "reliable")
func rpc_update_inventory(serialized_inventory: Dictionary):
	# Only process if called from server (peer ID 1)
	# When client receives this, remote_sender_id will be 1 (server)
	if !multiplayer.is_server():
		if multiplayer.get_remote_sender_id() != 1:
			return
	# Deserialize inventory dictionary
	carrying_items.clear()
	for key in serialized_inventory.keys():
		var weapon_data = serialized_inventory[key] as Dictionary
		if weapon_data != null:
			carrying_items[key] = GameManager.deserialize_weapon_resource(weapon_data)
	
	_clamp_selected_index()
	if inventory_slots_panel_container:
		inventory_slots_panel_container.update_inventory_items_ui(carrying_items, current_selected_item_index)
	
	# Equip the currently selected item to ensure it shows up in hands
	var item_keys = carrying_items.keys()
	if item_keys.size() > current_selected_item_index and current_selected_item_index >= 0:
		var selected_item_res = carrying_items[item_keys[current_selected_item_index]]
		var weapon_data = GameManager.serialize_weapon_resource(selected_item_res)
		rpc_update_item_in_hands(current_selected_item_index, weapon_data)
	else:
		rpc_update_item_in_hands(-1, {}) # No item selected

func handle_attacking():
	if !_has_input_authority:
		return
	if is_attacking:
		return
	if Input.is_action_just_pressed("attack"):
		var attack_string = ''
		if is_crouching:
			attack_string = 'crouch_attack'
		elif input_dir.y != 0:
			attack_string = 'attack_vertical'
		elif input_dir.x != 0:
			attack_string = 'attack_horizontal'
		else:
			attack_string = ['attack_vertical', 'attack_horizontal'].pick_random()
		rpc_melee_attack.rpc(attack_string)
		
@rpc("call_local")
func rpc_melee_attack(attack_string: String):
	# Apply forward push when attacking (on the client that has authority over this character)
	# Store push velocity to apply it after movement handling (so it doesn't get dampened)
	if is_multiplayer_authority() and item_in_hands != null and item_in_hands.weapon_resource != null:
		var push_force = item_in_hands.weapon_resource.push_forward_on_attack_force
		if is_crouching:
			push_force = 0
		if push_force > 0:
			# Get forward direction from camera/head (where player is looking)
			# Use camera forward direction if available, otherwise use head
			var forward_direction: Vector3
			if CAMERA != null:
				forward_direction = - CAMERA.global_transform.basis.z.normalized()
			else:
				forward_direction = - HEAD.global_transform.basis.z.normalized()
			# Ignore Y component for horizontal push
			forward_direction.y = 0
			forward_direction = forward_direction.normalized()
			# Store push velocity to apply after movement handling (don't apply it here to avoid double application)
			attack_push_velocity = forward_direction * push_force
	
	mesh_animation_player.play(attack_string, 0.1)

	is_attacking = true
	if item_in_hands:
		item_in_hands.set_dangerous(true, self)
	await mesh_animation_player.animation_finished
	if item_in_hands:
		item_in_hands.set_dangerous(false, self)
	is_attacking = false
@onready var camera: Camera3D = %Camera

func handle_crouching():
	if !_has_input_authority:
		return
	if !crouch_enabled:
		return
	#if is_multiplayer_authority() == false:
		#return
	if camera.current == false:
		return
	if crouch_mode == 0: # Hold to crouch
		if Input.is_action_pressed(controls.CROUCH) and state != "sprinting":
			if state != "crouching":
				print("[CROUCH DEBUG] %s: Entering crouch state" % name)
				rpc_enter_crouch_state.rpc()
		elif state == "crouching":
			if !low_ceiling:
				print("[CROUCH DEBUG] %s: Exiting crouch state" % name)
				rpc_enter_normal_state.rpc()
	elif crouch_mode == 1: # Toggle crouch
		if Input.is_action_just_pressed(controls.CROUCH):
			if state == "crouching":
				if !low_ceiling:
					print("[CROUCH DEBUG] %s: Exiting crouch state (toggle)" % name)
					rpc_enter_normal_state.rpc()
			elif state != "sprinting":
				print("[CROUCH DEBUG] %s: Entering crouch state (toggle)" % name)
				rpc_enter_crouch_state.rpc()

@rpc("any_peer", "call_local")
func rpc_enter_crouch_state():
	# Only execute this RPC for the character that has the same authority as the RPC sender
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		# Local call (on server), use the authority of this character instance
		sender_id = get_multiplayer_authority()
	
	# Only apply state change if this character's authority matches the RPC sender
	if get_multiplayer_authority() != sender_id:
		return
	
	# Don't change if already crouching
	if state == "crouching":
		return
	
	print("[STATE] %s: rpc_enter_crouch_state() - prev=%s, has_input=%s, authority=%d, sender=%d" % [name, state, _has_input_authority, get_multiplayer_authority(), sender_id])
	state = "crouching"
	speed = crouch_speed
	is_crouching = true

@rpc("any_peer", "call_local")
func rpc_enter_normal_state():
	# Only execute this RPC for the character that has the same authority as the RPC sender
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		# Local call (on server), use the authority of this character instance
		sender_id = get_multiplayer_authority()
	
	# Only apply state change if this character's authority matches the RPC sender
	if get_multiplayer_authority() != sender_id:
		return
	
	# Don't change if already normal
	if state == "normal":
		return
	
	print("[STATE] %s: rpc_enter_normal_state() - prev=%s, has_input=%s, authority=%d, sender=%d" % [name, state, _has_input_authority, get_multiplayer_authority(), sender_id])
	state = "normal"
	speed = base_speed
	is_crouching = false

func handle_jumping():
	if !_has_input_authority:
		return
	if is_vaulting:
		return
	if jumping_enabled:
		if continuous_jumping: # Hold down the jump button
			#if Input.is_action_pressed(controls.JUMP) and is_on_floor() and !low_ceiling:
			if Input.is_action_pressed(controls.JUMP) and is_on_floor():
				if jump_animation:
					JUMP_ANIMATION.play("jump", 0.25)
				mesh_animation_player.play("jump", 0.1)
				velocity.y += jump_velocity # Adding instead of setting so jumping on slopes works properly
		else:
			if Input.is_action_just_pressed(controls.JUMP) and is_on_floor():
				if jump_animation:
					JUMP_ANIMATION.play("jump", 0.25)
				mesh_animation_player.play("jump", 0.1)
				velocity.y += jump_velocity


func handle_movement(delta, input_dir):
	if !_has_input_authority:
		return
	
	# Если игрок движется лифтом, не обрабатывать движение
	if is_moving_by_elevator:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var direction = input_dir.rotated(-rotation.y)
	if is_attacking or is_blocking:
		# Apply attack push velocity first (only once per attack, before dampening)
		if attack_push_velocity.length() > 0:
			velocity += attack_push_velocity
			# Clear it after applying so it's only applied once
			attack_push_velocity = Vector3.ZERO
		# Dampen velocity (this will reduce the push velocity naturally over time)
		velocity.x = lerpf(velocity.x, velocity.x * 0.1, 10 * get_process_delta_time())
		velocity.z = lerpf(velocity.z, velocity.z * 0.1, 10 * get_process_delta_time())
		
		# DONT CALL - ITS PROCESSED BY STAIRS CHARACTER 3D
		#move_and_slide()
		return
		
	direction = Vector3(direction.x, 0, direction.y)
	
	# DONT CALL - ITS PROCESSED BY STAIRS CHARACTER 3D
	#move_and_slide()

	if in_air_momentum:
		if is_on_floor():
			if motion_smoothing:
				velocity.x = lerp(velocity.x, direction.x * speed, acceleration * delta)
				velocity.z = lerp(velocity.z, direction.z * speed, acceleration * delta)
			else:
				velocity.x = direction.x * speed
				velocity.z = direction.z * speed
	else:
		if motion_smoothing:
			velocity.x = lerp(velocity.x, direction.x * speed, acceleration * delta)
			velocity.z = lerp(velocity.z, direction.z * speed, acceleration * delta)
		else:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed


func handle_head_rotation():
	if !_has_input_authority:
		return
	if mouseInput != Vector2.ZERO:
		if debug_authority:
			_debug_print("Rotating camera: mouse=%s" % str(mouseInput))
	if invert_camera_x_axis:
		target_character_rotation_y -= deg_to_rad(mouseInput.x * mouse_sensitivity * -1)
	else:
		target_character_rotation_y -= deg_to_rad(mouseInput.x * mouse_sensitivity)

	if invert_camera_y_axis:
		target_head_rotation_x -= deg_to_rad(mouseInput.y * mouse_sensitivity * -1)
	else:
		target_head_rotation_x -= deg_to_rad(mouseInput.y * mouse_sensitivity)

	if controller_support:
		var controller_view_rotation = Input.get_vector(controller_controls.LOOK_DOWN, controller_controls.LOOK_UP, controller_controls.LOOK_RIGHT, controller_controls.LOOK_LEFT) * look_sensitivity # These are inverted because of the nature of 3D rotation.
		# Vertical stick (y) controls pitch (head rotation X)
		if invert_camera_x_axis:
			target_head_rotation_x += controller_view_rotation.y * -1
		else:
			target_head_rotation_x += controller_view_rotation.y
		
		# Horizontal stick (x) controls yaw (character rotation Y)
		if invert_camera_y_axis:
			target_character_rotation_y += controller_view_rotation.x * -1
		else:
			target_character_rotation_y += controller_view_rotation.x

	mouseInput = Vector2(0, 0)
	target_head_rotation_x = clamp(target_head_rotation_x, deg_to_rad(camera_clamp.x), deg_to_rad(camera_clamp.y))


func apply_rotation_smoothing(delta):
	if !_has_input_authority:
		return
	
	if rotation_smoothing_speed > 0.0:
		# Smooth head rotation X (pitch)
		HEAD.rotation.x = lerp(HEAD.rotation.x, target_head_rotation_x, rotation_smoothing_speed * delta)
		if is_dead() == false:
			# Smooth character rotation Y (yaw) - use lerp_angle for proper wrapping
			rotation.y = lerp_angle(rotation.y, target_character_rotation_y, rotation_smoothing_speed * delta)
	else:
		# No smoothing - apply directly
		HEAD.rotation.x = target_head_rotation_x
		if is_dead() == false:
			rotation.y = target_character_rotation_y


func check_controls(): # If you add a control, you might want to add a check for it here.
	# The actions are being disabled so the engine doesn't halt the entire project in debug mode
	if !InputMap.has_action(controls.JUMP):
		push_error("No control mapped for jumping. Please add an input map control. Disabling jump.")
		jumping_enabled = false
	if !InputMap.has_action(controls.LEFT):
		push_error("No control mapped for move left. Please add an input map control. Disabling movement.")
		immobile = true
	if !InputMap.has_action(controls.RIGHT):
		push_error("No control mapped for move right. Please add an input map control. Disabling movement.")
		immobile = true
	if !InputMap.has_action(controls.FORWARD):
		push_error("No control mapped for move forward. Please add an input map control. Disabling movement.")
		immobile = true
	if !InputMap.has_action(controls.BACKWARD):
		push_error("No control mapped for move backward. Please add an input map control. Disabling movement.")
		immobile = true
	if !InputMap.has_action(controls.PAUSE):
		push_error("No control mapped for pause. Please add an input map control. Disabling pausing.")
		pausing_enabled = false
	if !InputMap.has_action(controls.CROUCH):
		push_error("No control mapped for crouch. Please add an input map control. Disabling crouching.")
		crouch_enabled = false
	if !InputMap.has_action(controls.SPRINT):
		push_error("No control mapped for sprint. Please add an input map control. Disabling sprinting.")
		sprint_enabled = false

#endregion

#region State Handling

func handle_state(moving):
	if !_has_input_authority:
		return
	if sprint_enabled:
		if sprint_mode == 0:
			if Input.is_action_pressed(controls.SPRINT) and state != "crouching":
				if moving:
					if state != "sprinting":
						enter_sprint_state()
				else:
					if state == "sprinting":
						enter_normal_state()
			elif state == "sprinting":
				enter_normal_state()
		elif sprint_mode == 1:
			if moving:
				# If the player is holding sprint before moving, handle that scenario
				if Input.is_action_pressed(controls.SPRINT) and state == "normal":
					enter_sprint_state()
				if Input.is_action_just_pressed(controls.SPRINT):
					match state:
						"normal":
							enter_sprint_state()
						"sprinting": # Corrected from `elif state == "sprinting":`
							enter_normal_state()
			elif state == "sprinting":
				enter_normal_state()
	
	# Crouch handling is now in handle_crouching() function which uses RPC calls


# Any enter state function should only be called once when you want to enter that state, not every frame.
func enter_normal_state():
	print("[STATE] %s: enter_normal_state() - prev=%s, has_input=%s, authority=%d" % [name, state, _has_input_authority, get_multiplayer_authority()])
	var prev_state = state
	state = "normal"
	speed = base_speed
	is_crouching = false


func enter_sprint_state():
	#print("entering sprint state")
	var prev_state = state
	state = "sprinting"
	speed = sprint_speed
	is_crouching = false

func enter_crouch_state():
	print("[STATE] %s: enter_crouch_state() - prev=%s, has_input=%s, authority=%d" % [name, state, _has_input_authority, get_multiplayer_authority()])
	var prev_state = state
	state = "crouching"
	speed = crouch_speed
	is_crouching = true

#endregion

#region Animation Handling

func initialize_animations():
	# Reset the camera position
	# If you want to change the default head height, change these animations.
	HEADBOB_ANIMATION.play("RESET")
	JUMP_ANIMATION.play("RESET")

func play_headbob_animation(moving):
	if !_has_input_authority:
		return
	if moving and is_on_floor():
		var use_headbob_animation: String
		match state:
			"normal", "crouching":
				use_headbob_animation = "walk"
			"sprinting":
				use_headbob_animation = "sprint"

		var was_playing: bool = false
		if HEADBOB_ANIMATION.current_animation == use_headbob_animation:
			was_playing = true

		HEADBOB_ANIMATION.play(use_headbob_animation, 0.25)
		HEADBOB_ANIMATION.speed_scale = (current_speed / base_speed) * 1.75
		if !was_playing:
			HEADBOB_ANIMATION.seek(float(randi() % 2)) # Randomize the initial headbob direction
			# Let me explain that piece of code because it looks like it does the opposite of what it actually does.
			# The headbob animation has two starting positions. One is at 0 and the other is at 1.
			# randi() % 2 returns either 0 or 1, and so the animation randomly starts at one of the starting positions.
			# This code is extremely performant but it makes no sense.

	else:
		if HEADBOB_ANIMATION.current_animation == "sprint" or HEADBOB_ANIMATION.current_animation == "walk":
			HEADBOB_ANIMATION.speed_scale = 1
			HEADBOB_ANIMATION.play("RESET", 1)

func play_jump_animation():
	if !was_on_floor and is_on_floor(): # The player just landed
		var facing_direction: Vector3 = CAMERA.get_global_transform().basis.x
		var facing_direction_2D: Vector2 = Vector2(facing_direction.x, facing_direction.z).normalized()
		var velocity_2D: Vector2 = Vector2(velocity.x, velocity.z).normalized()

		# Compares velocity direction against the camera direction (via dot product) to determine which landing animation to play.
		var side_landed: int = round(velocity_2D.dot(facing_direction_2D))

		if side_landed > 0:
			JUMP_ANIMATION.play("land_right", 0.25)
		elif side_landed < 0:
			JUMP_ANIMATION.play("land_left", 0.25)
		else:
			JUMP_ANIMATION.play("land_center", 0.25)

#endregion

#region Vaulting and Climbing

func handle_vaulting():
	if !_has_input_authority:
		return
		
	# Check input direction directly (Forward)
	if not Input.is_action_pressed(controls.FORWARD):
		return
		
	if not Input.is_action_pressed(controls.JUMP):
		return
		
	# Check for wall
	var result = check_wall_height()
	if result.type != "none":
		start_vault_or_climb(result.type, result.height, result.normal, result.point)

func check_wall_height() -> Dictionary:
	# Returns { "type": "none"|"vault"|"climb", "height": float, "normal": Vector3, "point": Vector3 }
	var result = {"type": "none", "height": 0.0, "normal": Vector3.ZERO, "point": Vector3.ZERO}
	
	if vaulting_raycasts.is_empty():
		return result
		
	# Enable raycasts temporarily
	for ray in vaulting_raycasts:
		if ray.enabled == false:
			ray.force_raycast_update()
		
	# Find the highest raycast that hits
	var highest_hit_index = -1
	var hit_point = Vector3.ZERO
	var hit_normal = Vector3.ZERO
	
	for i in range(vaulting_raycasts.size()):
		var ray = vaulting_raycasts[i]
		if ray.is_colliding():
			highest_hit_index = i
			hit_point = ray.get_collision_point()
			hit_normal = ray.get_collision_normal()
		else:
			# If we found a hit previously and this one misses, we found the top edge
			if highest_hit_index != -1:
				break
	
	# Disable raycasts
	#for ray in vaulting_raycasts:
		#ray.enabled = false
	
	if highest_hit_index == -1 or 0:
		return result
		
	# Determine height based on the raycast ABOVE the highest hit
	# If highest_hit_index is the last one, we can't climb over it (too high)
	if highest_hit_index == vaulting_raycasts.size() - 1:
		return result
		
	# The clear height is the position of the first ray that missed
	var clear_ray = vaulting_raycasts[highest_hit_index + 1]
	var wall_height_y = clear_ray.global_position.y
	
	# Calculate relative height from player feet
	var height_diff = wall_height_y - global_position.y
	print("trying enter parkour at dist %s"%height_diff)
	if height_diff <= vaulting_threshold:
		result.type = "vault"
	else:
		return result
		
	result.height = wall_height_y
	result.normal = hit_normal
	result.point = hit_point
	
	return result

func start_vault_or_climb(type: String, target_height: float, wall_normal: Vector3, wall_point: Vector3):
	if is_vaulting:
		return
	if type == "vault":
		print('enter vault ')
		is_vaulting = true
		enter_crouch_state()
		if mesh_animation_player:
			mesh_animation_player.play("vault", 0.2)
	
	vault_target_height = target_height
	# Target position is forward past the wall
	# Invert normal to get wall direction (towards wall)
	var wall_dir = - wall_normal
	wall_dir.y = 0
	wall_dir = wall_dir.normalized()
	
	# Move 1 meter past the hit point
	vault_target_pos = wall_point + (wall_dir * 1)
	vault_target_pos.y = target_height
	
	vault_start_pos = global_position
	vault_progress = 0.0

func process_vault_climb(delta):
	# Simple procedural animation for movement: Up then Forward
	# Adjust speed as needed
	var move_speed = 2
		
	# Phase 1: Move Up
	if global_position.y < vault_target_height - 0.1:
		velocity = Vector3(0, move_speed, 0)
		#move_and_slide()
	else:
		# Phase 2: Move Forward
		var target_xz = Vector3(vault_target_pos.x, global_position.y, vault_target_pos.z)
		var dir = global_position.direction_to(target_xz)
		var dist = global_position.distance_to(target_xz)
		
		if dist > 0.2:
			velocity = dir * move_speed
			#move_and_slide()
		else:
			# Finished
			finish_vault_climb()

func finish_vault_climb():
	is_vaulting = false
	velocity = Vector3.ZERO
	if !low_ceiling:
		enter_normal_state()
#endregion

#region Debug Menu

func update_debug_menu_per_frame():
	$UserInterface/DebugPanel.add_property("FPS", Performance.get_monitor(Performance.TIME_FPS), 0)
	var status: String = state
	if !is_on_floor():
		status += " in the air"
	$UserInterface/DebugPanel.add_property("State", status, 4)


func update_debug_menu_per_tick():
	# Big thanks to github.com/LorenzoAncora for the concept of the improved debug values
	current_speed = Vector3.ZERO.distance_to(get_real_velocity())
	$UserInterface/DebugPanel.add_property("Speed", snappedf(current_speed, 0.001), 1)
	$UserInterface/DebugPanel.add_property("Target speed", speed, 2)
	var cv: Vector3 = get_real_velocity()
	var vd: Array[float] = [
		snappedf(cv.x, 0.001),
		snappedf(cv.y, 0.001),
		snappedf(cv.z, 0.001)
	]
	var readable_velocity: String = "X: " + str(vd[0]) + " Y: " + str(vd[1]) + " Z: " + str(vd[2])
	$UserInterface/DebugPanel.add_property("Velocity", readable_velocity, 3)


func _unhandled_input(event: InputEvent):
	if !_has_input_authority:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouseInput = event.relative
		if debug_authority:
			_debug_print("Mouse input: %s" % str(mouseInput))
	elif Input.is_action_just_pressed('switch_inventory_item'):
		change_selected_item_index(1)
	elif event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Handle mouse wheel for inventory selection
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			change_selected_item_index(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			change_selected_item_index(1)
	elif event is InputEventKey:
		# Handle number keys 1-5 for direct item selection
		if event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var target_index = -1
			match event.keycode:
				KEY_1:
					target_index = 0
				KEY_2:
					target_index = 1
				KEY_3:
					target_index = 2
				KEY_4:
					target_index = 3
				KEY_5:
					target_index = 4
			
			if target_index >= 0:
				set_selected_item_index(target_index)
		# Toggle debug menu
		if event.is_released():
			# Where we're going, we don't need InputMap
			if event.keycode == 4194338: # F7
				$UserInterface/DebugPanel.visible = !$UserInterface/DebugPanel.visible

#endregion

#region Misc Functions

func change_reticle(reticle): # Yup, this function is kinda strange
	if !_has_input_authority:
		return
	if RETICLE:
		RETICLE.queue_free()

	RETICLE = load(reticle).instantiate()
	RETICLE.character = self
	$UserInterface.add_child(RETICLE)


func update_camera_fov():
	if state == "sprinting":
		CAMERA.fov = lerp(CAMERA.fov, fov_sprint, 5 * get_process_delta_time())
	else:
		CAMERA.fov = lerp(CAMERA.fov, fov_idle, 5 * get_process_delta_time())

func handle_pausing():
	if !_has_input_authority:
		return
	if Input.is_action_just_pressed(controls.PAUSE):
		# You may want another node to handle pausing, because this player may get paused too.
		match Input.mouse_mode:
			Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				#get_tree().paused = false
			Input.MOUSE_MODE_VISIBLE:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				#get_tree().paused = false
				
var on_change_item_cooldown = false
func change_selected_item_index(delta: int):
	if !_has_input_authority:
		return
	if on_change_item_cooldown:
		return
	var item_count = carrying_items.size()
	if item_count == 0:
		current_selected_item_index = 0
		return
	
	on_change_item_cooldown = true
	await get_tree().create_timer(0.15).timeout
	on_change_item_cooldown = false
	
	# Sync durability from currently equipped weapon back to inventory before switching
	if item_in_hands != null and item_in_hands.weapon_resource != null:
		_sync_weapon_durability_to_inventory()
	
	current_selected_item_index += delta
	
	# Wrap around
	if current_selected_item_index < 0:
		current_selected_item_index = item_count - 1
	elif current_selected_item_index >= item_count:
		current_selected_item_index = 0
	
	# Update UI locally first
	if inventory_slots_panel_container:
		inventory_slots_panel_container.update_inventory_items_ui(carrying_items, current_selected_item_index)
	
	# Send request to server to update item in hands for all clients
	if multiplayer.is_server():
		# Server processes directly
		_rpc_update_item_in_hands_server(current_selected_item_index)
	else:
		# Client sends request to server
		rpc_request_change_item.rpc(current_selected_item_index)

func set_selected_item_index(target_index: int):
	if !_has_input_authority:
		return
	if on_change_item_cooldown:
		return
	var item_count = carrying_items.size()
	if item_count == 0:
		current_selected_item_index = 0
		return
	
	# Check if target index is valid
	if target_index < 0 or target_index >= item_count:
		return
	
	# Don't switch if already on this item
	if current_selected_item_index == target_index:
		return
	
	on_change_item_cooldown = true
	await get_tree().create_timer(0.15).timeout
	on_change_item_cooldown = false
	
	# Sync durability from currently equipped weapon back to inventory before switching
	if item_in_hands != null and item_in_hands.weapon_resource != null:
		_sync_weapon_durability_to_inventory()
	
	current_selected_item_index = target_index
	
	# Update UI locally first
	if inventory_slots_panel_container:
		inventory_slots_panel_container.update_inventory_items_ui(carrying_items, current_selected_item_index)
	
	# Send request to server to update item in hands for all clients
	if multiplayer.is_server():
		# Server processes directly
		_rpc_update_item_in_hands_server(current_selected_item_index)
	else:
		# Client sends request to server
		rpc_request_change_item.rpc(current_selected_item_index)

@rpc("any_peer", "reliable")
func rpc_request_change_item(item_index: int):
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	# Get requesting peer ID
	var requesting_peer_id = multiplayer.get_unique_id()
	if multiplayer.get_remote_sender_id() != 0:
		requesting_peer_id = multiplayer.get_remote_sender_id()
	
	# Find requesting player
	var root = get_tree().root
	var player_path = root.get_node_or_null("Main/GameRoot/Players/PlayerSpawner/Player_%d" % requesting_peer_id)
	var requesting_player = player_path
	
	if requesting_player == null:
		var all_players = get_tree().get_nodes_in_group("players")
		for player in all_players:
			if player.name == "Player_%d" % requesting_peer_id:
				requesting_player = player
				break
	
	if requesting_player == null:
		return
	
	# Sync durability before switching
	if requesting_player.item_in_hands != null and requesting_player.item_in_hands.weapon_resource != null:
		requesting_player._sync_weapon_durability_to_inventory()
	
	# Update selected index
	requesting_player.current_selected_item_index = item_index
	requesting_player._clamp_selected_index()
	
	# Broadcast update to all clients
	requesting_player._rpc_update_item_in_hands_server(requesting_player.current_selected_item_index)

func _rpc_update_item_in_hands_server(item_index: int):
	# Get the item and broadcast to all clients
	var item_keys = carrying_items.keys()
	if item_keys.size() > item_index and item_index >= 0:
		var selected_item_res = carrying_items[item_keys[item_index]]
		var weapon_data = GameManager.serialize_weapon_resource(selected_item_res)
		rpc_update_item_in_hands.rpc(item_index, weapon_data)
	else:
		rpc_update_item_in_hands.rpc(-1, {}) # No item selected
	

@onready var weapon_bone_attachment_3d: BoneAttachment3D = %WeaponBoneAttachment3D

@rpc("any_peer", "call_local", "reliable")
func rpc_update_item_in_hands(item_index: int, weapon_data: Dictionary):
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	if item_in_hands != null:
		item_in_hands.queue_free()
		item_in_hands = null
	
	# If no item selected (item_index < 0 or empty data), don't spawn anything
	if item_index < 0 or weapon_data.is_empty():
		return
	
	# Deserialize weapon resource from data
	var weapon_resource = GameManager.deserialize_weapon_resource(weapon_data)
	if weapon_resource == null:
		return
	
	# Use the provided item_path instead of relying on carrying_items
	item_in_hands = load(weapon_resource.weapon_prefab_path).instantiate()
	item_in_hands.weapon_owner = self
	if item_in_hands == null:
		push_error("Failed to load item: " + weapon_resource.weapon_prefab_path)
		return
	
	weapon_bone_attachment_3d.add_child(item_in_hands)
	item_in_hands.weapon_resource = weapon_resource.duplicate()
	print("item_in_hands.weapon_resource.reducing_durability_when_in_hands %s"%item_in_hands.weapon_resource.reducing_durability_when_in_hands)
	item_in_hands.position = item_in_hands.weapon_slot_position
	item_in_hands.scale = Vector3.ONE * 100
	
	# Sync durability to client if this is a server call
	if multiplayer.is_server() and item_in_hands.weapon_resource != null:
		rpc_sync_weapon_durability.rpc(item_in_hands.weapon_resource.weapon_durability_current)

@rpc("any_peer", "call_local", "reliable")
func rpc_sync_weapon_durability(durability: float):
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	# Update durability on client's weapon
	if item_in_hands != null and item_in_hands.weapon_resource != null:
		var old_durability = item_in_hands.weapon_resource.weapon_durability_current
		item_in_hands.weapon_resource.weapon_durability_current = durability
		# Also sync to inventory
		_sync_weapon_durability_to_inventory()
		# Update UI
		if inventory_slots_panel_container:
			inventory_slots_panel_container.update_durability_display(carrying_items)
	else:
		#print("[DURABILITY SYNC] Warning: item_in_hands or weapon_resource is null!")
		pass

func _sync_weapon_durability_to_inventory():
	# Sync durability from item_in_hands.weapon_resource back to carrying_items
	if item_in_hands == null or item_in_hands.weapon_resource == null:
		return
	
	var equipped_resource = item_in_hands.weapon_resource
	var item_keys = carrying_items.keys()
	
	# Use current_selected_item_index to find the exact item that's currently equipped
	# This ensures we sync to the correct item when multiple items of the same type exist
	if current_selected_item_index >= 0 and current_selected_item_index < item_keys.size():
		var current_item_key = item_keys[current_selected_item_index]
		var inventory_resource = carrying_items[current_item_key] as ResourceWeapon
		if inventory_resource != null:
			# Verify it matches the equipped weapon (safety check)
			if inventory_resource.weapon_name == equipped_resource.weapon_name and inventory_resource.weapon_type == equipped_resource.weapon_type:
				var old_inventory_durability = inventory_resource.weapon_durability_current
				# Sync durability
				inventory_resource.weapon_durability_current = equipped_resource.weapon_durability_current
				# Debug output when durability changes significantly
				#if abs(old_inventory_durability - inventory_resource.weapon_durability_current) > 0.1:
					#print("[DURABILITY SYNC] %s (index %d): Synced %.2f -> %.2f (equipped: %.2f)" % [
						#current_item_key,
						#current_selected_item_index,
						#old_inventory_durability,
						#inventory_resource.weapon_durability_current,
						#equipped_resource.weapon_durability_current
					#])
			else:
				#print("[DURABILITY SYNC WARNING] Selected item doesn't match equipped weapon!")
				pass
	else:
		# Fallback: Find matching item by weapon_name and weapon_type (for cases where index might be invalid)
		for key in item_keys:
			var inventory_resource = carrying_items[key] as ResourceWeapon
			if inventory_resource != null:
				if inventory_resource.weapon_name == equipped_resource.weapon_name and inventory_resource.weapon_type == equipped_resource.weapon_type:
					var old_inventory_durability = inventory_resource.weapon_durability_current
					# Sync durability
					inventory_resource.weapon_durability_current = equipped_resource.weapon_durability_current
					# Debug output when durability changes significantly
					#if abs(old_inventory_durability - inventory_resource.weapon_durability_current) > 0.1:
						#print("[DURABILITY SYNC FALLBACK] %s: Synced %.2f -> %.2f (equipped: %.2f)" % [
							#key,
							#old_inventory_durability,
							#inventory_resource.weapon_durability_current,
							#equipped_resource.weapon_durability_current
						#])
					break

func _clamp_selected_index():
	# Ensure selected index is within valid range
	var item_count = carrying_items.size()
	if item_count == 0:
		current_selected_item_index = 0
	elif current_selected_item_index >= item_count:
		current_selected_item_index = item_count - 1
	elif current_selected_item_index < 0:
		current_selected_item_index = 0

#endregion

#region Multiplayer

#func _multiplayer_authority_changed():
	#_refresh_authority_state()


func _has_local_control() -> bool:
	if !multiplayer.has_multiplayer_peer():
		return true
	# Use cached peer IDs to avoid parsing name and calling get_unique_id() every frame
	if _cached_peer_id >= 0:
		if _cached_local_peer_id < 0:
			_cached_local_peer_id = multiplayer.get_unique_id()
		return _cached_peer_id == _cached_local_peer_id
	# Fallback: parse name if cache not set (shouldn't happen normally)
	var name_parts = name.split("_")
	if name_parts.size() >= 2:
		_cached_peer_id = name_parts[1].to_int()
		if _cached_local_peer_id < 0:
			_cached_local_peer_id = multiplayer.get_unique_id()
		return _cached_peer_id == _cached_local_peer_id
	return is_multiplayer_authority()


func _refresh_authority_state(force: bool = false):
	var new_authority_state := _has_local_control()
	if !force and new_authority_state == _has_input_authority:
		return

	_has_input_authority = new_authority_state
	if _has_input_authority:
		#var bone_idx = skeleton_3d.find_bone('mixamorig_Spine2')
		var bone_idx = skeleton_3d.find_bone('mixamorig_Neck')
		skeleton_3d.set_bone_pose_scale(bone_idx, Vector3.ZERO)
	_debug_last_has_input = _has_input_authority
	if debug_authority:
		var ctx := _debug_authority_context()
		_debug_print("Authority state refreshed -> %s (force=%s, context=%s)" % [str(_has_input_authority), str(force), ctx])

	# Configure synchronizer based on authority
	var synchronizer = get_node_or_null("MultiplayerSynchronizer")
	if synchronizer:
		if debug_authority:
			_debug_print("Synchronizer status - authority: %s, multiplayer_authority: %d, visibility_mode: %d" % [str(_has_input_authority), get_multiplayer_authority(), synchronizer.visibility_update_mode])
		# Set visibility update mode to On Change to match replication mode
		synchronizer.visibility_update_mode = 1 # On Change

	if has_node("UserInterface"):
		$UserInterface.visible = _has_input_authority

	if !_has_input_authority:
		mouseInput = Vector2.ZERO
		if RETICLE:
			RETICLE.queue_free()
			RETICLE = null
		if CAMERA:
			CAMERA.current = false
		_debug_report_input_block("authority_refresh")
		return

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if CAMERA:
		CAMERA.current = true

	if default_reticle and RETICLE == null:
		change_reticle(default_reticle)
	_debug_clear_block_reason("authority_refresh")


func _ensure_authority_state():
	var should_have_control := _has_local_control()
	if should_have_control != _has_input_authority:
		if debug_authority:
			var ctx := _debug_authority_context()
			_debug_print("Authority change: was=%s, now=%s (%s)" % [str(_has_input_authority), str(should_have_control), ctx])
		_refresh_authority_state()

#endregion

#region Debug Helpers

func _debug_print(message: String) -> void:
	if !debug_authority:
		return
	var prefix := "[CharacterAuth]"
	var peer_desc := "local"
	if multiplayer and multiplayer.has_multiplayer_peer():
		peer_desc = "peer=%s" % str(multiplayer.get_unique_id())
	print("%s %s %s -> %s" % [prefix, name, peer_desc, message])


func _debug_authority_context() -> String:
	var parts: Array[String] = []
	parts.append("node=%s" % name)
	if multiplayer:
		if multiplayer.has_multiplayer_peer():
			parts.append("peer=%s" % str(multiplayer.get_unique_id()))
		else:
			parts.append("peer=local")
	else:
		parts.append("peer=<none>")
	parts.append("authority=%s" % str(get_multiplayer_authority()))
	parts.append("is_authority=%s" % str(is_multiplayer_authority()))
	parts.append("has_input=%s" % str(_has_input_authority))
	return "; ".join(parts)


func _debug_report_input_block(source: String) -> void:
	if !debug_authority:
		return
	if _debug_last_blocked_reason == source:
		return
	_debug_last_blocked_reason = source
	var ctx := _debug_authority_context()
	_debug_print("Input blocked at %s (%s)" % [source, ctx])


func _debug_clear_block_reason(source: String) -> void:
	if !debug_authority:
		return
	if _debug_last_blocked_reason == source:
		_debug_last_blocked_reason = ""
		var ctx := _debug_authority_context()
		_debug_print("Input restored after %s (%s)" % [source, ctx])

func death():
	super.death()
	if _has_input_authority:
		await get_tree().create_timer(5).timeout
		rpc_full_heal_and_resurrect.rpc()
		enter_normal_state()


func cheat_codes():
	#if Input.is_key_label_pressed(KEY_G) and Input.is_key_label_pressed(KEY_Z) and Input.is_key_label_pressed(KEY_H):
		#rpc_full_heal_and_resurrect.rpc()
		#if _has_input_authority:
			#enter_normal_state()
	pass
