# COPYRIGHT Colormatic Studios
# MIT license
# Quality Godot First Person Controller v2


extends Unit
class_name PlayerCharacter

#region Character Export Group

## The settings for the character's movement and feel.
@export var carrying_items : Dictionary[StringName, Array] = {}  # Dictionary[interactive_name, [prefab_path_pickup, prefab_weapon]]
@export var inventory_slots_max : int = 5
@export var current_selected_item_index : int = 0
@onready var interaction_ray_cast_3d: RayCast3D = %InteractionRayCast3D

@onready var inventory_slots_panel_container: PlayerInventorySlotsPanelContainer = %InventorySlotsPanelContainer
@export_category("Character")
## The speed that the character moves at without crouching or sprinting.
@export var base_speed : float = 3.0
## The speed that the character moves at when sprinting.
@export var sprint_speed : float = 6.0
## The speed that the character moves at when crouching.
@export var crouch_speed : float = 1.0

## How fast the character speeds up and slows down when Motion Smoothing is on.
@export var acceleration : float = 10.0
## How high the player jumps.
@export var jump_velocity : float = 4.5
## How far the player turns when the mouse is moved.
@export var mouse_sensitivity : float = 0.1
@export var camera_clamp : Vector2 = Vector2(-80,80)
## How fast the camera rotation smooths (higher = faster). Set to 0 to disable smoothing.
@export var rotation_smoothing_speed : float = 20.0
## Invert the X axis input for the camera.
@export var invert_camera_x_axis : bool = false
## Invert the Y axis input for the camera.
@export var invert_camera_y_axis : bool = false
@export var fov_sprint : float = 80
@export var fov_idle : float = 50
## Whether the player can use movement inputs. Does not stop outside forces or jumping. See Jumping Enabled.
@export var immobile : bool = false
## The reticle file to import at runtime. By default are in res://addons/fpc/reticles/. Set to an empty string to remove.
@export_file var default_reticle

#endregion

#region Nodes Export Group

@export_group("Nodes")
## A reference to the camera for use in the character script. This is the parent node to the camera and is rotated instead of the camera for mouse input.
@export var HEAD : Node3D
## A reference to the camera for use in the character script.
@export var CAMERA : Camera3D
## A reference to the headbob animation for use in the character script.

@export var HEADBOB_ANIMATION : AnimationPlayer
## A reference to the jump animation for use in the character script.
@export var JUMP_ANIMATION : AnimationPlayer
## A reference to the crouch animation for use in the character script.
@export var CROUCH_ANIMATION : AnimationPlayer
## A reference to the the player's collision shape for use in the character script.
@export var COLLISION_MESH : CollisionShape3D
@export var visual_node_3d : Node3D
@export var skeleton_3d : Skeleton3D
#endregion

#region Controls Export Group

# We are using UI controls because they are built into Godot Engine so they can be used right away
@export_group("Controls")
## Use the Input Map to map a mouse/keyboard input to an action and add a reference to it to this dictionary to be used in the script.
@export var controls : Dictionary = {
	LEFT = "move_left",
	RIGHT = "move_right",
	FORWARD = "move_up",
	BACKWARD = "move_down",
	JUMP = "jump",
	CROUCH = "crouch",
	SPRINT = "sprint",
	PAUSE = "ui_cancel",
	INTERACTION = 'interaction',
	BLOCK = 'block'
	}
@export_subgroup("Controller Specific")
## This only affects how the camera is handled, the rest should be covered by adding controller inputs to the existing actions in the Input Map.
@export var controller_support : bool = false
## Use the Input Map to map a controller input to an action and add a reference to it to this dictionary to be used in the script.
@export var controller_controls : Dictionary = {
	LOOK_LEFT = "look_left",
	LOOK_RIGHT = "look_right",
	LOOK_UP = "look_up",
	LOOK_DOWN = "look_down"
	}
## The sensitivity of the analog stick that controls camera rotation. Lower is less sensitive and higher is more sensitive.
@export_range(0.001, 1, 0.001) var look_sensitivity : float = 0.035

#endregion

#region Feature Settings Export Group

