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

var party_money = 0
signal party_money_changed

# Dungeon seed synchronization
var dungeon_seed: int = 0
var dungeon_seed_received: bool = false
signal dungeon_seed_synced(seed_value: int)
signal all_players_are_dead

func _ready() -> void:
	_check_launch_args()
	check_all_players_dead_coroutine()
func check_all_players_dead_coroutine():
	var all_dead = _player_nodes.values().size() > 0
	for player : PlayerCharacter in _player_nodes.values():
		if player.is_dead() == false:
			all_dead = false
			break
	
	if all_dead:
		all_players_are_dead.emit()
			
	await get_tree().create_timer(1).timeout
	check_all_players_dead_coroutine()

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
	if pickup_prefab_path.is_empty():
		push_error("GameManager._spawn_pickup_scene: Empty pickup_prefab_path!")
		return null
	var pickup_scene = load(pickup_prefab_path)
	if pickup_scene == null:
		push_error("GameManager._spawn_pickup_scene: Failed to load scene from path: %s" % pickup_prefab_path)
		return null
	var pickup: Node = pickup_scene.instantiate()
	if pickup == null:
		push_error("GameManager._spawn_pickup_scene: Failed to instantiate scene from path: %s" % pickup_prefab_path)
		return null
	# Set a temporary unique name to avoid conflicts when MultiplayerSpawner adds it to tree
	# This name will be used for synchronization - caller can rename it after spawn if needed
	# Using a more unique name to avoid conflicts
	pickup.name = "Pickup_%d_%d" % [Time.get_ticks_msec(), randi()]
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return pickup

func _spawn_prop_scene(prop_prefab_path: String) -> Node:
	if prop_prefab_path.is_empty():
		push_error("GameManager._spawn_prop_scene: Empty prop_prefab_path!")
		return null
	var prop_scene = load(prop_prefab_path)
	if prop_scene == null:
		push_error("GameManager._spawn_prop_scene: Failed to load scene from path: %s" % prop_prefab_path)
		return null
	var prop: Node = prop_scene.instantiate()
	if prop == null:
		push_error("GameManager._spawn_prop_scene: Failed to instantiate scene from path: %s" % prop_prefab_path)
		return null
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return prop

func _spawn_elevator_scene(elevator_prefab_path: String) -> Node:
	if elevator_prefab_path.is_empty():
		push_error("GameManager._spawn_elevator_scene: Empty elevator_prefab_path!")
		return null
	var elevator_scene = load(elevator_prefab_path)
	if elevator_scene == null:
		push_error("GameManager._spawn_elevator_scene: Failed to load scene from path: %s" % elevator_prefab_path)
		return null
	var elevator: Node = elevator_scene.instantiate()
	if elevator == null:
		push_error("GameManager._spawn_elevator_scene: Failed to instantiate scene from path: %s" % elevator_prefab_path)
		return null
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return elevator

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
		_game_spawner.spawn_function = Callable(self, "_spawn_game_object")
		_game_root.add_child(_game_spawner)
	if !_spawner_has_game_level:
		_game_spawner.add_spawnable_scene(GAME_LEVEL_SCENE_PATH)
		_spawner_has_game_level = true

# Universal spawn function for game objects (pickups, props, etc.)
func _spawn_game_object(spawn_data) -> Node:
	# spawn_data can be a String/StringName (prefab path) or Dictionary with "type" and "path"
	# MultiplayerSpawner may pass StringName instead of String
	if spawn_data is String or spawn_data is StringName:
		# Simple string path - treat as pickup (backward compatibility)
		var path_str = str(spawn_data)  # Convert StringName to String
		var result = _spawn_pickup_scene(path_str)
		if result == null:
			push_error("GameManager._spawn_game_object: Failed to spawn pickup from path: %s" % path_str)
		return result
	elif spawn_data is Dictionary:
		var obj_type = spawn_data.get("type", "pickup")
		var obj_path = spawn_data.get("path", "")
		if obj_path.is_empty():
			push_error("GameManager._spawn_game_object: Empty path in spawn_data: %s" % spawn_data)
			return null
		# Convert StringName to String if needed
		var path_str = str(obj_path)
		var result: Node = null
		if obj_type == "prop":
			result = _spawn_prop_scene(path_str)
		elif obj_type == "elevator":
			result = _spawn_elevator_scene(path_str)
		else:
			result = _spawn_pickup_scene(path_str)
		if result == null:
			push_error("GameManager._spawn_game_object: Failed to spawn %s from path: %s" % [obj_type, path_str])
		return result
	else:
		push_error("GameManager._spawn_game_object: Invalid spawn_data type: %s (value: %s)" % [typeof(spawn_data), spawn_data])
		return null

