extends NavigationRegion3D

@export var is_game_level_ready = false
@export var level_generator_path: NodePath = "ProceduralDungeon"
@export var level_generator: Node # Changed from ProceduralDungeon to Node to avoid casting issues in exported builds
var players_placed: bool = false
@onready var world_environment: WorldEnvironment = %WorldEnvironment

func _ready() -> void:
	is_game_level_ready = false
	players_placed = false
	GameManager._game_level = self
	
	# Wait for a frame to ensure all child nodes are added to the scene tree
	# This is especially important in exported builds where nodes might not be ready immediately
	await get_tree().process_frame
	
	# Try to find level generator from the exported NodePath first
	if level_generator_path != NodePath():
		var node_from_path = get_node_or_null(level_generator_path)
		if node_from_path != null:
			level_generator = node_from_path
			print("GameLevel._ready: Found level generator from NodePath: ", node_from_path.name)
	
	if level_generator == null:
		push_error("GameLevel: Failed to find any LevelGenerator node! Children: " + str(get_children().map(func(c): return c.name)))
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

func _find_elevator_location_multistory_building() -> Vector3i:
	# Найти позицию для лифта в multistory building dungeon
	# Выбираем тайл с полом в одной из комнат на верхнем этаже
	if level_generator == null:
		push_warning("_find_elevator_location_multistory_building: level_generator is null")
		return Vector3i.ZERO
	
	# Проверить, что у генератора есть apartment_rooms_by_floor
	if not level_generator is MultistoryBuildingDungeon:
		push_warning("_find_elevator_location_multistory_building: level_generator does not have apartment_rooms_by_floor property")
		return Vector3i.ZERO
	
	var apartment_rooms_by_floor: Dictionary = level_generator.apartment_rooms_by_floor
	
	if apartment_rooms_by_floor.is_empty():
		push_warning("_find_elevator_location_multistory_building: apartment_rooms_by_floor is empty")
		return Vector3i.ZERO
	
	# Найти максимальный floor_y (верхний этаж)
	var max_floor_y: int = -2147483648 # INT_MIN equivalent
	for floor_y in apartment_rooms_by_floor.keys():
		if floor_y > max_floor_y:
			max_floor_y = floor_y
	
	if max_floor_y == -2147483648:
		push_warning("_find_elevator_location_multistory_building: Could not find any floors")
		return Vector3i.ZERO
	
	# Получить комнаты на верхнем этаже
	var rooms_on_top_floor: Array = apartment_rooms_by_floor.get(max_floor_y, [])
	if rooms_on_top_floor.is_empty():
		push_warning("_find_elevator_location_multistory_building: No rooms on top floor (floor_y=%d)" % max_floor_y)
		return Vector3i.ZERO
	
	# Выбрать случайную комнату на верхнем этаже
	# var selected_room = rooms_on_top_floor[randi() % rooms_on_top_floor.size()]
	var selected_room = null
	var max_room_height: int = -1
	for room in rooms_on_top_floor:
		if room.default_vertical_wall_tiles_amount > max_room_height:
			max_room_height = room.default_vertical_wall_tiles_amount
			selected_room = room

	if selected_room == null:
		push_warning("_find_elevator_location_multistory_building: Could not find any valid room")
		return rooms_on_top_floor[randi() % rooms_on_top_floor.size()]

	# Найти тайлы этой комнаты НА УРОВНЕ ЭТАЖА (floor_y) - это будут тайлы с полом
	# Проверить, что у генератора есть all_spawned_tiles
	
	var all_spawned_tiles: Dictionary = level_generator.all_spawned_tiles
	
	# Найти тайлы выбранной комнаты на уровне floor_y (это тайлы с полом)
	var room_floor_tiles: Array[DungeonTile] = []
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		var tile_room = all_spawned_tiles.get(tile, null)
		# Мы ищем тайлы на уровне floor_y (где будет пол), а не выше
		# if tile_room == selected_room and is_instance_valid(tile.floor):
		if tile_room == selected_room and tile.coord.y == max_floor_y:
			# Дополнительная проверка: у тайла должен быть пол после конфигурации
			# (то есть не должно быть тайла снизу на том же уровне этажа)
			var neighbor_below = level_generator._get_tile_at_coord(tile.coord + Vector3i(0, -1, 0))
			if neighbor_below == null or neighbor_below.coord.y < max_floor_y:
				room_floor_tiles.append(tile)
	
	if room_floor_tiles.is_empty():
		push_warning("_find_elevator_location_multistory_building: No floor tiles found for selected room on floor_y=%d" % max_floor_y)
		return Vector3i.ZERO
	
	# Выбрать случайный тайл с полом из комнаты
	var selected_tile: DungeonTile = room_floor_tiles[randi() % room_floor_tiles.size()]
	
	print("_find_elevator_location_multistory_building: Selected elevator location at %s (top floor=%d, room has %d floor tiles)" % [
		selected_tile.coord,
		max_floor_y,
		room_floor_tiles.size()
	])
	
	return selected_tile.coord