@export_group("Feature Settings")
## Enable or disable jumping. Useful for restrictive storytelling environments.
@export var jumping_enabled : bool = true
## Whether the player can move in the air or not.
@export var in_air_momentum : bool = true
## Smooths the feel of walking.
@export var motion_smoothing : bool = true
## Enables or disables sprinting.
@export var sprint_enabled : bool = true
## Toggles the sprinting state when button is pressed or requires the player to hold the button down to remain sprinting.
@export_enum("Hold to Sprint", "Toggle Sprint") var sprint_mode : int = 0
## Enables or disables crouching.
@export var crouch_enabled : bool = true
## Toggles the crouch state when button is pressed or requires the player to hold the button down to remain crouched.
@export_enum("Hold to Crouch", "Toggle Crouch") var crouch_mode : int = 0
## Wether sprinting should effect FOV.
@export var dynamic_fov : bool = true
## If the player holds down the jump button, should the player keep hopping.
@export var continuous_jumping : bool = true
## Enables the view bobbing animation.
@export var view_bobbing : bool = true
## Enables an immersive animation when the player jumps and hits the ground.
@export var jump_animation : bool = true
## This determines wether the player can use the pause button, not wether the game will actually pause.
@export var pausing_enabled : bool = true
## Use with caution.
@export var gravity_enabled : bool = true
## If your game changes the gravity value during gameplay, check this property to allow the player to experience the change in gravity.
@export var dynamic_gravity : bool = false

#endregion


@export var debug_authority : bool = true

#region Member Variable Initialization

# These are variables used in this script that don't need to be exposed in the editor.
var speed : float = base_speed
var current_speed : float = 0.0
# States: normal, crouching, sprinting
@export var state : String = "normal"
var low_ceiling : bool = false # This is for when the ceiling is too low and the player needs to crouch.
var was_on_floor : bool = true # Was the player on the floor last frame (for landing animation)

# The reticle should always have a Control node as the root
var RETICLE : Control

# Get the gravity from the project settings to be synced with RigidBody nodes
var gravity : float = ProjectSettings.get_setting("physics/3d/default_gravity") # Don't set this as a const, see the gravity section in _physics_process

# Stores mouse input for rotating the camera in the physics process
var mouseInput : Vector2 = Vector2(0,0)

# Target rotations for smoothing
var target_head_rotation_x : float = 0.0
var target_character_rotation_y : float = 0.0

# Tracks whether this instance is allowed to process local player input.
var _has_input_authority : bool = false
var _debug_last_should_control : bool = false
var _debug_last_has_input : bool = false
var _debug_last_blocked_reason : String = ""
# Cached peer ID to avoid parsing name every frame
var _cached_peer_id : int = -1
# Cached local peer ID to avoid calling get_unique_id() every frame
var _cached_local_peer_id : int = -1

#endregion



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

	# If the controller is rotated in a certain direction for game design purposes, redirect this rotation into the head.
	HEAD.rotation.y = rotation.y
	rotation.y = 0
	
	# Initialize target rotations to match current rotations
	target_head_rotation_x = HEAD.rotation.x
	target_character_rotation_y = rotation.y

	initialize_animations()
	check_controls()
	enter_normal_state()

	if OS.get_name() == "Web":
		Input.set_use_accumulated_input(false)
	super._ready()
		