func _spawn_game_level() -> void:
	if is_instance_valid(_game_level):
		return
	
	# Instantiate the scene first to check its structure
	_game_level = GAME_LEVEL_SCENE.instantiate()
	print("GameManager._spawn_game_level: Instantiated GameLevel, children count: ", _game_level.get_child_count())
	for child in _game_level.get_children():
		print("GameManager._spawn_game_level: Child: ", child.name, " (", child.get_class(), ")")
	
	# Add to spawner - MultiplayerSpawner will sync it to all clients
	# Note: When using add_spawnable_scene, we should use spawn() method, but for root level scenes
	# that are added directly, add_child() should work. However, all children must be properly synced.
	_game_spawner.add_child(_game_level)
	
	# Verify after adding
	print("GameManager._spawn_game_level: After add_child, children count: ", _game_level.get_child_count())
	if _game_level.get_child_count() == 0:
		push_error("GameManager._spawn_game_level: WARNING - GameLevel has no children after instantiation!")

func _cache_spawned_game_level() -> void:
	if !is_instance_valid(_game_spawner):
		return
	for child in _game_spawner.get_children():
		if child is Node and child.name == "GameLevel":
			_game_level = child
			# Set spawn_path for GameSpawner to DungeonTiles (for props and pickups)
			var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
			if dungeon_tiles != null and is_instance_valid(_game_spawner):
				var dungeon_tiles_path = _game_spawner.get_path_to(dungeon_tiles)
				_game_spawner.spawn_path = dungeon_tiles_path
				print("GameManager: GameSpawner spawn_path set to DungeonTiles (is_server: %s, path: %s)" % [
					multiplayer.is_server(),
					dungeon_tiles_path
				])
			
			# Set spawn_path now that GameLevel exists (on all clients)
			if is_instance_valid(_mob_spawner):
				# Use relative path from MobSpawner to GameLevel
				# Structure: GameRoot -> GameLevelSpawner -> GameLevel
				# From MobSpawner (child of GameRoot): ../GameLevelSpawner/GameLevel
				_mob_spawner.spawn_path = NodePath("../GameLevelSpawner/GameLevel")
				# Verify the path is valid
				var spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
				if is_instance_valid(spawn_parent):
					print("GameManager: MobSpawner spawn_path set successfully to GameLevel (is_server: %s, path: %s, parent: %s)" % [
						multiplayer.is_server(), 
						_mob_spawner.spawn_path,
						spawn_parent.get_path()
					])
					# Verify MultiplayerSpawner is configured correctly
					print("GameManager: MobSpawner config - spawn_path: %s, spawn_function: %s" % [
						_mob_spawner.spawn_path,
						"set" if _mob_spawner.spawn_function != null else "null"
					])
				else:
					# Fallback: use absolute path from scene root
					var game_level_path = _mob_spawner.get_path_to(_game_level)
					_mob_spawner.spawn_path = game_level_path
					spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
					if is_instance_valid(spawn_parent):
						print("GameManager: MobSpawner spawn_path set to absolute path: %s (is_server: %s, parent: %s)" % [
							game_level_path, 
							multiplayer.is_server(),
							spawn_parent.get_path()
						])
					else:
						push_error("GameManager: Failed to set MobSpawner spawn_path on %s!" % ("SERVER" if multiplayer.is_server() else "CLIENT"))
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
		# Set spawn_path to GameLevel (will be set properly in _cache_spawned_game_level)
		# Use relative path that should work once GameLevel exists
		_mob_spawner.spawn_path = NodePath("../GameLevelSpawner/GameLevel")