func _handle_elevator_spawn_and_player_teleport():
	# Проверить, что level_generator имеет правильный скрипт
	if level_generator == null:
		push_warning("_handle_elevator_spawn_and_player_teleport: level_generator is null")
		return
	
	var script = level_generator.get_script()
	if not script:
		push_warning("_handle_elevator_spawn_and_player_teleport: level_generator does not have a script")
		return
	
	var script_path = script.resource_path
	var is_multistory_building = script_path.ends_with("multistory_building_dungeon.gd")
	var is_procedural_dungeon = script_path.ends_with("procedural_dungeon.gd")
	
	if not is_multistory_building and not is_procedural_dungeon:
		push_warning("_handle_elevator_spawn_and_player_teleport: level_generator does not have ProceduralDungeon or MultistoryBuildingDungeon script")
		return
	
	# Найти место для спавна лифта
	var elevator_coord: Vector3i = Vector3i.ZERO
	
	if is_multistory_building:
		# Для multistory building dungeon выбираем комнату на верхнем этаже
		elevator_coord = _find_elevator_location_multistory_building()
	else:
		# Для обычного procedural dungeon используем стандартный метод
		elevator_coord = level_generator.find_elevator_spawn_location()
	
	if elevator_coord == Vector3i.ZERO:
		push_warning("_handle_elevator_spawn_and_player_teleport: Failed to find elevator spawn location")
		return
	
	# Получить тайл по координатам
	var elevator_tile: DungeonTile = level_generator._get_tile_at_coord(elevator_coord)
	if elevator_tile == null:
		push_warning("_handle_elevator_spawn_and_player_teleport: Failed to find tile at coord %s" % elevator_coord)
		return
	
	# Очистить потолок на тайле где спавнится лифт
	if is_instance_valid(elevator_tile.ceiling):
		elevator_tile.ceiling.queue_free()
		print("_handle_elevator_spawn_and_player_teleport: Cleared ceiling at elevator tile coord %s" % elevator_coord)
	
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
	if not script:
		push_warning("_spawn_elevator_at_position: level_generator does not have a script")
		return
	
	var script_path = script.resource_path
	var is_multistory_building = script_path.ends_with("multistory_building_dungeon.gd")
	var is_procedural_dungeon = script_path.ends_with("procedural_dungeon.gd")
	
	if not is_multistory_building and not is_procedural_dungeon:
		push_warning("_spawn_elevator_at_position: level_generator does not have ProceduralDungeon or MultistoryBuildingDungeon script")
		return
	
	# Найти узел DungeonTiles в зависимости от типа генератора
	var dungeon_tiles_node: Node3D = null
	if is_multistory_building:
		dungeon_tiles_node = get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
	else:
		dungeon_tiles_node = get_node_or_null("ProceduralDungeon/DungeonTiles")
	
	if dungeon_tiles_node == null:
		# Fallback: попробовать найти по имени level_generator
		var generator_name = level_generator.name
		dungeon_tiles_node = get_node_or_null("%s/DungeonTiles" % generator_name)
	
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
	var TILE_SIZE: Vector3i = Vector3i(4, 2, 4) # Должно совпадать с TILE_SIZE в procedural_dungeon.gd
	var elevator_coord: Vector3i = Vector3i(
		int(round(elevator_pos.x / TILE_SIZE.x)),
		int(round(elevator_pos.y / TILE_SIZE.y)),
		int(round(elevator_pos.z / TILE_SIZE.z))
	)
	
	# Найти горизонтальных соседей (только X и Z направления)
	var horizontal_offsets: Array[Vector3i] = [
		Vector3i(1, 0, 0), # Right
		Vector3i(-1, 0, 0), # Left
		Vector3i(0, 0, 1), # Forward
		Vector3i(0, 0, -1) # Backward
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
		if neighbor_offset.x > 0: # Right (+X)
			rotation_y = deg_to_rad(270) # или -90°
		elif neighbor_offset.x < 0: # Left (-X)
			rotation_y = deg_to_rad(90)
		elif neighbor_offset.z > 0: # Forward (+Z)
			rotation_y = deg_to_rad(0)
		elif neighbor_offset.z < 0: # Backward (-Z)
			rotation_y = deg_to_rad(180)
		
		elevator.rotation.y = rotation_y
		print("_spawn_elevator_at_position: Rotated elevator towards neighbor at offset %s (rotation_y=%.2f°)" % [neighbor_offset, rad_to_deg(rotation_y)])
	else:
		print("_spawn_elevator_at_position: No horizontal neighbors found for elevator, using default rotation")
	
	# Установить authority на сервер в мультиплеере
	if multiplayer.has_multiplayer_peer():
		elevator.set_multiplayer_authority(1)
	
	print("_spawn_elevator_at_position: Spawned elevator at position %s [is_server=%s]" % [elevator_pos, multiplayer.is_server()])
	
	# Заспавнить шахту лифта - 100 тайлов вверх без потолка и пола
	_spawn_elevator_shaft(elevator_coord, 100)

func _spawn_elevator_shaft(elevator_coord: Vector3i, shaft_height: int):
	# Спавнить шахту лифта над тайлом с лифтом
	# shaft_height - количество тайлов вверх
	if level_generator == null:
		push_warning("_spawn_elevator_shaft: level_generator is null")
		return
	
	var TILE_SIZE: Vector3i = Vector3i(4, 2, 4) # Должно совпадать с TILE_SIZE в level_generator
	var DUNGEON_TILE = level_generator.DUNGEON_TILE
	
	if DUNGEON_TILE == null:
		push_warning("_spawn_elevator_shaft: DUNGEON_TILE is null")
		return
	
	# Найти узел DungeonTiles
	var script = level_generator.get_script()
	if not script:
		return
	
	var script_path = script.resource_path
	var is_multistory_building = script_path.ends_with("multistory_building_dungeon.gd")
	
	var dungeon_tiles_node: Node3D = null
	if is_multistory_building:
		dungeon_tiles_node = get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
	else:
		dungeon_tiles_node = get_node_or_null("ProceduralDungeon/DungeonTiles")
	
	if dungeon_tiles_node == null:
		var generator_name = level_generator.name
		dungeon_tiles_node = get_node_or_null("%s/DungeonTiles" % generator_name)
	
	if dungeon_tiles_node == null:
		push_warning("_spawn_elevator_shaft: Could not find DungeonTiles node")
		return
	
	# Создать шахту - тайлы без пола и потолка
	var tiles_created: int = 0
	for i in range(1, shaft_height + 1):
		var shaft_coord: Vector3i = elevator_coord + Vector3i(0, i, 0)
		
		# Проверить, не существует ли уже тайл на этой позиции
		var existing_tile = level_generator._get_tile_at_coord(shaft_coord)
		if existing_tile != null:
			# Удалить пол и потолок у существующего тайла
			if is_instance_valid(existing_tile.floor):
				existing_tile.floor.queue_free()
				existing_tile.floor = null
			if is_instance_valid(existing_tile.ceiling):
				existing_tile.ceiling.queue_free()
				existing_tile.ceiling = null
			tiles_created += 1
			continue
		
		# Создать новый тайл для шахты
		var world_position: Vector3 = Vector3(
			shaft_coord.x * TILE_SIZE.x,
			shaft_coord.y * TILE_SIZE.y,
			shaft_coord.z * TILE_SIZE.z
		)
		
		var shaft_tile = DUNGEON_TILE.instantiate()
		shaft_tile.position = world_position
		shaft_tile.coord = shaft_coord
		shaft_tile.master_dungeon = level_generator
		dungeon_tiles_node.add_child(shaft_tile)
		shaft_tile.owner = get_tree().edited_scene_root
		
		# Удалить пол и потолок у тайла шахты
		# Подождем один кадр, чтобы тайл успел сконфигурироваться
		await get_tree().process_frame
		
		if is_instance_valid(shaft_tile.floor):
			shaft_tile.floor.queue_free()
			shaft_tile.floor = null
		if is_instance_valid(shaft_tile.ceiling):
			shaft_tile.ceiling.queue_free()
			shaft_tile.ceiling = null
		
		tiles_created += 1
	
	print("_spawn_elevator_shaft: Created %d shaft tiles above elevator at %s" % [tiles_created, elevator_coord])
