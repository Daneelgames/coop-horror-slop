extends Node

const GAME_LEVEL_SCENE_PATH := "res://assets/scenes/game_level.tscn"
const PLAYER_SCENE_PATH := "res://addons/fpc/character.tscn"
const AI_CHARACTER_SCENE_PATH := "res://addons/fpc/ai_character.tscn"
const GAME_LEVEL_SCENE : PackedScene = preload(GAME_LEVEL_SCENE_PATH)
const PLAYER_SCENE : PackedScene = preload(PLAYER_SCENE_PATH)
const AI_CHARACTER_SCENE : PackedScene = preload(AI_CHARACTER_SCENE_PATH)

var main_menu : CanvasLayer
var lobby : CanvasLayer
var main : Main

var _game_root : Node3D
var _game_spawner : MultiplayerSpawner
var _game_level : Node
var _spawner_has_game_level : bool = false
var _player_root : Node3D
var _player_spawner : MultiplayerSpawner
var _player_nodes : Dictionary = {}
var _player_signals_connected : bool = false
var _mob_spawner : MultiplayerSpawner
var particles_manager : ParticlesManager
var ai_visibility_manager : AiVisibilityManager
var ai_hearing_manager : AiHearingManager

# Dungeon seed synchronization
var dungeon_seed: int = 0
var dungeon_seed_received: bool = false
signal dungeon_seed_synced(seed_value: int)

func _ready() -> void:
	_check_launch_args()

func create_main_menu() -> CanvasLayer:
	if is_instance_valid(main_menu):
		main_menu.queue_free()
		main_menu.get_parent().remove_child(main_menu)
	var mm : CanvasLayer = load("res://assets/scenes/ui/main_menu.tscn").instantiate()
	main_menu = mm
	return mm

func create_lobby() -> CanvasLayer:
	var lob : CanvasLayer = load("res://assets/scenes/ui/lobby.tscn").instantiate()
	lobby = lob
	return lob

func _check_launch_args() -> void:
	var args = OS.get_cmdline_args()
	if "--no-sound" in args:
		var master_bus_index = AudioServer.get_bus_index("Master")
		AudioServer.set_bus_mute(master_bus_index, true)
	if "--host" in args:
		await get_tree().create_timer(0.5).timeout
		NetworkManager._on_host_lan()
	if "--join" in args:
		await get_tree().create_timer(1.5).timeout
		NetworkManager._on_join_lan()

func _spawn_player_scene(peer_id: int) -> Node:
	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return player

func _spawn_pickup_scene(pickup_prefab_path: String) -> Node:
	var pickup_scene = load(pickup_prefab_path)
	if pickup_scene == null:
		return null
	var pickup: Node = pickup_scene.instantiate()
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return pickup

func start_multiplayer_game():
	if !multiplayer.is_server():
		push_warning("start_multiplayer_game called on a non-authority peer.")
		return
	_start_multiplayer_game.rpc()

@rpc("authority", "call_local")
func _start_multiplayer_game() -> void:
	if !is_instance_valid(main):
		push_warning("Main node is not ready, cannot start multiplayer game.")
		return
	_teardown_lobby()
	_ensure_game_root()
	_ensure_game_spawner()
	_ensure_player_root()
	_ensure_player_spawner()
	_ensure_mob_spawner()
	if multiplayer.is_server():
		# Generate dungeon seed before spawning game level
		dungeon_seed = int(Time.get_unix_time_from_system())
		dungeon_seed_received = true
		print("GameManager: Host generated dungeon seed: ", dungeon_seed)
		# Send seed to all clients
		_sync_dungeon_seed.rpc(dungeon_seed)
		_spawn_game_level()
		_setup_player_multiplayer_signals()
		_spawn_existing_players()
	else:
		# Client waits for seed
		dungeon_seed_received = false
	call_deferred("_cache_spawned_game_level")

func _teardown_lobby() -> void:
	if is_instance_valid(lobby):
		var parent := lobby.get_parent()
		if is_instance_valid(parent):
			parent.remove_child(lobby)
		lobby.queue_free()
	lobby = null

func _ensure_game_root() -> void:
	if is_instance_valid(_game_root):
		return
	_game_root = Node3D.new()
	_game_root.name = "GameRoot"
	main.add_child(_game_root)

func _ensure_game_spawner() -> void:
	if !is_instance_valid(_game_spawner):
		_game_spawner = MultiplayerSpawner.new()
		_game_spawner.name = "GameLevelSpawner"
		_game_spawner.spawn_path = NodePath(".")
		_game_spawner.spawn_function = Callable(self, "_spawn_pickup_scene")
		_game_root.add_child(_game_spawner)
	if !_spawner_has_game_level:
		_game_spawner.add_spawnable_scene(GAME_LEVEL_SCENE_PATH)
		_spawner_has_game_level = true