func _spawn_mob_scene(spawn_data_dict: Dictionary) -> Node:
	# spawn_data_dict should contain: mob_name, position, home_position, mob_prefab_path
	# This function is called by MultiplayerSpawner on both server and clients

	var mob_prefab_path = spawn_data_dict.get("mob_prefab_path", "")
	var mob: Node

	if mob_prefab_path != "" and ResourceLoader.exists(mob_prefab_path):
		var prefab = load(mob_prefab_path)
		if prefab:
			mob = prefab.instantiate()
		else:
			push_error("Failed to load mob prefab: %s" % mob_prefab_path)
			mob = AI_CHARACTER_SCENE.instantiate()
	else:
		mob = AI_CHARACTER_SCENE.instantiate()

	var mob_name = spawn_data_dict.get("mob_name", "Mob_Unknown")
	mob.name = mob_name
	
	var position = spawn_data_dict.get("position", Vector3.ZERO)
	var home_position = spawn_data_dict.get("home_position", Vector3.ZERO)
	
	mob.position = position
	if mob is AiCharacter:
		mob.home_position = home_position
	
	var peer_id_str = str(multiplayer.get_unique_id()) if multiplayer.has_multiplayer_peer() else "N/A"
	print("GameManager: _spawn_mob_scene called for %s (is_server: %s, peer_id: %s)" % [
		mob_name, 
		multiplayer.is_server(),
		peer_id_str
	])
	
	# Verify spawn_path is set on clients too
	if !multiplayer.is_server() and is_instance_valid(_mob_spawner):
		print("GameManager [CLIENT]: MobSpawner spawn_path: %s" % _mob_spawner.spawn_path)
		var spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
		if is_instance_valid(spawn_parent):
			print("GameManager [CLIENT]: Spawn parent is valid: %s" % spawn_parent.get_path())
		else:
			push_error("GameManager [CLIENT]: Spawn parent is INVALID! Path: %s" % _mob_spawner.spawn_path)
	
	# Note: Don't add to scene tree here - MultiplayerSpawner handles that
	return mob

# Public function to spawn a mob through MultiplayerSpawner
# This should ONLY be called on the server - uses RPC to ensure clients spawn too
func spawn_mob(mob_name: String, position: Vector3, home_position: Vector3, mob_prefab_path: String = "") -> void:
	if !multiplayer.is_server():
		push_error("spawn_mob called on client! This should only be called on server.")
		return
	
	if !is_instance_valid(_mob_spawner):
		push_error("MobSpawner not initialized!")
		return
	
	# Verify that GameLevel exists
	if !is_instance_valid(_game_level):
		push_error("GameLevel not available for mob spawning!")
		return
	
	# Ensure spawn_path is set correctly (should already be set in _cache_spawned_game_level)
	if _mob_spawner.spawn_path.is_empty() or _mob_spawner.spawn_path == NodePath():
		# Set spawn_path if not already set
		var game_level_path = _mob_spawner.get_path_to(_game_level)
		_mob_spawner.spawn_path = game_level_path
		print("GameManager [SERVER]: Setting MobSpawner spawn_path to: ", game_level_path)
	
	# Verify spawn_path points to a valid node
	var spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
	if !is_instance_valid(spawn_parent):
		push_error("MobSpawner spawn_path is invalid: %s (GameLevel exists: %s)" % [_mob_spawner.spawn_path, is_instance_valid(_game_level)])
		# Try to fix it
		var game_level_path = _mob_spawner.get_path_to(_game_level)
		_mob_spawner.spawn_path = game_level_path
		spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
		if !is_instance_valid(spawn_parent):
			push_error("Failed to fix MobSpawner spawn_path!")
			return
	
	# Create spawn data dictionary
	var spawn_data = {
		"mob_name": mob_name,
		"position": position,
		"home_position": home_position,
		"mob_prefab_path": mob_prefab_path
	}
	
	# Spawn on server first
	print("GameManager [SERVER]: Spawning mob %s at %s" % [mob_name, position])
	var mob = _mob_spawner.spawn(spawn_data) as Node
	if mob:
		var parent_path_str: String
		if mob.get_parent():
			parent_path_str = str(mob.get_parent().get_path())
		else:
			parent_path_str = "NO PARENT"
		print("GameManager [SERVER]: Mob %s spawned successfully, node path: %s, parent: %s" % [
			mob_name, 
			mob.get_path(),
			parent_path_str
		])
		# Set multiplayer authority to server (peer ID 1) for AI control
		if multiplayer.has_multiplayer_peer():
			mob.set_multiplayer_authority(1, true)
			print("GameManager [SERVER]: Set authority for mob %s to server (1)" % mob_name)
		
		# Use RPC to spawn on all clients - this ensures spawn_path is set on clients
		_rpc_spawn_mob_on_clients.rpc(mob_name, position, home_position)
	else:
		push_error("GameManager [SERVER]: Failed to spawn mob %s" % mob_name)

