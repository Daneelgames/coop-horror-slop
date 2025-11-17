extends NavigationRegion3D

@export var is_game_level_ready = false
@export var level_generator_path : NodePath = "ProceduralDungeon"
var level_generator : Node  # Changed from ProceduralDungeon to Node to avoid casting issues in exported builds
var players_placed: bool = false
@onready var world_environment: WorldEnvironment = %WorldEnvironment

func _ready() -> void:
	is_game_level_ready = false
	players_placed = false
	GameManager._game_level = self
	
	# Debug: Print all children to see what's available
	print("GameLevel._ready: Children count: ", get_child_count())
	for child in get_children():
		print("GameLevel._ready: Child: ", child.name, " (", child.get_class(), "), path: ", child.get_path())
	
	# Wait for a frame to ensure all child nodes are added to the scene tree
	# This is especially important in exported builds where nodes might not be ready immediately
	await get_tree().process_frame
	
	# Debug again after frame wait
	print("GameLevel._ready: After frame wait, children count: ", get_child_count())
	var procedural_dungeon_node: Node = null
	for child in get_children():
		print("GameLevel._ready: After wait - Child: ", child.name, " (", child.get_class(), "), is_inside_tree: ", child.is_inside_tree())
		if child.name == "ProceduralDungeon":
			procedural_dungeon_node = child
			print("GameLevel._ready: Found ProceduralDungeon node! Type check: is ProceduralDungeon = ", child is ProceduralDungeon)
			print("GameLevel._ready: ProceduralDungeon script: ", child.get_script())
			if child.get_script():
				print("GameLevel._ready: Script path: ", child.get_script().resource_path)
	
	# Try to get the node directly from children array first
	if procedural_dungeon_node != null:
		print("GameLevel._ready: Using direct reference from children array")
		# In exported builds, class_name casting may not work, so we use the node directly
		# Check if the node has the correct script by checking script path
		var script = procedural_dungeon_node.get_script()
		if script:
			var script_path = script.resource_path
			print("GameLevel._ready: Node script path: ", script_path)
			# Check if script is ProceduralDungeon by path or name
			if script_path.ends_with("procedural_dungeon.gd") or "procedural_dungeon" in script_path.to_lower():
				print("GameLevel._ready: Node has ProceduralDungeon script, using directly")
				# Use the node directly - it has the script, so it will work
				level_generator = procedural_dungeon_node
			else:
				print("GameLevel._ready: Script path doesn't match ProceduralDungeon: ", script_path)
		else:
			print("GameLevel._ready: WARNING - Node has no script!")
		
		# Fallback: try casting if direct assignment didn't work
		if level_generator == null:
			level_generator = procedural_dungeon_node as ProceduralDungeon
			if level_generator != null:
				print("GameLevel._ready: Cast to ProceduralDungeon succeeded")
			else:
				print("GameLevel._ready: WARNING - Cast to ProceduralDungeon failed! Node type: ", procedural_dungeon_node.get_class())
	
	# Resolve level_generator from NodePath (works in both editor and exported builds)
	if level_generator == null and level_generator_path != NodePath():
		var node_from_path = get_node_or_null(level_generator_path)
		print("GameLevel._ready: Tried NodePath resolution: ", level_generator_path, " -> node: ", node_from_path)
		if node_from_path != null:
			level_generator = node_from_path as ProceduralDungeon
			print("GameLevel._ready: NodePath cast result: ", level_generator != null)
	
	# Fallback: try to find ProceduralDungeon node directly if path resolution failed
	if level_generator == null:
		var node_by_name = get_node_or_null("ProceduralDungeon")
		print("GameLevel._ready: Tried direct name lookup 'ProceduralDungeon' -> node: ", node_by_name)
		if node_by_name != null:
			level_generator = node_by_name as ProceduralDungeon
			print("GameLevel._ready: Direct name cast result: ", level_generator != null)
	
	# Try to find any ProceduralDungeon node recursively
	if level_generator == null:
		level_generator = _find_procedural_dungeon_recursive(self)
		print("GameLevel._ready: Tried recursive search -> ", level_generator != null)
	
	if level_generator == null:
		push_error("GameLevel: Failed to find ProceduralDungeon node! Children: " + str(get_children().map(func(c): return c.name)))
		# Try one more time - maybe we need to wait longer?
		await get_tree().create_timer(0.1).timeout
		procedural_dungeon_node = get_node_or_null("ProceduralDungeon")
		if procedural_dungeon_node != null:
			level_generator = procedural_dungeon_node as ProceduralDungeon
			print("GameLevel._ready: Found after additional wait!")
	
	if level_generator == null:
		push_error("GameLevel: CRITICAL - ProceduralDungeon node exists but cannot be cast to ProceduralDungeon type!")
		return
	
	level_generator.generate_dungeon()
	await level_generator.level_generated
	bake_navigation_mesh()
	await bake_finished
	is_game_level_ready = true
	
	# На сервере обработать спавн лифта и телепортацию игроков
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		await _handle_elevator_spawn_and_player_teleport()