func _spawn_game_level() -> void:
	if is_instance_valid(_game_level):
		return
	_game_level = GAME_LEVEL_SCENE.instantiate()
	_game_spawner.add_child(_game_level)

func _cache_spawned_game_level() -> void:
	if !is_instance_valid(_game_spawner):
		return
	for child in _game_spawner.get_children():
		if child is Node and child.name == "GameLevel":
			_game_level = child
			# Update mob spawner path to point to GameLevel
			if is_instance_valid(_mob_spawner):
				var game_level_path = _mob_spawner.get_path_to(_game_level)
				_mob_spawner.spawn_path = game_level_path
			return

func _ensure_player_root() -> void:
	if is_instance_valid(_player_root):
		return
	_player_root = Node3D.new()
	_player_root.name = "Players"
	_game_root.add_child(_player_root)

func _ensure_player_spawner() -> void:
	if !is_instance_valid(_player_spawner):
		_player_spawner = MultiplayerSpawner.new()
		_player_spawner.name = "PlayerSpawner"
		_player_spawner.spawn_path = NodePath(".")
		_player_root.add_child(_player_spawner)
		# Set spawn function after spawner is created
		_player_spawner.spawn_function = Callable(self, "_spawn_player_scene")

func _ensure_mob_spawner() -> void:
	if !is_instance_valid(_mob_spawner):
		_mob_spawner = MultiplayerSpawner.new()
		_mob_spawner.name = "MobSpawner"
		_game_root.add_child(_mob_spawner)
		# Set spawn function for mobs
		_mob_spawner.spawn_function = Callable(self, "_spawn_mob_scene")
		# Add AI character scene to spawnable scenes
		_mob_spawner.add_spawnable_scene(AI_CHARACTER_SCENE_PATH)

func _spawn_mob_scene(spawn_data_dict: Dictionary) -> Node:
	# spawn_data_dict should contain: mob_name, position, home_position
	var mob := AI_CHARACTER_SCENE.instantiate()
	var mob_name = spawn_data_dict.get("mob_name", "Mob_Unknown")
	mob.name = mob_name
	
	var position = spawn_data_dict.get("position", Vector3.ZERO)
	var home_position = spawn_data_dict.get("home_position", Vector3.ZERO)
	
	mob.position = position
	if mob is AiCharacter:
		mob.home_position = home_position
	
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return mob

# Public function to spawn a mob through MultiplayerSpawner
func spawn_mob(mob_name: String, position: Vector3, home_position: Vector3) -> void:
	if !multiplayer.is_server():
		return
	
	if !is_instance_valid(_mob_spawner):
		push_error("MobSpawner not initialized!")
		return
	
	# Ensure spawn_path is set correctly
	if !is_instance_valid(_game_level):
		push_error("GameLevel not available for mob spawning!")
		return
	
	var game_level_path = _mob_spawner.get_path_to(_game_level)
	_mob_spawner.spawn_path = game_level_path
	
	# Create spawn data dictionary
	var spawn_data = {
		"mob_name": mob_name,
		"position": position,
		"home_position": home_position
	}
	
	# Spawn on all peers (use 1 as peer_id for server authority)
	var mob = _mob_spawner.spawn(spawn_data) as Node
	if mob:
		# Set multiplayer authority to server (peer ID 1) for AI control
		if multiplayer.has_multiplayer_peer():
			mob.set_multiplayer_authority(1, true)

func _spawn_existing_players() -> void:
	for peer_id in NetworkManager.players.keys():
		_spawn_player_for(peer_id)

func _spawn_player_for(peer_id: int) -> void:
	if _player_nodes.has(peer_id):
		var existing: Node = _player_nodes[peer_id]
		if is_instance_valid(existing):
			return
	var player := _player_spawner.spawn(peer_id) as Node
	if player:
		_player_nodes[peer_id] = player
		await get_tree().process_frame
		player.global_position = Vector3(randf_range(-5,5),0, randf_range(-5,5))
		# Authority is set in character.gd _enter_tree() based on the character name

func _setup_player_multiplayer_signals() -> void:
	if _player_signals_connected:
		return
	multiplayer.peer_connected.connect(_on_peer_connected_to_game)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected_from_game)
	_player_signals_connected = true

func _on_peer_connected_to_game(peer_id: int) -> void:
	if !multiplayer.is_server():
		return
	_spawn_player_for(peer_id)

