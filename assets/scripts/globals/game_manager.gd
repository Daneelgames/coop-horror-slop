extends Node

const GAME_LEVEL_SCENE_PATH := "res://assets/scenes/game_level.tscn"
const PLAYER_SCENE_PATH := "res://addons/fpc/character.tscn"
const GAME_LEVEL_SCENE : PackedScene = preload(GAME_LEVEL_SCENE_PATH)
const PLAYER_SCENE : PackedScene = preload(PLAYER_SCENE_PATH)

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
var particles_manager : ParticlesManager
var ai_visibility_manager : AiVisibilityManager
var ai_hearing_manager : AiHearingManager

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
	if multiplayer.is_server():
		_spawn_game_level()
		_setup_player_multiplayer_signals()
		_spawn_existing_players()
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