# RPC function to spawn mobs on clients
@rpc("authority", "call_local", "reliable")
func _rpc_spawn_mob_on_clients(mob_name: String, position: Vector3, home_position: Vector3) -> void:
	# This is called on all clients (and server) to spawn the mob
	# Only spawn if we're a client (server already spawned it)
	if multiplayer.is_server():
		return
	
	if !is_instance_valid(_mob_spawner):
		push_error("GameManager [CLIENT]: MobSpawner not initialized!")
		return
	
	# Ensure GameLevel exists on client
	if !is_instance_valid(_game_level):
		# Try to find GameLevel
		if is_instance_valid(_game_spawner):
			for child in _game_spawner.get_children():
				if child is Node and child.name == "GameLevel":
					_game_level = child
					break
		
		if !is_instance_valid(_game_level):
			push_error("GameManager [CLIENT]: GameLevel not available for mob spawning!")
			return
	
	# Ensure spawn_path is set correctly on client
	# Try relative path first
	_mob_spawner.spawn_path = NodePath("../GameLevelSpawner/GameLevel")
	var spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
	
	# If relative path doesn't work, try absolute path
	if !is_instance_valid(spawn_parent):
		var game_level_path = _mob_spawner.get_path_to(_game_level)
		_mob_spawner.spawn_path = game_level_path
		spawn_parent = _mob_spawner.get_node_or_null(_mob_spawner.spawn_path)
	
	# Verify spawn_path is valid
	if !is_instance_valid(spawn_parent):
		var game_level_path_str = str(_game_level.get_path()) if is_instance_valid(_game_level) else "N/A"
		push_error("GameManager [CLIENT]: MobSpawner spawn_path is invalid: %s (GameLevel exists: %s, GameLevel path: %s)" % [
			_mob_spawner.spawn_path,
			is_instance_valid(_game_level),
			game_level_path_str
		])
		return
	 
	print("GameManager [CLIENT]: MobSpawner spawn_path verified: %s -> %s" % [
		_mob_spawner.spawn_path,
		spawn_parent.get_path()
	])
	
	# Create spawn data and spawn mob on client
	var spawn_data = {
		"mob_name": mob_name,
		"position": position,
		"home_position": home_position
	}
	
	print("GameManager [CLIENT]: Spawning mob %s at %s via RPC" % [mob_name, position])
	var mob = _mob_spawner.spawn(spawn_data) as Node
	if mob:
		print("GameManager [CLIENT]: Mob %s spawned successfully on client, path: %s" % [mob_name, mob.get_path()])
		# Set multiplayer authority to server (peer ID 1) for AI control
		if multiplayer.has_multiplayer_peer():
			mob.set_multiplayer_authority(1, true)
	else:
		push_error("GameManager [CLIENT]: Failed to spawn mob %s - spawn() returned null" % mob_name)

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
		"fire_damage_min_max": weapon_resource.fire_damage_min_max,
		"weapon_blocking_angle": weapon_resource.weapon_blocking_angle,
		"push_forward_on_attack_force": weapon_resource.push_forward_on_attack_force,
		"weapon_durability_current": weapon_resource.weapon_durability_current,
		"weapon_durability_max": weapon_resource.weapon_durability_max,
		"reducing_durability_when_in_hands": weapon_resource.reducing_durability_when_in_hands,
		"in_hands_reduce_durability_speed": weapon_resource.in_hands_reduce_durability_speed,
		"is_one_time_use": weapon_resource.is_one_time_use,
		"is_throw_on_use": weapon_resource.is_throw_on_use,
		"thrown_projectile_prefab_path": weapon_resource.thrown_projectile_prefab_path,
		"self_heal_hp_amount": weapon_resource.self_heal_hp_amount
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
	weapon_resource.fire_damage_min_max = data.get("fire_damage_min_max", Vector2i(0, 0))
	weapon_resource.weapon_blocking_angle = data.get("weapon_blocking_angle", 160)
	weapon_resource.push_forward_on_attack_force = data.get("push_forward_on_attack_force", 5.0)
	weapon_resource.weapon_durability_current = data.get("weapon_durability_current", 100.0)
	weapon_resource.weapon_durability_max = data.get("weapon_durability_max", 100.0)
	weapon_resource.reducing_durability_when_in_hands = data.get("reducing_durability_when_in_hands", false)
	weapon_resource.in_hands_reduce_durability_speed = data.get("in_hands_reduce_durability_speed", 0.5)
	weapon_resource.is_one_time_use = data.get("is_one_time_use", false)
	weapon_resource.is_throw_on_use = data.get("is_throw_on_use", false)
	weapon_resource.thrown_projectile_prefab_path = data.get("thrown_projectile_prefab_path", "")
	weapon_resource.self_heal_hp_amount = data.get("self_heal_hp_amount", 0.0)
	return weapon_resource