func _process(_delta):
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
	_ensure_authority_state()
	#if mesh_animation_player and _has_input_authority:
	if mesh_animation_player:
		play_mesh_animation(input_dir, _has_input_authority, state)
	if !_has_input_authority:
		return
	# Gravity
	if dynamic_gravity:
		gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
	if not is_on_floor() and gravity and gravity_enabled:
		velocity.y -= gravity * delta
	if is_taking_damage == false and is_attacking == false and is_dead() == false and is_blocking == false and is_stun_lock == false and is_blocking_react == false:
		handle_attacking()
		handle_blocking()
		handle_jumping()
		handle_interaction()

	input_dir = Vector2.ZERO

	if not immobile and is_dead() == false and is_taking_damage == false and is_stun_lock == false and is_blocking == false and is_blocking_react == false and is_attacking == false: # Immobility works by interrupting user input, so other forces can still be applied to the player
		input_dir = Input.get_vector(controls.LEFT, controls.RIGHT, controls.FORWARD, controls.BACKWARD)

	handle_movement(delta, input_dir)

	handle_head_rotation()
	apply_rotation_smoothing(delta)

	# The player is not able to stand up if the ceiling is too low
	low_ceiling = $CrouchCeilingDetection.is_colliding()

	handle_state(input_dir)
	if dynamic_fov and _has_input_authority: # This may be changed to an AnimationPlayer
		update_camera_fov()

	if view_bobbing and _has_input_authority:
		play_headbob_animation(input_dir)

	if jump_animation and _has_input_authority:
		play_jump_animation()


	update_debug_menu_per_tick()

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
	if is_blocking:
		return
	is_blocking = true
	mesh_animation_player.play('block', 0.1)
	await mesh_animation_player.animation_finished
	is_blocking = false
	

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
	
	if col is Interactive:
		interaction_feedback_label_3d.text = col.interactive_name
		interaction_feedback_label_3d.visible = true
		interaction_feedback_label_3d.global_position = interaction_ray_cast_3d.get_collision_point()
			
		if Input.is_action_just_pressed(controls.INTERACTION):
			var weapon_path = col.get_path()
			
			# Client sends request to server
			if multiplayer.is_server():
				# If we're the server, process directly
				rpc_request_weapon_pickup(weapon_path, col.interactive_name, col.prefab_path_pickup, col.prefab_path_weapon)
			else:
				# Otherwise send RPC to server (peer ID 1)
				rpc_request_weapon_pickup.rpc_id(1, weapon_path, col.interactive_name, col.prefab_path_pickup, col.prefab_path_weapon)
	else:
		interaction_feedback_label_3d.visible = false
			

@onready var items_bag: Node3D = %ItemsBag

# Client requests weapon pickup from server
@rpc("any_peer", "reliable")
func rpc_request_weapon_pickup(pickup_node_path: NodePath, interactive_name: StringName, prefab_path: StringName, prefab_weapon_path : StringName):
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	# Get requesting peer ID - if called directly (server), use server's peer ID (1)
	var requesting_peer_id = multiplayer.get_unique_id()
	if multiplayer.get_remote_sender_id() != 0:
		requesting_peer_id = multiplayer.get_remote_sender_id()
	
	# Find the weapon node
	var weapon_node = get_node_or_null(pickup_node_path)
	if weapon_node == null or not weapon_node is Interactive:
		return
	
	var weapon = weapon_node as Interactive
	
	# Get the requesting player's character - find via scene tree path
	# Path structure: Main/GameRoot/Players/PlayerSpawner/Player_{peer_id}
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
	
	# Check if player can pick up (inventory not full)
	if requesting_player.carrying_items.size() >= requesting_player.inventory_slots_max:
		return
	
	# Process pickup on server
	# Handle duplicate names by appending a counter
	var final_name = interactive_name
	var counter = 1
	while requesting_player.carrying_items.has(final_name):
		final_name = StringName("%s %d" % [interactive_name, counter+1])
		counter += 1
	
	requesting_player.carrying_items[final_name] = [prefab_path, prefab_weapon_path]
	
	# Clamp selected index if needed
	requesting_player._clamp_selected_index()
	
	# Tell all clients to destroy the weapon
	# Call from server's own character node (peer ID 1) to ensure proper authority
	var server_player = root.get_node_or_null("Main/GameRoot/Players/PlayerSpawner/Player_1")
	if server_player == null:
		# Fallback: find server's player node
		var all_players = get_tree().get_nodes_in_group("players")
		for player in all_players:
			if player.name == "Player_1":
				server_player = player
				break
	
	if server_player != null:
		server_player.rpc_destroy_weapon.rpc(pickup_node_path)
	else:
		# Fallback: call  directly if we can't find server player
		rpc_destroy_weapon.rpc(pickup_node_path)
	
	# Tell requesting client to update their inventory UI
	# If requesting peer is the server, update directly (no RPC needed)
	if requesting_peer_id == 1:
		# Server picking up - update directly
		if requesting_player.inventory_slots_panel_container:
			requesting_player.inventory_slots_panel_container.update_inventory_items_ui(requesting_player.carrying_items, requesting_player.current_selected_item_index)
	else:
		# Client picking up - send RPC to their character node
		requesting_player.rpc_update_inventory.rpc_id(requesting_peer_id, requesting_player.carrying_items)
	
	# Update item in hands for all clients
	var item_keys = requesting_player.carrying_items.keys()
	if item_keys.size() > requesting_player.current_selected_item_index:
		var selected_item_path = requesting_player.carrying_items[item_keys[requesting_player.current_selected_item_index]][1]
		requesting_player.rpc_update_item_in_hands.rpc(requesting_player.current_selected_item_index, selected_item_path)
	else:
		requesting_player.rpc_update_item_in_hands.rpc(-1, "")  # No item selected
	
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