func _process(_delta: float) -> void:
	if Input.is_key_label_pressed(KEY_G) and Input.is_key_label_pressed(KEY_Z) and Input.is_key_label_pressed(KEY_M):
		toggle_cheat_environment()

func _find_procedural_dungeon_recursive(node: Node) -> Node:
	# Check if current node has ProceduralDungeon script
	var script = node.get_script()
	if script and script.resource_path.ends_with("procedural_dungeon.gd"):
		return node
	
	# Recursively check all children
	for child in node.get_children():
		var result = _find_procedural_dungeon_recursive(child)
		if result != null:
			return result
	
	return null

var is_dark_env = true
var cheat_env_cooldown = false
func toggle_cheat_environment():
	if cheat_env_cooldown:
		return
	is_dark_env = !is_dark_env
	if is_dark_env:
		world_environment.environment = load('res://game_darkness_environment.tres')
	else:
		world_environment.environment = load('res://game_light_environment.tres')
	cheat_env_cooldown = true
	await get_tree().create_timer(0.2).timeout
	cheat_env_cooldown = false

func _handle_elevator_spawn_and_player_teleport():
	# Проверить, что level_generator имеет правильный скрипт
	if level_generator == null:
		push_warning("_handle_elevator_spawn_and_player_teleport: level_generator is null")
		return
	
	var script = level_generator.get_script()
	if not script or not script.resource_path.ends_with("procedural_dungeon.gd"):
		push_warning("_handle_elevator_spawn_and_player_teleport: level_generator does not have ProceduralDungeon script")
		return
	
	# Используем level_generator напрямую - у него есть нужные методы
	# Найти место для спавна лифта
	var elevator_coord: Vector3i = level_generator.find_elevator_spawn_location()
	if elevator_coord == Vector3i.ZERO:
		push_warning("_handle_elevator_spawn_and_player_teleport: Failed to find elevator spawn location")
		return
	
	# Получить тайл по координатам
	var elevator_tile: DungeonTile = level_generator._get_tile_at_coord(elevator_coord)
	if elevator_tile == null:
		push_warning("_handle_elevator_spawn_and_player_teleport: Failed to find tile at coord %s" % elevator_coord)
		return
	
	# Заспавнить лифт на тайле через RPC для синхронизации с клиентами
	var elevator_position = elevator_tile.position
	# Вызвать RPC для спавна лифта на всех клиентах
	if multiplayer.has_multiplayer_peer():
		rpc_spawn_elevator.rpc(elevator_position)
	else:
		# Single player: спавнить локально
		_spawn_elevator_at_position(elevator_position)
	
	# Подождать, пока все игроки зарегистрируются (только в мультиплеере)
	if multiplayer.has_multiplayer_peer():
		var max_wait_time = 5.0
		var wait_interval = 0.1
		var waited_time = 0.0
		var all_players_registered = false
		
		while not all_players_registered and waited_time < max_wait_time:
			var expected_player_count = NetworkManager.players.size() if is_instance_valid(NetworkManager) else 0
			var registered_count = GameManager._player_nodes.size()
			
			if expected_player_count > 0 and registered_count >= expected_player_count:
				all_players_registered = true
			else:
				await get_tree().create_timer(wait_interval).timeout
				waited_time += wait_interval
		
		if not all_players_registered:
			push_warning("_handle_elevator_spawn_and_player_teleport: Not all players registered after %.1fs" % max_wait_time)
	
	# Телепортировать всех игроков на тайл с лифтом
	# Вычислить позицию спавна (центр тайла с небольшим смещением вверх)
	var spawn_position = elevator_tile.position + Vector3(0, 0.25, 0)
	
	# Получить всех игроков
	var all_players: Array = []
	for peer_id in GameManager._player_nodes.keys():
		var player = GameManager._player_nodes[peer_id]
		if is_instance_valid(player):
			all_players.append(player)
	
	# Телепортировать каждого игрока с небольшим смещением по кругу
	var total_players = all_players.size()
	var circle_radius = 0.25
	var angle_step = (2.0 * PI) / total_players if total_players > 0 else 0.0
	
	for i in range(all_players.size()):
		var player = all_players[i]
		if not is_instance_valid(player):
			continue
		
		# Вычислить круговое смещение
		var angle = i * angle_step
		var offset_x = cos(angle) * circle_radius
		var offset_z = sin(angle) * circle_radius
		
		# Финальная позиция
		var player_spawn_position = spawn_position + Vector3(offset_x, 0.0, offset_z)
		
		# Телепортировать игрока через RPC (в мультиплеере) или напрямую (в single player)
		if multiplayer.has_multiplayer_peer():
			# В мультиплеере ВСЕ игроки телепортируются через RPC
			# Вызываем RPC для каждого игрока отдельно через rpc_id чтобы гарантировать доставку
			if player.has_method("rpc_teleport_to_position"):
				# Извлечь peer_id из имени игрока "Player_{peer_id}"
				var name_parts = player.name.split("_")
				if name_parts.size() >= 2:
					var peer_id = name_parts[1].to_int()
					var local_peer_id = multiplayer.get_unique_id()
					
					if peer_id == local_peer_id:
						# Для локального игрока на сервере вызываем локально
						player.rpc_teleport_to_position(player_spawn_position)
						print("_handle_elevator_spawn_and_player_teleport: Called locally for server player %s (peer_id=%d) at position %s" % [player.name, peer_id, player_spawn_position])
					else:
						# Для удаленных клиентов вызываем через RPC
						player.rpc_teleport_to_position.rpc_id(peer_id, player_spawn_position)
						print("_handle_elevator_spawn_and_player_teleport: Sent RPC to remote player %s (peer_id=%d) at position %s" % [player.name, peer_id, player_spawn_position])
				else:
					push_warning("_handle_elevator_spawn_and_player_teleport: Could not extract peer_id from player name %s" % player.name)
					# Fallback: вызвать локально
					player.rpc_teleport_to_position(player_spawn_position)
			else:
				push_warning("_handle_elevator_spawn_and_player_teleport: Player %s does not have rpc_teleport_to_position method" % player.name)
		else:
			# Single player: установить позицию напрямую
			player.global_position = player_spawn_position
	
	print("_handle_elevator_spawn_and_player_teleport: Teleported %d players to elevator position" % all_players.size())
	players_placed = true