# RPC function to handle pickup requests from clients (backward compatibility)
@rpc("any_peer", "reliable")
func rpc_request_pickup_by_name(pickup_name: String) -> void:
	rpc_request_pickup_by_name_and_position(pickup_name, Vector3.ZERO)

# RPC function to handle pickup requests from clients
# This is needed for procedurally spawned pickups that aren't synchronized
# Dropped pickups (synchronized via MultiplayerSpawner) should use direct RPC call instead
# Updated to avoid path resolution issues by searching in multiple locations
# Position is used as fallback when name doesn't match (e.g., client sees old name but server renamed it)
@rpc("any_peer", "reliable")
func rpc_request_pickup_by_name_and_position(pickup_name: String, pickup_position: Vector3) -> void:
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	# Find the pickup by name - procedurally spawned pickups have consistent names
	var pickup: InteractivePickup = null
	
	# First, try to find by exact name in all locations
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned pickups
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			pickup = dungeon_tiles.get_node_or_null(pickup_name) as InteractivePickup
		
		# If not found, check GameLevel directly for dropped pickups
		if pickup == null:
			pickup = _game_level.get_node_or_null(pickup_name) as InteractivePickup
	
	# Also check GameLevelSpawner in case pickups were spawned before spawn_path was set
	if pickup == null and is_instance_valid(_game_spawner):
		pickup = _game_spawner.get_node_or_null(pickup_name) as InteractivePickup
	
	# Last resort: search recursively in GameRoot
	if pickup == null and is_instance_valid(_game_root):
		pickup = _find_pickup_recursive(_game_root, pickup_name)
	
	# If still not found and we have a position, try to find by position
	# This handles the case where client sees old name but server already renamed it
	if pickup == null and pickup_position != Vector3.ZERO:
		if is_instance_valid(_game_root):
			var all_pickups = _find_all_pickups_recursive(_game_root)
			var closest_pickup: InteractivePickup = null
			var closest_distance = INF
			for p in all_pickups:
				var distance = p.global_position.distance_to(pickup_position)
				# If pickup is very close (within 0.5 units), it's likely the right one
				if distance < 0.5 and distance < closest_distance:
					closest_pickup = p
					closest_distance = distance
			if closest_pickup != null:
				pickup = closest_pickup
				print("[GameManager] Found pickup by position: '%s' at distance %.2f (was looking for '%s')" % [pickup.name, closest_distance, pickup_name])
	
	if pickup == null:
		print("[GameManager] Could not find pickup '%s' for pickup request (position: %s)" % [pickup_name, pickup_position])
		return
	
	# Process pickup using the found pickup node
	pickup._process_pickup_request()

# Helper function to recursively search for a pickup by name
func _find_pickup_recursive(node: Node, pickup_name: String) -> InteractivePickup:
	if node.name == pickup_name and node is InteractivePickup:
		return node as InteractivePickup
	for child in node.get_children():
		var result = _find_pickup_recursive(child, pickup_name)
		if result != null:
			return result
	return null