# Server tells requesting client to update their inventory UI
# This RPC can be called by the server from any character node
@rpc("any_peer", "reliable")
func rpc_update_inventory(inventory: Dictionary[StringName, Array]):
	# Only process if called from server (peer ID 1)
	# When client receives this, remote_sender_id will be 1 (server)
	if !multiplayer.is_server():
		if multiplayer.get_remote_sender_id() != 1:
			return
	# Server can also process this locally if needed
	carrying_items = inventory
	_clamp_selected_index()
	if inventory_slots_panel_container:
		inventory_slots_panel_container.update_inventory_items_ui(carrying_items, current_selected_item_index)
	
	# Equip the currently selected item to ensure it shows up in hands
	var item_keys = carrying_items.keys()
	if item_keys.size() > current_selected_item_index and current_selected_item_index >= 0:
		var selected_item_path = carrying_items[item_keys[current_selected_item_index]][1]
		rpc_update_item_in_hands(current_selected_item_index, selected_item_path)
	else:
		rpc_update_item_in_hands(-1, "")  # No item selected

func handle_attacking():
	if !_has_input_authority:
		return
	if is_attacking:
		return
	if Input.is_action_just_pressed("attack"):
		rpc_melee_attack.rpc()
		
@rpc("call_local")
func rpc_melee_attack():
	
	# Apply forward push when attacking
	if item_in_hands != null:
		var push_force = item_in_hands.push_forward_on_attack_force
		if push_force > 0:
			# Get forward direction from camera/head (where player is looking)
			# Use camera forward direction if available, otherwise use head
			var forward_direction: Vector3
			if CAMERA != null:
				forward_direction = -CAMERA.global_transform.basis.z.normalized()
			else:
				forward_direction = -HEAD.global_transform.basis.z.normalized()
			# Ignore Y component for horizontal push
			forward_direction.y = 0
			forward_direction = forward_direction.normalized()
			velocity += forward_direction * push_force
	
	var attack_string = ''
	if input_dir.y != 0:
		attack_string = 'attack_vertical'
	elif input_dir.x != 0:
		attack_string = 'attack_horizontal'
	else:
		attack_string = ['attack_vertical', 'attack_horizontal'].pick_random()
	mesh_animation_player.play(attack_string, 0.1)
	is_attacking = true
	if item_in_hands:
		item_in_hands.set_dangerous(true, self)
	await mesh_animation_player.animation_finished
	if item_in_hands:
		item_in_hands.set_dangerous(false, self)
	is_attacking = false

func handle_jumping():
	if !_has_input_authority:
		return
	if jumping_enabled:
		if continuous_jumping: # Hold down the jump button
			if Input.is_action_pressed(controls.JUMP) and is_on_floor() and !low_ceiling:
				if jump_animation:
					JUMP_ANIMATION.play("jump", 0.25)
				velocity.y += jump_velocity # Adding instead of setting so jumping on slopes works properly
		else:
			if Input.is_action_just_pressed(controls.JUMP) and is_on_floor() and !low_ceiling:
				if jump_animation:
					JUMP_ANIMATION.play("jump", 0.25)
				velocity.y += jump_velocity