@rpc("authority", "call_local", "reliable")
func rpc_spawn_elevator(elevator_pos: Vector3):
	# Спавнить лифт на указанной позиции
	# Эта функция вызывается сервером для всех клиентов через RPC
	_spawn_elevator_at_position(elevator_pos)

func _spawn_elevator_at_position(elevator_pos: Vector3):
	# Проверить, что level_generator имеет правильный скрипт
	if level_generator == null:
		push_warning("_spawn_elevator_at_position: level_generator is null")
		return
	
	var script = level_generator.get_script()
	if not script or not script.resource_path.ends_with("procedural_dungeon.gd"):
		push_warning("_spawn_elevator_at_position: level_generator does not have ProceduralDungeon script")
		return
	
	var dungeon_tiles_node = get_node_or_null("ProceduralDungeon/DungeonTiles")
	if dungeon_tiles_node == null:
		push_warning("_spawn_elevator_at_position: Could not find DungeonTiles node")
		return
	
	# Проверить, не спавнился ли лифт уже
	if dungeon_tiles_node.get_node_or_null("Elevator") != null:
		print("_spawn_elevator_at_position: Elevator already exists, skipping spawn")
		return
	
	# Заспавнить лифт - используем level_generator напрямую
	var elevator = level_generator.ELEVATOR.instantiate()
	if elevator == null:
		push_warning("_spawn_elevator_at_position: Failed to instantiate elevator")
		return
	
	elevator.position = elevator_pos
	elevator.name = "Elevator"
	dungeon_tiles_node.add_child(elevator)
	elevator.owner = get_tree().edited_scene_root
	
	# Повернуть лифт к одному из горизонтальных соседей
	# Преобразовать позицию в координату тайла
	var TILE_SIZE: Vector3i = Vector3i(4, 2, 4)  # Должно совпадать с TILE_SIZE в procedural_dungeon.gd
	var elevator_coord: Vector3i = Vector3i(
		int(round(elevator_pos.x / TILE_SIZE.x)),
		int(round(elevator_pos.y / TILE_SIZE.y)),
		int(round(elevator_pos.z / TILE_SIZE.z))
	)
	
	# Найти горизонтальных соседей (только X и Z направления)
	var horizontal_offsets: Array[Vector3i] = [
		Vector3i(1, 0, 0),   # Right
		Vector3i(-1, 0, 0),  # Left
		Vector3i(0, 0, 1),   # Forward
		Vector3i(0, 0, -1)   # Backward
	]
	
	var available_neighbors: Array[Vector3i] = []
	for offset in horizontal_offsets:
		var neighbor_coord: Vector3i = elevator_coord + offset
		var neighbor_tile = level_generator._get_tile_at_coord(neighbor_coord)
		if neighbor_tile != null:
			available_neighbors.append(offset)
	
	# Если есть доступные соседи, выбрать первого и повернуть к нему
	if available_neighbors.size() > 0:
		var neighbor_offset: Vector3i = available_neighbors[0]
		
		# Вычислить угол поворота в радианах
		# В Godot: 0° = +Z (вперед), 90° = -X (влево), 180° = -Z (назад), 270° = +X (вправо)
		var rotation_y: float = 0.0
		if neighbor_offset.x > 0:  # Right (+X)
			rotation_y = deg_to_rad(270)  # или -90°
		elif neighbor_offset.x < 0:  # Left (-X)
			rotation_y = deg_to_rad(90)
		elif neighbor_offset.z > 0:  # Forward (+Z)
			rotation_y = deg_to_rad(0)
		elif neighbor_offset.z < 0:  # Backward (-Z)
			rotation_y = deg_to_rad(180)
		
		elevator.rotation.y = rotation_y
		print("_spawn_elevator_at_position: Rotated elevator towards neighbor at offset %s (rotation_y=%.2f°)" % [neighbor_offset, rad_to_deg(rotation_y)])
	else:
		print("_spawn_elevator_at_position: No horizontal neighbors found for elevator, using default rotation")
	
	# Установить authority на сервер в мультиплеере
	if multiplayer.has_multiplayer_peer():
		elevator.set_multiplayer_authority(1)
	
	print("_spawn_elevator_at_position: Spawned elevator at position %s [is_server=%s]" % [elevator_pos, multiplayer.is_server()])