# Helper function to find all pickups recursively
func _find_all_pickups_recursive(node: Node) -> Array[InteractivePickup]:
	var pickups: Array[InteractivePickup] = []
	if node is InteractivePickup:
		pickups.append(node as InteractivePickup)
	for child in node.get_children():
		pickups.append_array(_find_all_pickups_recursive(child))
	return pickups

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
	var pickup: InteractivePickup = null
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned pickups
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			pickup = dungeon_tiles.get_node_or_null(pickup_name) as InteractivePickup
		
		# If not found, check GameLevel directly for dropped pickups
		if pickup == null:
			pickup = _game_level.get_node_or_null(pickup_name) as InteractivePickup
	
	# Also check GameLevelSpawner in case pickups were spawned before spawn_path was set
	if pickup == null and is_instance_valid(_game_spawner):
		pickup = _game_spawner.get_node_or_null(pickup_name) as InteractivePickup
	
	# Last resort: search recursively in GameRoot
	if pickup == null and is_instance_valid(_game_root):
		pickup = _find_pickup_recursive(_game_root, pickup_name)
	
	if pickup != null:
		print("[GameManager] Destroying pickup: %s" % pickup.name)
		# Use call_deferred to let MultiplayerSpawner process despawn properly
		pickup.call_deferred("queue_free")
	else:
		print("[GameManager] Could not find pickup '%s' to destroy" % pickup_name)

# RPC function to handle prop damage requests from clients
# Position is used as fallback when name doesn't match
@rpc("any_peer", "reliable")
func rpc_prop_take_damage(prop_name: String, prop_position: Vector3, damage: float, fire_damage: float, hit_position: Vector3, attacker_position: Vector3) -> void:
	# Only server processes this
	if !multiplayer.is_server():
		return

	# Find the prop by name - check both PhysicalPropRigidbody3D and LightStandProp
	var prop = null
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned props
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			prop = dungeon_tiles.get_node_or_null(prop_name)
			if prop != null and not (prop is PhysicalPropRigidbody3D or prop is LightStandProp):
				prop = null

		# Check MultistoryBuildingDungeon/DungeonTiles for procedurally spawned props (including LightStandProp)
		if prop == null:
			var multistory_dungeon_tiles = _game_level.get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
			if multistory_dungeon_tiles != null:
				prop = multistory_dungeon_tiles.get_node_or_null(prop_name)
				if prop != null and not (prop is PhysicalPropRigidbody3D or prop is LightStandProp):
					prop = null

	# If not found by name and we have a position, try to find by position
	if prop == null and prop_position != Vector3.ZERO:
		if is_instance_valid(_game_root):
			var all_props = _find_all_props_recursive(_game_root)
			var closest_prop = null
			var closest_distance = INF
			for p in all_props:
				# Check if prop is dead (only for PhysicalPropRigidbody3D)
				if p is PhysicalPropRigidbody3D and p.is_dead:
					continue
				var distance = p.global_position.distance_to(prop_position)
				# If prop is very close (within 1.0 units for better reliability), it's likely the right one
				if distance < 1.0 and distance < closest_distance:
					closest_prop = p
					closest_distance = distance
			if closest_prop != null:
				prop = closest_prop
				print("[GameManager] Found prop by position: '%s' (type: %s) at distance %.2f (was looking for '%s' at %s)" % [
					prop.name, prop.get_class(), closest_distance, prop_name, prop_position
				])

	if prop == null:
		print("[GameManager] Could not find prop '%s' for damage request (position: %s)" % [prop_name, prop_position])
		# Debug: list all available props
		if is_instance_valid(_game_root):
			var all_props = _find_all_props_recursive(_game_root)
			print("[GameManager] Available props:")
			for p in all_props:
				var distance = p.global_position.distance_to(prop_position) if prop_position != Vector3.ZERO else -1.0
				print("[GameManager]   - %s (type: %s) at %s (distance: %.2f)" % [p.name, p.get_class(), p.global_position, distance])
		return

	# Call take_damage on the prop
	prop.rpc_take_damage(damage, fire_damage, hit_position, attacker_position)