func handle_movement(delta, input_dir):
	if !_has_input_authority:
		return

	var direction = input_dir.rotated(-rotation.y)
	if is_attacking or is_blocking:
		velocity.x = lerpf(velocity.x, velocity.x * 0.1, 10 * get_process_delta_time())
		velocity.z = lerpf(velocity.z, velocity.z * 0.1, 10 * get_process_delta_time())
		move_and_slide()
		return
		
	direction = Vector3(direction.x, 0, direction.y)
		
	move_and_slide()

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

	mouseInput = Vector2(0,0)
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
						"sprinting":
							enter_normal_state()
			elif state == "sprinting":
				enter_normal_state()

	if crouch_enabled:
		if crouch_mode == 0:
			if Input.is_action_pressed(controls.CROUCH) and state != "sprinting":
				if state != "crouching":
					enter_crouch_state()
			elif state == "crouching" and !$CrouchCeilingDetection.is_colliding():
				enter_normal_state()
		elif crouch_mode == 1:
			if Input.is_action_just_pressed(controls.CROUCH):
				match state:
					"normal":
						enter_crouch_state()
					"crouching":
						if !$CrouchCeilingDetection.is_colliding():
							enter_normal_state()


# Any enter state function should only be called once when you want to enter that state, not every frame.
func enter_normal_state():
	#print("entering normal state")
	var prev_state = state
	if prev_state == "crouching":
		CROUCH_ANIMATION.play_backwards("crouch")
	state = "normal"
	speed = base_speed

func enter_crouch_state():
	#print("entering crouch state")
	state = "crouching"
	speed = crouch_speed
	CROUCH_ANIMATION.play("crouch")

func enter_sprint_state():
	#print("entering sprint state")
	var prev_state = state
	if prev_state == "crouching":
		CROUCH_ANIMATION.play_backwards("crouch")
	state = "sprinting"
	speed = sprint_speed

#endregion

#region Animation Handling

func initialize_animations():
	# Reset the camera position
	# If you want to change the default head height, change these animations.
	HEADBOB_ANIMATION.play("RESET")
	JUMP_ANIMATION.play("RESET")
	CROUCH_ANIMATION.play("RESET")

func play_headbob_animation(moving):
	if !_has_input_authority:
		return
	if moving and is_on_floor():
		var use_headbob_animation : String
		match state:
			"normal","crouching":
				use_headbob_animation = "walk"
			"sprinting":
				use_headbob_animation = "sprint"

		var was_playing : bool = false
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
		var facing_direction : Vector3 = CAMERA.get_global_transform().basis.x
		var facing_direction_2D : Vector2 = Vector2(facing_direction.x, facing_direction.z).normalized()
		var velocity_2D : Vector2 = Vector2(velocity.x, velocity.z).normalized()

		# Compares velocity direction against the camera direction (via dot product) to determine which landing animation to play.
		var side_landed : int = round(velocity_2D.dot(facing_direction_2D))

		if side_landed > 0:
			JUMP_ANIMATION.play("land_right", 0.25)
		elif side_landed < 0:
			JUMP_ANIMATION.play("land_left", 0.25)
		else:
			JUMP_ANIMATION.play("land_center", 0.25)

#endregion

#region Debug Menu

func update_debug_menu_per_frame():
	$UserInterface/DebugPanel.add_property("FPS", Performance.get_monitor(Performance.TIME_FPS), 0)
	var status : String = state
	if !is_on_floor():
		status += " in the air"
	$UserInterface/DebugPanel.add_property("State", status, 4)


func update_debug_menu_per_tick():
	# Big thanks to github.com/LorenzoAncora for the concept of the improved debug values
	current_speed = Vector3.ZERO.distance_to(get_real_velocity())
	$UserInterface/DebugPanel.add_property("Speed", snappedf(current_speed, 0.001), 1)
	$UserInterface/DebugPanel.add_property("Target speed", speed, 2)
	var cv : Vector3 = get_real_velocity()
	var vd : Array[float] = [
		snappedf(cv.x, 0.001),
		snappedf(cv.y, 0.001),
		snappedf(cv.z, 0.001)
	]
	var readable_velocity : String = "X: " + str(vd[0]) + " Y: " + str(vd[1]) + " Z: " + str(vd[2])
	$UserInterface/DebugPanel.add_property("Velocity", readable_velocity, 3)