func _on_peer_disconnected_from_game(peer_id: int) -> void:
	if _player_nodes.has(peer_id):
		var node: Node = _player_nodes[peer_id]
		if is_instance_valid(node):
			node.queue_free()
		_player_nodes.erase(peer_id)

# Helper functions to serialize/deserialize ResourceWeapon for RPC
func serialize_weapon_resource(weapon_resource: ResourceWeapon) -> Dictionary:
	if weapon_resource == null:
		return {}
	return {
		"weapon_name": weapon_resource.weapon_name,
		"weapon_type": weapon_resource.weapon_type,
		"pickup_prefab_path": weapon_resource.pickup_prefab_path,
		"weapon_prefab_path": weapon_resource.weapon_prefab_path,
		"damage_min_max": weapon_resource.damage_min_max,
		"weapon_blocking_angle": weapon_resource.weapon_blocking_angle,
		"push_forward_on_attack_force": weapon_resource.push_forward_on_attack_force,
		"weapon_durability_current": weapon_resource.weapon_durability_current,
		"weapon_durability_max": weapon_resource.weapon_durability_max,
		"reducing_durability_when_in_hands": weapon_resource.reducing_durability_when_in_hands,
		"in_hands_reduce_durability_speed": weapon_resource.in_hands_reduce_durability_speed
	}

func deserialize_weapon_resource(data: Dictionary) -> ResourceWeapon:
	if data.is_empty():
		return null
	var weapon_resource = ResourceWeapon.new()
	weapon_resource.weapon_name = data.get("weapon_name", &'Weapon')
	weapon_resource.weapon_type = data.get("weapon_type", ResourceWeapon.WEAPON_TYPE.TORCH)
	weapon_resource.pickup_prefab_path = data.get("pickup_prefab_path", "")
	weapon_resource.weapon_prefab_path = data.get("weapon_prefab_path", "")
	weapon_resource.damage_min_max = data.get("damage_min_max", Vector2i(30, 60))
	weapon_resource.weapon_blocking_angle = data.get("weapon_blocking_angle", 160)
	weapon_resource.push_forward_on_attack_force = data.get("push_forward_on_attack_force", 5.0)
	weapon_resource.weapon_durability_current = data.get("weapon_durability_current", 100.0)
	weapon_resource.weapon_durability_max = data.get("weapon_durability_max", 100.0)
	weapon_resource.reducing_durability_when_in_hands = data.get("reducing_durability_when_in_hands", false)
	weapon_resource.in_hands_reduce_durability_speed = data.get("in_hands_reduce_durability_speed", 0.5)
	return weapon_resource

# RPC function to handle pickup requests from clients
# This is needed for procedurally spawned pickups that aren't synchronized
# Dropped pickups (synchronized via MultiplayerSpawner) should use direct RPC call instead
@rpc("any_peer", "reliable")
func rpc_request_pickup_by_name(pickup_name: String) -> void:
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	# Find the pickup by name only - procedurally spawned pickups have consistent names
	var pickup: Interactive = null
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned pickups
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			pickup = dungeon_tiles.get_node_or_null(pickup_name) as Interactive
		
		# If not found, check GameLevel directly for dropped pickups
		if pickup == null:
			pickup = _game_level.get_node_or_null(pickup_name) as Interactive
	
	if pickup != null:
		# Call the pickup's internal function directly (no RPC needed on server)
		pickup._process_pickup_request()
	else:
		print("[GameManager] Could not find pickup '%s'" % pickup_name)

# RPC function to destroy pickups by name (needed for procedurally spawned pickups)
@rpc("any_peer", "call_local", "reliable")
func rpc_destroy_pickup_by_name(pickup_name: String) -> void:
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	# Find the pickup by name only - procedurally spawned pickups have consistent names
	var pickup: Interactive = null
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned pickups
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			pickup = dungeon_tiles.get_node_or_null(pickup_name) as Interactive
		
		# If not found, check GameLevel directly for dropped pickups
		if pickup == null:
			pickup = _game_level.get_node_or_null(pickup_name) as Interactive
	
	if pickup != null:
		print("[GameManager] Destroying pickup: %s" % pickup.name)
		pickup.queue_free()
	else:
		print("[GameManager] Could not find pickup '%s' to destroy" % pickup_name)

@rpc("authority", "call_local", "reliable")
func _sync_dungeon_seed(seed_value: int) -> void:
	dungeon_seed = seed_value
	dungeon_seed_received = true
	print("GameManager: Synced dungeon seed: ", dungeon_seed)
	dungeon_seed_synced.emit(dungeon_seed)