# RPC function to handle prop death requests from server
# This ensures death particles spawn on all clients
@rpc("any_peer", "call_local", "reliable")
func rpc_prop_death(prop_name: String, death_position: Vector3) -> void:
	# Find the prop by name
	var prop: PhysicalPropRigidbody3D = null
	if is_instance_valid(_game_level):
		# Check ProceduralDungeon/DungeonTiles for procedurally spawned props
		var dungeon_tiles = _game_level.get_node_or_null("ProceduralDungeon/DungeonTiles")
		if dungeon_tiles != null:
			prop = dungeon_tiles.get_node_or_null(prop_name) as PhysicalPropRigidbody3D
	
	# If not found by name, try to find by position
	if prop == null and death_position != Vector3.ZERO:
		if is_instance_valid(_game_root):
			var all_props = _find_all_props_recursive(_game_root)
			var closest_prop: PhysicalPropRigidbody3D = null
			var closest_distance = INF
			for p in all_props:
				if p.is_dead:
					continue
				var distance = p.global_position.distance_to(death_position)
				# If prop is very close (within 1.0 units), it's likely the right one
				if distance < 1.0 and distance < closest_distance:
					closest_prop = p
					closest_distance = distance
			if closest_prop != null:
				prop = closest_prop
				print("[GameManager] Found prop by position for death: '%s' at distance %.2f (was looking for '%s')" % [prop.name, closest_distance, prop_name])
	
	if prop == null:
		print("[GameManager] Could not find prop '%s' for death (position: %s)" % [prop_name, death_position])
		# Spawn particles anyway at the death position
		if is_instance_valid(_game_level) and death_position != Vector3.ZERO:
			_spawn_prop_death_particles_at_position(death_position)
		return
	
	# Call death on the prop (this will spawn particles on all clients)
	prop.death(death_position)

# Helper function to spawn death particles at a specific position (fallback)
func _spawn_prop_death_particles_at_position(_death_position: Vector3):
	# Try to find a prop death particles scene
	# This is a fallback - normally particles are spawned by the prop itself
	# You might want to load a default particle scene here if needed
	pass

# Helper function to find all props recursively
func _find_all_props_recursive(node: Node) -> Array:
	var props: Array = []
	if node is PhysicalPropRigidbody3D or node is LightStandProp:
		props.append(node)
	for child in node.get_children():
		props.append_array(_find_all_props_recursive(child))
	return props

@rpc("authority", "call_local", "reliable")
func _sync_dungeon_seed(seed_value: int) -> void:
	dungeon_seed = seed_value
	dungeon_seed_received = true
	print("GameManager: Synced dungeon seed: ", dungeon_seed)
	dungeon_seed_synced.emit(dungeon_seed)

@rpc("authority", "call_local", "reliable")
func rpc_add_money_to_party(money: int) -> void:
	party_money += money
	party_money_changed.emit()
	rpc_sync_party_money.rpc(party_money)
	
@rpc("authority", "call_local", "reliable")
func rpc_remove_money_from_party(money: int) -> void:
	party_money -= money
	party_money_changed.emit()
	rpc_sync_party_money.rpc(party_money)

@rpc("any_peer", "call_local", "reliable")
func rpc_sync_party_money(new_amount: int) -> void:
	party_money = new_amount
	party_money_changed.emit()

