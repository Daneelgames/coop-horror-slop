extends Unit
class_name AiCharacter
@export var input_dir : Vector2
@export var random_weapons_paths : Array[StringName]
var state = 'normal'
 
@onready var weapon_bone_attachment_3d: BoneAttachment3D = %WeaponBoneAttachment3D

func _enter_tree():
	# Set multiplayer authority to server (peer ID 1) for AI characters
	if multiplayer.has_multiplayer_peer():
		set_multiplayer_authority(1, true)

func _ready():
	is_blocking = false
	is_attacking = false
	is_taking_damage = false
	# Wait a frame to ensure node is fully ready and synced across all clients
	await get_tree().process_frame
	spawn_random_weapon_to_hands()

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

func _physics_process(_delta): # Most things happen here.
	if mesh_animation_player:
		play_mesh_animation(input_dir, true, state)
	handle_blocking()

#region Input Handling
func handle_blocking():
	if is_blocking or is_attacking or is_dead() or is_taking_damage:
		return
	# AI characters are server-controlled, so call blocking directly (no RPC needed)
	# The is_blocking variable will be synced via MultiplayerSynchronizer
	_start_blocking()

func _start_blocking():
	if is_blocking:
		return
	is_blocking = true
	mesh_animation_player.play('block', 0.1)
	await mesh_animation_player.animation_finished
	is_blocking = false
	