func _unhandled_input(event : InputEvent):
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
	current_selected_item_index += delta
	
	# Wrap around
	if current_selected_item_index < 0:
		current_selected_item_index = item_count - 1
	elif current_selected_item_index >= item_count:
		current_selected_item_index = 0
	
	# Update UI
	if inventory_slots_panel_container:
		inventory_slots_panel_container.update_inventory_items_ui(carrying_items, current_selected_item_index)
	# Get the item path before calling RPC
	var item_keys = carrying_items.keys()
	if item_keys.size() > current_selected_item_index:
		var selected_item_path = carrying_items[item_keys[current_selected_item_index]][1]
		rpc_update_item_in_hands.rpc(current_selected_item_index, selected_item_path)
	else:
		rpc_update_item_in_hands.rpc(-1, "")  # No item selected
	

@onready var weapon_bone_attachment_3d: BoneAttachment3D = %WeaponBoneAttachment3D

@rpc("any_peer", "call_local", "reliable")
func rpc_update_item_in_hands(item_index: int, item_path: String):
	# Allow server calls, local calls (call_local), or calls from the character's owner
	var sender_id = multiplayer.get_remote_sender_id()
	if multiplayer.is_server():
		# On server: allow if it's a local call (sender_id == 0) or if sender has authority over this character
		if sender_id != 0:
			if sender_id != get_multiplayer_authority():
				return
	else:
		# On clients: allow if it's a local call (sender_id == 0) or from server (sender_id == 1)
		# Also allow if sender matches this character's authority (owner calling for themselves)
		if sender_id != 0 and sender_id != 1:
			# Check if sender has authority over this character
			if sender_id != get_multiplayer_authority():
				return
	
	# Update the selected item index to keep it in sync
	current_selected_item_index = item_index
	
	if item_in_hands != null:
		item_in_hands.queue_free()
		item_in_hands = null
	
	# If no item selected (item_index < 0 or empty path), don't spawn anything
	if item_index < 0 or item_path == "":
		return
	
	# Use the provided item_path instead of relying on carrying_items
	item_in_hands = load(item_path).instantiate()
	if item_in_hands == null:
		push_error("Failed to load item: " + item_path)
		return
	
	weapon_bone_attachment_3d.add_child(item_in_hands)
	item_in_hands.position = item_in_hands.weapon_slot_position
	item_in_hands.scale = Vector3.ONE * 100

	
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


func _refresh_authority_state(force : bool = false):
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
		synchronizer.visibility_update_mode = 1  # On Change

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

func _debug_print(message : String) -> void:
	if !debug_authority:
		return
	var prefix := "[CharacterAuth]"
	var peer_desc := "local"
	if multiplayer and multiplayer.has_multiplayer_peer():
		peer_desc = "peer=%s" % str(multiplayer.get_unique_id())
	print("%s %s %s -> %s" % [prefix, name, peer_desc, message])


func _debug_authority_context() -> String:
	var parts : Array[String] = []
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


func _debug_report_input_block(source : String) -> void:
	if !debug_authority:
		return
	if _debug_last_blocked_reason == source:
		return
	_debug_last_blocked_reason = source
	var ctx := _debug_authority_context()
	_debug_print("Input blocked at %s (%s)" % [source, ctx])


func _debug_clear_block_reason(source : String) -> void:
	if !debug_authority:
		return
	if _debug_last_blocked_reason == source:
		_debug_last_blocked_reason = ""
		var ctx := _debug_authority_context()
		_debug_print("Input restored after %s (%s)" % [source, ctx])

func death():
	super.death()
	if _has_input_authority:
		enter_crouch_state()
		await get_tree().create_timer(5).timeout
		rpc_full_heal_and_resurrect.rpc()
		enter_normal_state()


func cheat_codes():
	#if Input.is_key_label_pressed(KEY_G) and Input.is_key_label_pressed(KEY_Z) and Input.is_key_label_pressed(KEY_H):
		#rpc_full_heal_and_resurrect.rpc()
		#if _has_input_authority:
			#enter_normal_state()

	pass