# Internal function to process buy item request (used both by RPC and direct calls)
func _process_buy_item_request(player_id: int, item_price: int, weapon_data: Dictionary) -> void:
	# Find the player
	if !_player_nodes.has(player_id):
		print("[SHOP] Player %d not found for buy request" % player_id)
		return

	var player = _player_nodes[player_id]

	# Check if player has enough money
	if party_money < item_price:
		print("[SHOP] Not enough money to buy item. Need %d, have %d" % [item_price, party_money])
		return

	# Check if player has inventory space
	if player.carrying_items.size() >= player.inventory_slots_max:
		print("[SHOP] Player inventory is full")
		return

	# Remove money from party
	rpc_remove_money_from_party(item_price)

	# Add item to player's inventory
	var weapon_resource = deserialize_weapon_resource(weapon_data)
	var final_name = weapon_resource.weapon_name
	var counter = 1
	while player.carrying_items.has(final_name):
		final_name = StringName("%s %d" % [weapon_resource.weapon_name, counter+1])
		counter += 1

	player.carrying_items[final_name] = weapon_resource.duplicate(true)

	# Update player's inventory UI
	player._clamp_selected_index()
	var serialized_inventory: Dictionary = {}
	for key in player.carrying_items.keys():
		serialized_inventory[key] = serialize_weapon_resource(player.carrying_items[key])

	if player_id == 1:
		# Server player - update directly
		if player.inventory_slots_panel_container:
			player.inventory_slots_panel_container.update_inventory_items_ui(player.carrying_items, player.current_selected_item_index)
	else:
		# Client player - send RPC
		player.rpc_update_inventory.rpc_id(player_id, serialized_inventory)

	# Update item in hands if needed
	var item_keys = player.carrying_items.keys()
	if item_keys.size() > player.current_selected_item_index and player.current_selected_item_index >= 0:
		var selected_item_resource = player.carrying_items[item_keys[player.current_selected_item_index]]
		var selected_weapon_data = serialize_weapon_resource(selected_item_resource)
		player.rpc_update_item_in_hands.rpc(player.current_selected_item_index, selected_weapon_data)
	else:
		player.rpc_update_item_in_hands.rpc(-1, {})  # No item selected

# RPC for clients to request buying an item from shop
@rpc("any_peer", "reliable")
func rpc_request_buy_item(player_id: int, item_price: int, weapon_data: Dictionary) -> void:
	# Only server processes this
	if !multiplayer.is_server():
		return

	_process_buy_item_request(player_id, item_price, weapon_data)

# Internal function to process sell item request (used both by RPC and direct calls)
func _process_sell_item_request(player_id: int, item_key: String, sell_price: int) -> void:
	print("[SHOP] Processing sell request: player %d, item %s, price %d" % [player_id, item_key, sell_price])

	# Find the player
	if !_player_nodes.has(player_id):
		print("[SHOP] Player %d not found for sell request" % player_id)
		return

	var player = _player_nodes[player_id]

	# Check if player has the item
	if !player.carrying_items.has(item_key):
		print("[SHOP] Player doesn't have item %s to sell" % item_key)
		return

	print("[SHOP] Removing item %s from player %d's inventory (had %d items)" % [item_key, player_id, player.carrying_items.size()])

	# Remove item from inventory
	player.carrying_items.erase(item_key)

	print("[SHOP] Added %d gold to party (total now: %d)" % [sell_price, party_money + sell_price])

	# Add money to party
	party_money += sell_price
	party_money_changed.emit()
	rpc_sync_party_money.rpc(party_money)

	# Update player's inventory UI
	player._clamp_selected_index()
	var serialized_inventory: Dictionary = {}
	for key in player.carrying_items.keys():
		serialized_inventory[key] = serialize_weapon_resource(player.carrying_items[key])

	# Always send inventory update to the player who sold the item
	player.rpc_update_inventory.rpc_id(player_id, serialized_inventory)

	# Also update UI directly for server player
	if player_id == 1:
		# Server player - update directly
		if player.inventory_slots_panel_container:
			player.inventory_slots_panel_container.update_inventory_items_ui(player.carrying_items, player.current_selected_item_index)

	# Update item in hands if needed
	var item_keys = player.carrying_items.keys()
	if item_keys.size() > player.current_selected_item_index and player.current_selected_item_index >= 0:
		var selected_item_resource = player.carrying_items[item_keys[player.current_selected_item_index]]
		var selected_weapon_data = serialize_weapon_resource(selected_item_resource)
		player.rpc_update_item_in_hands.rpc_id(player_id, player.current_selected_item_index, selected_weapon_data)
	else:
		player.rpc_update_item_in_hands.rpc_id(player_id, -1, {})  # No item selected

# RPC for clients to request selling an item
@rpc("any_peer", "reliable")
func rpc_request_sell_item(player_id: int, item_key: String, sell_price: int) -> void:
	# Only server processes this
	if !multiplayer.is_server():
		return

	_process_sell_item_request(player_id, item_key, sell_price)
