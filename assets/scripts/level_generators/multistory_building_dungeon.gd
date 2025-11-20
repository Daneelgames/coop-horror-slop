@tool
extends LevelGenerator
class_name MultistoryBuildingDungeon

const DUNGEON_TILE = preload("uid://cefhqgvoa83r2")
const STAIRS_1 = preload("res://assets/prefabs/environment/dungeon_walls/stairs_tile.tscn")
const DOORS_PREFABS = [preload("res://assets/prefabs/environment/dungeon_doors/door_multistory_building.tscn")]
const ELEVATOR = preload("uid://d1fhekbr7wjf3")
const AI_CHARACTER = preload("res://addons/fpc/ai_character.tscn")
const TILE_SIZE: Vector3i = Vector3i(4, 2, 4) # tile's origin is at its bottom center
const LIGHT_STAND = preload("uid://dm6w6626ynucp")

@export var torches_on_walls_amount = 30
@export var light_stands_amount = 30
@export var items_to_spawn_amount = 30
@export var item_spawns: Array[ResourceItemSpawn]
@export var mobs_amount_to_spawn = 30
@export var props_amount_to_spawn: int = 400 # Общее количество пропов для спавна
@export var props_by_weight: Dictionary[StringName, float] # prop path, drop weight - единый словарь для всего данжа
@export var floors_heights: Array[int] = [2, 3, 4, 5, 6]
@export var rooms_per_floor_min_max: Vector2i = Vector2i(3, 8) # Минимальное и максимальное количество комнат на этаж
@export var apartment_side_size_min_max: Vector2i = Vector2i(2, 5)
@export var min_stairs_per_floor: int = 1 # Минимальное количество лестниц на этаж
@export var max_stairs_per_floor: int = 3 # Максимальное количество лестниц на этаж

@export var gen: bool = false:
	set(v):
		if Engine.is_editor_hint() == false:
			return
		gen = false
		generate_dungeon()

@export var clr: bool = false:
	set(v):
		if Engine.is_editor_hint() == false:
			return
		clr = false
		clear()

@onready var dungeon_tiles: Node3D = %DungeonTiles

# Seeded random number generator for synchronized generation
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
@export var dungeon_seed: int = 0
var seed_received: bool = false

# Seed synchronization is now handled by GameManager

@export var all_spawned_tiles: Dictionary[DungeonTile, ResourceDungeonRoom]
@export var room_assignment: Dictionary[DungeonTile, ResourceDungeonRoom] = {} # Для проверки принадлежности к комнате
@export var spawned_stairs_coords: Dictionary[Vector3i, Node] # coord, stairs node
@export var spawned_doors_coords_new: Dictionary[String, Node] # "coord1-coord2", door node
@export var apartment_rooms_by_floor: Dictionary[int, Array] = {} # floor_y -> Array[ResourceDungeonRoom]
@export var room_connections: Dictionary[ResourceDungeonRoom, Array] = {} # room -> Array[connected_room]
@export var tunnel_room: ResourceDungeonRoom = null # Special room for all tunnel tiles

func _ready() -> void:
	print("MultistoryBuildingDungeon ready - node: ", name, ", path: ", get_path(), ", is_inside_tree: ", is_inside_tree())

# Helper function to get edited scene root (works in editor and game)
func _get_edited_scene_root() -> Node:
	return get_tree().edited_scene_root

# Helper function to await frame (works in editor and game)
func _await_frame():
	if Engine.is_editor_hint():
		if Engine.get_main_loop():
			await Engine.get_main_loop().process_frame
	else:
		if get_tree():
			await get_tree().process_frame

func _sort_tiles_by_coord(a: DungeonTile, b: DungeonTile) -> bool:
	if a.coord.x != b.coord.x:
		return a.coord.x < b.coord.x
	if a.coord.y != b.coord.y:
		return a.coord.y < b.coord.y
	return a.coord.z < b.coord.z

func _shuffle_array(arr: Array) -> void:
	# Shuffle array using seeded RNG (Fisher-Yates algorithm)
	for i in range(arr.size() - 1, 0, -1):
		var j = rng.randi() % (i + 1)
		var temp = arr[i]
		arr[i] = arr[j]
		arr[j] = temp

func clear():
	if is_instance_valid(dungeon_tiles):
		for child in dungeon_tiles.get_children():
			child.queue_free()
	all_spawned_tiles.clear()
	room_assignment.clear()
	spawned_stairs_coords.clear()
	spawned_doors_coords_new.clear()
	apartment_rooms_by_floor.clear()
	room_connections.clear()
	tunnel_room = null

func generate_dungeon():
	var parent_name: String = String(get_parent().name) if get_parent() else "null"
	print("MultistoryBuildingDungeon.generate_dungeon() called - node: ", name, ", path: ", get_path(), ", is_inside_tree: ", is_inside_tree(), ", parent: ", parent_name)
	
	# Generate seed - in editor use local seed, in game use GameManager if available
	if Engine.is_editor_hint():
		# Editor mode - generate seed from system datetime
		dungeon_seed = int(Time.get_unix_time_from_system())
		rng.seed = dungeon_seed
		seed_received = true
		print("MultistoryBuildingDungeon: Editor using local seed: ", dungeon_seed)
	elif multiplayer.has_multiplayer_peer():
		# Multiplayer mode - try to get seed from GameManager if available
		if is_instance_valid(GameManager) and GameManager.dungeon_seed_received:
			if multiplayer.is_server():
				dungeon_seed = GameManager.dungeon_seed
				rng.seed = dungeon_seed
				seed_received = true
				print("MultistoryBuildingDungeon: Host using seed from GameManager: ", dungeon_seed)
			else:
				# Client waits for seed from GameManager
				seed_received = false
				if not GameManager.dungeon_seed_received:
					await GameManager.dungeon_seed_synced
				dungeon_seed = GameManager.dungeon_seed
				rng.seed = dungeon_seed
				seed_received = true
				print("MultistoryBuildingDungeon: Client using seed from GameManager: ", dungeon_seed)
		else:
			# GameManager not available - use local seed
			dungeon_seed = int(Time.get_unix_time_from_system())
			rng.seed = dungeon_seed
			seed_received = true
			print("MultistoryBuildingDungeon: GameManager not available, using local seed: ", dungeon_seed)
	else:
		# Single player - generate seed from system datetime
		dungeon_seed = int(Time.get_unix_time_from_system())
		rng.seed = dungeon_seed
		seed_received = true
	
	# Clear existing tiles
	clear()

	# Clear and recreate doors dictionary to ensure correct type
	spawned_doors_coords_new = {}

	# Create tunnel room for all tunnel tiles
	tunnel_room = ResourceDungeonRoom.new()
	tunnel_room.base_room_height = 0 # Tunnels can be on any floor

	# Проверить, что есть высоты этажей
	if floors_heights.is_empty():
		push_error("MultistoryBuildingDungeon: floors_heights is empty!")
		return
	
	var floors_count: int = floors_heights.size()
	
	# Вычислить накопительные высоты этажей
	var floor_y_positions: Array[int] = []
	var current_y: int = 0
	for floor_height in floors_heights:
		floor_y_positions.append(current_y)
		current_y += floor_height
	
	# Генерация этажей
	for floor_num in range(floors_count):
		var floor_y: int = floor_y_positions[floor_num]
		var floor_height: int = floors_heights[floor_num]
		await _generate_floor(floor_y, floor_height)
		await _await_frame() # Await после каждого этажа

	# Объединение комнат дверьми на каждом этаже (до конфигурации тайлов!)
	for floor_num in range(floors_count):
		var floor_y: int = floor_y_positions[floor_num]
		await _connect_rooms_with_doors_on_floor(floor_y)
		await _await_frame()

	# Соединение тупиковых комнат (dead-end rooms) на каждом этаже
	for floor_num in range(floors_count):
		var floor_y: int = floor_y_positions[floor_num]
		var dead_end_rooms: Array[ResourceDungeonRoom] = _find_dead_end_rooms(floor_y)
		await _connect_dead_end_rooms(floor_y, dead_end_rooms)
		await _await_frame()

	# Конфигурация тайлов с проверкой комнат
	await _configure_all_tiles_with_room_check()
	await _await_frame()

	await spawn_stairs_between_floors()
	await _await_frame()
	await _connect_dead_end_tiles_with_doors(floor_y_positions)
	await clear_stairs_on_tiles_with_no_floor()
	await reconfigure_all_tunnel_tiles()

	# await _configure_all_tiles_with_room_check()
	# Финальный проход - спавн заблокированных дверей на краях открытых в пустоту направлений
	await _spawn_blocked_doors_on_open_edges(floor_y_positions)
	await _await_frame()

	await spawn_debug_spheres_on_stairs_ends()
	await spawn_props()
	await spawn_pickups()
	await spawn_mobs()
	await spawn_wall_torches()
	await spawn_light_stands()
	print("DEBUG: Final dungeon generation summary:")
	print("  Total spawned stairs: ", spawned_stairs_coords.size())
	level_generated.emit()


func _generate_floor(floor_y: int, floor_height: int):
	# Генерация квартир на этаже
	var apartments_on_floor: Array[ResourceDungeonRoom] = []
	
	# Определить количество комнат на этаже
	var rooms_count: int = rng.randi_range(rooms_per_floor_min_max.x, rooms_per_floor_min_max.y)
	
	# Структура для хранения информации о комнатах: {room: {x_start, x_end, z_start, z_end}}
	var rooms_data: Array[Dictionary] = []
	
	# Первая комната в центре (0, 0)
	var first_room_width: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
	var first_room_depth: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
	var first_room_x_start: int = - first_room_width / 2
	var first_room_z_start: int = - first_room_depth / 2
	var first_room_x_end: int = first_room_x_start + first_room_width
	var first_room_z_end: int = first_room_z_start + first_room_depth
	# Генерировать случайную высоту для первой комнаты от 1 до floor_height
	var first_room_height: int = rng.randi_range(1, floor_height)
	
	var first_room = await _generate_apartment(first_room_x_start, first_room_x_end, first_room_z_start, first_room_z_end, floor_y, first_room_height)
	if first_room != null:
		apartments_on_floor.append(first_room)
		rooms_data.append({
			"room": first_room,
			"x_start": first_room_x_start,
			"x_end": first_room_x_end,
			"z_start": first_room_z_start,
			"z_end": first_room_z_end
		})
		await get_tree().process_frame
	
	# Генерировать остальные комнаты
	var rooms_created: int = 1
	var max_attempts: int = rooms_count * 100 # Максимум попыток на комнату
	var attempts: int = 0
	
	while rooms_created < rooms_count and attempts < max_attempts:
		attempts += 1
		
		# Определить размер новой комнаты
		var room_width: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
		var room_depth: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
		# Генерировать случайную высоту для комнаты от 1 до floor_height
		var room_height: int = rng.randi_range(1, floor_height)
		
		# Найти позицию для новой комнаты по касательной к существующим
		var room_pos: Dictionary = _find_tangent_position(rooms_data, room_width, room_depth)
		
		if room_pos.has("x_start"):
			# Создать комнату
			var apartment_room = await _generate_apartment(
				room_pos.x_start, room_pos.x_end,
				room_pos.z_start, room_pos.z_end,
				floor_y, room_height
			)
			
			if apartment_room != null:
				apartments_on_floor.append(apartment_room)
				rooms_data.append({
					"room": apartment_room,
					"x_start": room_pos.x_start,
					"x_end": room_pos.x_end,
					"z_start": room_pos.z_start,
					"z_end": room_pos.z_end
				})
				rooms_created += 1
				await get_tree().process_frame
				
				# Await каждые 3 комнаты
				if rooms_created % 3 == 0:
					await _await_frame()
		
		# Await каждые 50 попыток
		if attempts % 50 == 0:
			await _await_frame()
	
	# Сохранить квартиры этого этажа
	apartment_rooms_by_floor[floor_y] = apartments_on_floor

func _find_tangent_position(rooms_data: Array[Dictionary], room_width: int, room_depth: int) -> Dictionary:
	# Найти позицию для новой комнаты, которая касается существующих комнат
	# Комната должна соседствовать (иметь общую стену), но не пересекаться
	if rooms_data.is_empty():
		return {}
	
	# Перемешать существующие комнаты для случайного порядка проверки
	var shuffled_rooms = rooms_data.duplicate()
	_shuffle_array(shuffled_rooms)
	
	# Для каждой существующей комнаты проверить возможные позиции вокруг неё
	for existing_room_data in shuffled_rooms:
		var ex_x_start: int = existing_room_data.x_start
		var ex_x_end: int = existing_room_data.x_end
		var ex_z_start: int = existing_room_data.z_start
		var ex_z_end: int = existing_room_data.z_end
		
		# Возможные позиции: справа, слева, сверху, снизу
		var candidate_positions: Array[Dictionary] = []
		
		# Справа от существующей комнаты
		var right_x_start: int = ex_x_end
		var right_x_end: int = right_x_start + room_width
		var right_z_start: int = ex_z_start
		var right_z_end: int = right_z_start + room_depth
		candidate_positions.append({
			"x_start": right_x_start,
			"x_end": right_x_end,
			"z_start": right_z_start,
			"z_end": right_z_end,
			"touches": true # Касается по правой стене
		})
		
		# Слева от существующей комнаты
		var left_x_end: int = ex_x_start
		var left_x_start: int = left_x_end - room_width
		var left_z_start: int = ex_z_start
		var left_z_end: int = left_z_start + room_depth
		candidate_positions.append({
			"x_start": left_x_start,
			"x_end": left_x_end,
			"z_start": left_z_start,
			"z_end": left_z_end,
			"touches": true # Касается по левой стене
		})
		
		# Сверху от существующей комнаты (вперед по Z)
		var top_x_start: int = ex_x_start
		var top_x_end: int = ex_x_end
		var top_z_end: int = ex_z_start
		var top_z_start: int = top_z_end - room_depth
		candidate_positions.append({
			"x_start": top_x_start,
			"x_end": top_x_end,
			"z_start": top_z_start,
			"z_end": top_z_end,
			"touches": true # Касается по верхней стене
		})
		
		# Снизу от существующей комнаты (назад по Z)
		var bottom_x_start: int = ex_x_start
		var bottom_x_end: int = ex_x_end
		var bottom_z_start: int = ex_z_end
		var bottom_z_end: int = bottom_z_start + room_depth
		candidate_positions.append({
			"x_start": bottom_x_start,
			"x_end": bottom_x_end,
			"z_start": bottom_z_start,
			"z_end": bottom_z_end,
			"touches": true # Касается по нижней стене
		})
		
		# Перемешать кандидатов для случайного выбора
		_shuffle_array(candidate_positions)
		
		# Проверить каждую позицию
		for candidate in candidate_positions:
			# Проверить, что комната не пересекается с существующими комнатами
			var intersects: bool = false
			for other_room_data in rooms_data:
				if _rooms_intersect(
					candidate.x_start, candidate.x_end, candidate.z_start, candidate.z_end,
					other_room_data.x_start, other_room_data.x_end, other_room_data.z_start, other_room_data.z_end
				):
					intersects = true
					break
			
			if not intersects:
				# Проверить, что комната действительно касается хотя бы одной существующей комнаты
				var touches_any: bool = false
				for other_room_data in rooms_data:
					if _rooms_touch(
						candidate.x_start, candidate.x_end, candidate.z_start, candidate.z_end,
						other_room_data.x_start, other_room_data.x_end, other_room_data.z_start, other_room_data.z_end
					):
						touches_any = true
						break
				
				if touches_any:
					return candidate
	
	return {}

func _rooms_intersect(x1_start: int, x1_end: int, z1_start: int, z1_end: int,
					  x2_start: int, x2_end: int, z2_start: int, z2_end: int) -> bool:
	# Проверить, пересекаются ли две комнаты
	# Комнаты пересекаются, если их прямоугольники перекрываются
	return not (x1_end <= x2_start or x1_start >= x2_end or z1_end <= z2_start or z1_start >= z2_end)

func _rooms_touch(x1_start: int, x1_end: int, z1_start: int, z1_end: int,
				  x2_start: int, x2_end: int, z2_start: int, z2_end: int) -> bool:
	# Проверить, касаются ли две комнаты (имеют общую стену)
	# Комнаты касаются, если они соседствуют по одной из сторон и не пересекаются
	# Проверить пересечение по X и касание по Z
	if not (x1_end <= x2_start or x1_start >= x2_end):
		# Есть перекрытие по X
		if z1_end == z2_start or z1_start == z2_end:
			return true # Касаются по Z
	
	# Проверить пересечение по Z и касание по X
	if not (z1_end <= z2_start or z1_start >= z2_end):
		# Есть перекрытие по Z
		if x1_end == x2_start or x1_start == x2_end:
			return true # Касаются по X
	
	return false

func _generate_apartment(x_start: int, x_end: int, z_start: int, z_end: int, floor_y: int, floor_height: int) -> ResourceDungeonRoom:
	# Создать комнату для квартиры
	var apartment_room = ResourceDungeonRoom.new()
	apartment_room.base_room_height = floor_y
	apartment_room.default_vertical_wall_tiles_amount = floor_height
	
	# Создать тайлы на всех вертикальных уровнях этажа
	var tiles_created: int = 0
	for x in range(x_start, x_end):
		for z in range(z_start, z_end):
			# Создать тайлы на всех уровнях от floor_y до floor_y + floor_height - 1
			for y_offset in range(floor_height):
				var coord: Vector3i = Vector3i(x, floor_y + y_offset, z)
				
				# Создать тайл
				var world_position: Vector3 = Vector3(
					coord.x * TILE_SIZE.x,
					coord.y * TILE_SIZE.y,
					coord.z * TILE_SIZE.z
				)
				
				var tile: DungeonTile = DUNGEON_TILE.instantiate()
				tile.position = world_position
				tile.coord = coord
				tile.master_dungeon = self
				dungeon_tiles.add_child(tile)
				tile.owner = _get_edited_scene_root()
				
				all_spawned_tiles[tile] = apartment_room
				room_assignment[tile] = apartment_room
				
				tiles_created += 1
				# Await каждые 50 тайлов
				if tiles_created % 50 == 0:
					await _await_frame()
	
	return apartment_room

func _connect_rooms_with_doors_on_floor(floor_y: int):
	# Объединение комнат дверьми на этаже используя flood fill алгоритм
	if not apartment_rooms_by_floor.has(floor_y):
		return
	
	var rooms_on_floor: Array[ResourceDungeonRoom] = apartment_rooms_by_floor[floor_y]
	
	if rooms_on_floor.size() <= 1:
		return # Нет смысла объединять одну комнату или меньше
	
	# Получить все тайлы на этом этаже, сгруппированные по комнатам
	var tiles_by_room: Dictionary[ResourceDungeonRoom, Array] = {} # value array dungeon tile
	var tiles_found: int = 0
	for tile in all_spawned_tiles.keys():
		if tile.coord.y != floor_y:
			continue
		var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
		if room == null:
			continue
		if not tiles_by_room.has(room):
			tiles_by_room[room] = []
		tiles_by_room[room].append(tile)
		tiles_found += 1
	
	# Sort tiles in each room to ensure deterministic order
	for room in tiles_by_room:
		tiles_by_room[room].sort_custom(_sort_tiles_by_coord)
	
	
	# Фильтровать комнаты - оставить только те, у которых есть тайлы на этом этаже
	var rooms_with_tiles: Array[ResourceDungeonRoom] = []
	for room in rooms_on_floor:
		if tiles_by_room.has(room) and tiles_by_room[room].size() > 0:
			rooms_with_tiles.append(room)
	
	if rooms_with_tiles.size() <= 1:
		return
	
	# Найти комнату с наименьшим количеством тайлов
	var unconnected_rooms: Array[ResourceDungeonRoom] = rooms_with_tiles.duplicate()
	var connected_rooms: Array[ResourceDungeonRoom] = []
	
	# Найти комнату с минимальным количеством тайлов
	var min_tiles_count: int = 999999 # Используем большое число вместо INF
	var start_room: ResourceDungeonRoom = null
	
	for room in unconnected_rooms:
		var tiles_count: int = tiles_by_room.get(room, []).size()
		if tiles_count > 0:
			if tiles_count < min_tiles_count:
				min_tiles_count = tiles_count
				start_room = room
	
	if start_room == null:
		# Вывести информацию о комнатах
		return
	
	
	# Добавить стартовую комнату в соединенные
	connected_rooms.append(start_room)
	unconnected_rooms.erase(start_room)
	
	# Flood fill: пока есть несоединенные комнаты
	var rooms_processed: int = 0
	while unconnected_rooms.size() > 0:
		# Найти несоединенные комнаты, которые соседствуют с соединенными
		var rooms_to_connect: Array[ResourceDungeonRoom] = []
		
		for connected_room in connected_rooms:
			for unconnected_room in unconnected_rooms:
				if unconnected_room in rooms_to_connect:
					continue
				
				# Проверить, соседствуют ли комнаты
				if _rooms_are_neighbors(connected_room, unconnected_room, floor_y, tiles_by_room):
					rooms_to_connect.append(unconnected_room)
		
		if rooms_to_connect.is_empty():
			# Если не нашли соседних комнат, попробуем найти любую несоединенную
			# и соединить её с ближайшей соединенной
			if unconnected_rooms.size() > 0:
				var fallback_room: ResourceDungeonRoom = unconnected_rooms[0]
				var closest_connected: ResourceDungeonRoom = _find_closest_room(fallback_room, connected_rooms, floor_y, tiles_by_room)
				if closest_connected != null:
					rooms_to_connect.append(fallback_room)
			else:
				break
		
		# Заспавнить двери между соединенными и найденными комнатами
		
		for room_to_connect in rooms_to_connect:
			# Найти комнату из connected_rooms, которая соседствует с room_to_connect
			var source_room: ResourceDungeonRoom = null
			for connected_room in connected_rooms:
				if _rooms_are_neighbors(connected_room, room_to_connect, floor_y, tiles_by_room):
					source_room = connected_room
					break
			
			if source_room == null:
				# Если не нашли соседнюю, используем ближайшую
				source_room = _find_closest_room(room_to_connect, connected_rooms, floor_y, tiles_by_room)

			if source_room != null:
				# Заспавнить двери между source_room и room_to_connect
				await _spawn_doors_between_rooms(source_room, room_to_connect, floor_y, tiles_by_room)
			
			# Добавить найденную комнату в соединенные
			connected_rooms.append(room_to_connect)
			unconnected_rooms.erase(room_to_connect)
		
		rooms_processed += 1
		if rooms_processed % 5 == 0:
			await _await_frame()
	

func _rooms_are_neighbors(room1: ResourceDungeonRoom, room2: ResourceDungeonRoom, floor_y: int, tiles_by_room: Dictionary) -> bool:
	# Проверить, соседствуют ли две комнаты (имеют соседние тайлы)
	var tiles1: Array = tiles_by_room.get(room1, [])
	var tiles2: Array = tiles_by_room.get(room2, [])
	
	var neighbors_found: int = 0
	for tile1 in tiles1:
		if not tile1 is DungeonTile:
			continue
		if tile1.coord.y != floor_y:
			continue
		for tile2 in tiles2:
			if not tile2 is DungeonTile:
				continue
			if tile2.coord.y != floor_y:
				continue
			
			# Проверить, являются ли тайлы соседями по горизонтали
			var offset: Vector3i = tile1.coord - tile2.coord
			if offset.y == 0 and ((abs(offset.x) == 1 and offset.z == 0) or (abs(offset.z) == 1 and offset.x == 0)):
				neighbors_found += 1
				return true
	
	return false

func _find_closest_room(target_room: ResourceDungeonRoom, candidate_rooms: Array[ResourceDungeonRoom], floor_y: int, tiles_by_room: Dictionary) -> ResourceDungeonRoom:
	# Найти ближайшую комнату из candidate_rooms к target_room
	var target_tiles: Array[DungeonTile] = tiles_by_room.get(target_room, [])
	if target_tiles.is_empty():
		return null
	
	var closest_room: ResourceDungeonRoom = null
	var min_distance: float = INF
	
	for candidate_room in candidate_rooms:
		var candidate_tiles: Array[DungeonTile] = tiles_by_room.get(candidate_room, [])
		if candidate_tiles.is_empty():
			continue
		
		# Найти минимальное расстояние между тайлами
		for target_tile in target_tiles:
			if target_tile.coord.y != floor_y:
				continue
			for candidate_tile in candidate_tiles:
				if candidate_tile.coord.y != floor_y:
					continue
				
				var distance: float = (target_tile.coord - candidate_tile.coord).length()
				if distance < min_distance:
					min_distance = distance
					closest_room = candidate_room
	
	return closest_room

func _spawn_doors_between_rooms(room1: ResourceDungeonRoom, room2: ResourceDungeonRoom, floor_y: int, tiles_by_room: Dictionary):
	# Заспавнить двери между двумя комнатами на стыках соседних тайлов
	# Для туннельных соединений (где одна из комнат - tunnel_room) не проверяем существующие соединения,
	# потому что комната может иметь несколько дверей в туннельную систему
	if room1 != tunnel_room and room2 != tunnel_room:
		# Проверить, есть ли уже соединение между этими обычными комнатами
		var room1_connections = room_connections.get(room1, [])
		if room1_connections.has(room2):
			return

	var tiles1: Array = tiles_by_room.get(room1, [])
	var tiles2: Array = tiles_by_room.get(room2, [])

	
	# Найти все пары соседних тайлов между комнатами
	# Структура: {tile1: tile2, offset: offset}
	var door_candidates: Array[Dictionary] = []
	
	for tile1 in tiles1:
		if not tile1 is DungeonTile:
			continue
		if tile1.coord.y != floor_y:
			continue
		
		# Проверить соседей по горизонтали
		var neighbor_offsets: Array[Vector3i] = [
			Vector3i(1, 0, 0), # Right
			Vector3i(-1, 0, 0), # Left
			Vector3i(0, 0, 1), # Forward
			Vector3i(0, 0, -1) # Backward
		]
		
		for offset in neighbor_offsets:
			var neighbor_coord: Vector3i = tile1.coord + offset
			var neighbor_tile: DungeonTile = _get_tile_at_coord(neighbor_coord)
			
			if neighbor_tile != null:
				# Проверить, что соседний тайл принадлежит второй комнате
				var neighbor_room: ResourceDungeonRoom = all_spawned_tiles.get(neighbor_tile, null)
				if neighbor_room == room2:
					# Найден соседний тайл из другой комнаты
					# Сохранить пару тайлов и направление
					var candidate: Dictionary = {
						"tile1": tile1,
						"tile2": neighbor_tile,
						"offset": offset
					}
					door_candidates.append(candidate)
	
	
	# Заспавнить дверь на одном из кандидатов
	if door_candidates.size() > 0:
		# Выбрать случайный кандидат
		var candidate: Dictionary = door_candidates[rng.randi() % door_candidates.size()]
		var tile1: DungeonTile = candidate.tile1
		var tile2: DungeonTile = candidate.tile2
		var offset: Vector3i = candidate.offset
		
		# Удалить стены между тайлами (на нижнем уровне)
		_remove_wall_between_tiles(tile1, tile2, offset)
		
		# Удалить стены между верхними тайлами (если они есть и принадлежат к одной комнате)
		var upper_tile1: DungeonTile = _get_tile_at_coord(Vector3i(tile1.coord.x, tile1.coord.y + 1, tile1.coord.z))
		var upper_tile2: DungeonTile = _get_tile_at_coord(Vector3i(tile2.coord.x, tile2.coord.y + 1, tile2.coord.z))
		if upper_tile1 != null and upper_tile2 != null:
			# Проверить, что верхние тайлы принадлежат к одной комнате
			var upper_room1 = all_spawned_tiles.get(upper_tile1, null)
			var upper_room2 = all_spawned_tiles.get(upper_tile2, null)

			# Вырезать стены только если верхние тайлы принадлежат к одной комнате
			if upper_room1 == upper_room2:
				_remove_wall_between_tiles(upper_tile1, upper_tile2, offset)
		
		# Заспавнить дверь на одном из тайлов
		await _spawn_door_between_tiles(tile1, tile2, offset, floor_y)

func _remove_wall_between_tiles(tile1: DungeonTile, tile2: DungeonTile, offset: Vector3i):
	# Удалить стены между двумя соседними тайлами
	# offset - направление от tile1 к tile2
	print("DEBUG _remove_wall_between_tiles: tile1=", tile1.coord, " tile2=", tile2.coord, " offset=", offset)
	
	# У tile1 удалить стену в направлении offset
	if offset == Vector3i(1, 0, 0):
		# tile2 справа от tile1 - удалить правую стену tile1
		var tile1_wall_exists = tile1.wall_r != null
		var tile1_wall_valid = is_instance_valid(tile1.wall_r)
		var tile1_wall_queued = tile1.wall_r != null and tile1.wall_r.is_queued_for_deletion() if tile1.wall_r != null else false
		var tile2_wall_exists = tile2.wall_l != null
		var tile2_wall_valid = is_instance_valid(tile2.wall_l)
		var tile2_wall_queued = tile2.wall_l != null and tile2.wall_l.is_queued_for_deletion() if tile2.wall_l != null else false
		print("  RIGHT: tile1.wall_r: exists=", tile1_wall_exists, " valid=", tile1_wall_valid, " queued=", tile1_wall_queued)
		print("        tile2.wall_l: exists=", tile2_wall_exists, " valid=", tile2_wall_valid, " queued=", tile2_wall_queued)
		if is_instance_valid(tile1.wall_r) and not tile1.wall_r.is_queued_for_deletion():
			tile1.wall_r.queue_free()
			tile1.wall_r = null
		# У tile2 удалить левую стену
		if is_instance_valid(tile2.wall_l) and not tile2.wall_l.is_queued_for_deletion():
			tile2.wall_l.queue_free()
			tile2.wall_l = null
	elif offset == Vector3i(-1, 0, 0):
		# tile2 слева от tile1 - удалить левую стену tile1
		var tile1_wall_exists = tile1.wall_l != null
		var tile1_wall_valid = is_instance_valid(tile1.wall_l)
		var tile1_wall_queued = tile1.wall_l != null and tile1.wall_l.is_queued_for_deletion() if tile1.wall_l != null else false
		var tile2_wall_exists = tile2.wall_r != null
		var tile2_wall_valid = is_instance_valid(tile2.wall_r)
		var tile2_wall_queued = tile2.wall_r != null and tile2.wall_r.is_queued_for_deletion() if tile2.wall_r != null else false
		print("  LEFT: tile1.wall_l: exists=", tile1_wall_exists, " valid=", tile1_wall_valid, " queued=", tile1_wall_queued)
		print("       tile2.wall_r: exists=", tile2_wall_exists, " valid=", tile2_wall_valid, " queued=", tile2_wall_queued)
		if is_instance_valid(tile1.wall_l) and not tile1.wall_l.is_queued_for_deletion():
			tile1.wall_l.queue_free()
			tile1.wall_l = null
		# У tile2 удалить правую стену
		if is_instance_valid(tile2.wall_r) and not tile2.wall_r.is_queued_for_deletion():
			tile2.wall_r.queue_free()
			tile2.wall_r = null
	elif offset == Vector3i(0, 0, 1):
		# tile2 НАЗАД от tile1 (Z+) - удалить заднюю стену tile1 (wall_b)
		var tile1_wall_exists = tile1.wall_b != null
		var tile1_wall_valid = is_instance_valid(tile1.wall_b)
		var tile1_wall_queued = tile1.wall_b != null and tile1.wall_b.is_queued_for_deletion() if tile1.wall_b != null else false
		var tile2_wall_exists = tile2.wall_f != null
		var tile2_wall_valid = is_instance_valid(tile2.wall_f)
		var tile2_wall_queued = tile2.wall_f != null and tile2.wall_f.is_queued_for_deletion() if tile2.wall_f != null else false
		print("  BACK (Z+): tile1.wall_b: exists=", tile1_wall_exists, " valid=", tile1_wall_valid, " queued=", tile1_wall_queued)
		print("            tile2.wall_f: exists=", tile2_wall_exists, " valid=", tile2_wall_valid, " queued=", tile2_wall_queued)
		if is_instance_valid(tile1.wall_b) and not tile1.wall_b.is_queued_for_deletion():
			tile1.wall_b.queue_free()
			tile1.wall_b = null
		# У tile2 удалить переднюю стену (wall_f)
		if is_instance_valid(tile2.wall_f) and not tile2.wall_f.is_queued_for_deletion():
			tile2.wall_f.queue_free()
			tile2.wall_f = null
	elif offset == Vector3i(0, 0, -1):
		# tile2 ВПЕРЕД от tile1 (Z-) - удалить переднюю стену tile1 (wall_f)
		var tile1_wall_exists = tile1.wall_f != null
		var tile1_wall_valid = is_instance_valid(tile1.wall_f)
		var tile1_wall_queued = tile1.wall_f != null and tile1.wall_f.is_queued_for_deletion() if tile1.wall_f != null else false
		var tile2_wall_exists = tile2.wall_b != null
		var tile2_wall_valid = is_instance_valid(tile2.wall_b)
		var tile2_wall_queued = tile2.wall_b != null and tile2.wall_b.is_queued_for_deletion() if tile2.wall_b != null else false
		print("  FORWARD (Z-): tile1.wall_f: exists=", tile1_wall_exists, " valid=", tile1_wall_valid, " queued=", tile1_wall_queued)
		print("               tile2.wall_b: exists=", tile2_wall_exists, " valid=", tile2_wall_valid, " queued=", tile2_wall_queued)
		if is_instance_valid(tile1.wall_f) and not tile1.wall_f.is_queued_for_deletion():
			tile1.wall_f.queue_free()
			tile1.wall_f = null
		# У tile2 удалить заднюю стену (wall_b)
		if is_instance_valid(tile2.wall_b) and not tile2.wall_b.is_queued_for_deletion():
			tile2.wall_b.queue_free()
			tile2.wall_b = null

func _spawn_door_between_tiles(tile1: DungeonTile, tile2: DungeonTile, offset: Vector3i, floor_y: int):
	# Заспавнить дверь между двумя тайлами
	# Используем tile1 как позицию для двери
	var door_tile: DungeonTile = tile1
	
	# Проверить, что тайл на нижнем уровне этажа (floor_y)
	if door_tile.coord.y != floor_y:
		return
	
	# Проверить, что у тайла есть пол (нет соседа снизу на том же уровне этажа)
	var neighbor_below: DungeonTile = _get_tile_at_coord(door_tile.coord + Vector3i(0, -1, 0))
	if neighbor_below != null:
		if neighbor_below.coord.y >= floor_y:
			return
	
	# # Проверить, что над тайлом есть тайл (двери 2 тайла высотой)
	# var upper_coord: Vector3i = Vector3i(door_tile.coord.x, door_tile.coord.y + 1, door_tile.coord.z)
	# var upper_tile: DungeonTile = _get_tile_at_coord(upper_coord)
	
	# if upper_tile == null:
	# 	# Создать тайл сверху
	# 	var room: ResourceDungeonRoom = all_spawned_tiles.get(door_tile, null)
	# 	if room != null:
	# 		_spawn_tile_at_coord_for_door(room, upper_coord)
	# 		upper_tile = _get_tile_at_coord(upper_coord)
	
	# if upper_tile == null:
	# 	return
	
	# Проверить, что здесь еще нет двери между этими тайлами
	var test_coord1 = tile1.coord
	var test_coord2 = tile2.coord
	var test_sorted_coords = [test_coord1, test_coord2]
	test_sorted_coords.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))))
	var test_coord1_str = "%d_%d_%d" % [test_sorted_coords[0].x, test_sorted_coords[0].y, test_sorted_coords[0].z]
	var test_coord2_str = "%d_%d_%d" % [test_sorted_coords[1].x, test_sorted_coords[1].y, test_sorted_coords[1].z]
	var test_pair_key = test_coord1_str + "-" + test_coord2_str
	if spawned_doors_coords_new.has(test_pair_key):
		return
	
	# Выбрать случайный префаб двери
	var door_prefab = DOORS_PREFABS[rng.randi() % DOORS_PREFABS.size()]
	var door = door_prefab.instantiate()
	if door == null:
		return
	
	# Определить ориентацию двери на основе направления между тайлами
	var door_rotation_y: float = 0.0
	if abs(offset.x) > 0:
		# Сосед по X оси - дверь должна быть повернута на 90°
		door_rotation_y = deg_to_rad(90)
	elif abs(offset.z) > 0:
		# Сосед по Z оси - дверь без поворота
		door_rotation_y = 0.0
	
	# Позиция двери - между двумя тайлами
	# Вычисляем среднюю точку между tile1 и tile2
	var door_position: Vector3 = (tile1.position + tile2.position) / 2.0
	
	door.rotation.y = door_rotation_y
	door.position = door_position
	
	var door_name = "Door_%d_%d_%d" % [door_tile.coord.x, door_tile.coord.y, door_tile.coord.z]
	door.name = door_name
	
	dungeon_tiles.add_child(door)
	door.owner = _get_edited_scene_root()

	# Save door by pair of coordinates (sorted to ensure consistent key)
	var coord1 = tile1.coord
	var coord2 = tile2.coord
	var sorted_coords = [coord1, coord2]
	sorted_coords.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))))
	var coord1_str = "%d_%d_%d" % [sorted_coords[0].x, sorted_coords[0].y, sorted_coords[0].z]
	var coord2_str = "%d_%d_%d" % [sorted_coords[1].x, sorted_coords[1].y, sorted_coords[1].z]
	var pair_key = coord1_str + "-" + coord2_str
	spawned_doors_coords_new[pair_key] = door

	# Track room connections
	var room1: ResourceDungeonRoom = all_spawned_tiles.get(tile1, null)
	var room2: ResourceDungeonRoom = all_spawned_tiles.get(tile2, null)
	if room1 != null and room2 != null and room1 != room2:
		# Add connection from room1 to room2
		if not room_connections.has(room1):
			room_connections[room1] = []
		if not room_connections[room1].has(room2):
			room_connections[room1].append(room2)

		# Add connection from room2 to room1 (bidirectional)
		if not room_connections.has(room2):
			room_connections[room2] = []
		if not room_connections[room2].has(room1):
			room_connections[room2].append(room1)


func _spawn_door_at_tile(tile: DungeonTile, floor_y: int):
	# Заспавнить дверь на указанном тайле
	# Note: door existence check removed since doors are now stored by pairs
	# if spawned_doors_coords.has(tile.coord):
	# 	print("_spawn_door_at_tile: Door already exists at ", tile.coord)
	# 	return  # Дверь уже есть
	# Проверить, что тайл на нижнем уровне этажа (floor_y)
	# floor_y - это Y координата нижнего уровня текущего этажа
	if tile.coord.y != floor_y:
		return
	
	# Проверить, что у тайла есть пол (нет соседа снизу на том же уровне этажа)
	# Для первого этажа (floor_y=0) соседа снизу не будет
	# Для верхних этажей сосед снизу может быть тайлом с предыдущего этажа, что нормально
	# Но если сосед снизу на том же уровне этажа (floor_y-1) - значит это не нижний тайл этажа
	var neighbor_below: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(0, -1, 0))
	if neighbor_below != null:
		# Проверить, что сосед снизу не на том же этаже (не на уровне floor_y-1)
		# Если floor_y > 0 и neighbor_below.coord.y == floor_y - 1, это тайл с предыдущего этажа - это нормально
		# Но если neighbor_below.coord.y >= floor_y, значит это тайл того же этажа - у этого тайла нет пола
		if neighbor_below.coord.y >= floor_y:
			return # У этого тайла нет пола (есть тайл того же этажа снизу)
	
	# Проверить соседей для определения ориентации двери
	var neighbor_r: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(1, 0, 0))
	var neighbor_l: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(-1, 0, 0))
	var neighbor_f: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(0, 0, -1))
	var neighbor_b: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(0, 0, 1))
	
	# Проверить, что есть хотя бы один сосед из другой комнаты
	var tile_room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
	if tile_room == null:
		return
	
	var has_different_room_neighbor: bool = false
	var door_direction: Vector3i = Vector3i.ZERO # Направление к соседу из другой комнаты
	
	if neighbor_r != null:
		var neighbor_r_room: ResourceDungeonRoom = all_spawned_tiles.get(neighbor_r, null)
		if neighbor_r_room != null and neighbor_r_room != tile_room:
			has_different_room_neighbor = true
			door_direction = Vector3i(1, 0, 0)
	if neighbor_l != null and not has_different_room_neighbor:
		var neighbor_l_room: ResourceDungeonRoom = all_spawned_tiles.get(neighbor_l, null)
		if neighbor_l_room != null and neighbor_l_room != tile_room:
			has_different_room_neighbor = true
			door_direction = Vector3i(-1, 0, 0)
	if neighbor_f != null and not has_different_room_neighbor:
		var neighbor_f_room: ResourceDungeonRoom = all_spawned_tiles.get(neighbor_f, null)
		if neighbor_f_room != null and neighbor_f_room != tile_room:
			has_different_room_neighbor = true
			door_direction = Vector3i(0, 0, -1)
	if neighbor_b != null and not has_different_room_neighbor:
		var neighbor_b_room: ResourceDungeonRoom = all_spawned_tiles.get(neighbor_b, null)
		if neighbor_b_room != null and neighbor_b_room != tile_room:
			has_different_room_neighbor = true
			door_direction = Vector3i(0, 0, 1)
	
	if not has_different_room_neighbor:
		return # Нет соседей из другой комнаты
	
	
	# Проверить, что над тайлом есть тайл (двери 2 тайла высотой)
	var upper_coord: Vector3i = Vector3i(tile.coord.x, tile.coord.y + 1, tile.coord.z)
	var upper_tile: DungeonTile = _get_tile_at_coord(upper_coord)
	
	if upper_tile == null:
		# Создать тайл сверху
		var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
		if room != null:
			_spawn_tile_at_coord_for_door(room, upper_coord)
			upper_tile = _get_tile_at_coord(upper_coord)
	
	if upper_tile == null:
		return
	
	# Выбрать случайный префаб двери
	var door_prefab = DOORS_PREFABS[rng.randi() % DOORS_PREFABS.size()]
	var door = door_prefab.instantiate()
	if door == null:
		return
	
	# Определить ориентацию двери на основе направления к соседу из другой комнаты
	var door_rotation_y: float = 0.0
	if abs(door_direction.x) > 0:
		# Сосед по X оси - дверь должна быть повернута на 90°
		door_rotation_y = deg_to_rad(90)
	elif abs(door_direction.z) > 0:
		# Сосед по Z оси - дверь без поворота
		door_rotation_y = 0.0
	
	door.rotation.y = door_rotation_y
	door.position = tile.position
	
	var door_name = "Door_%d_%d_%d" % [tile.coord.x, tile.coord.y, tile.coord.z]
	door.name = door_name
	
	dungeon_tiles.add_child(door)
	door.owner = _get_edited_scene_root()

	# Note: door saving removed since this function is not used and doors are stored by pairs
	# spawned_doors_coords[tile.coord] = door

func _spawn_tile_at_coord_for_door(room: ResourceDungeonRoom, coord: Vector3i):
	# Создать тайл для двери (над дверным тайлом)
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	var tile: DungeonTile = DUNGEON_TILE.instantiate()
	tile.position = world_position
	tile.coord = coord
	tile.master_dungeon = self
	dungeon_tiles.add_child(tile)
	tile.owner = _get_edited_scene_root()
	
	all_spawned_tiles[tile] = room
	room_assignment[tile] = room

func reconfigure_all_tunnel_tiles():
	# loop over all tunnel room tiles and reconfigure them
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		if room_assignment[tile] == tunnel_room:
			tile.configure_tile_based_on_neighbours(_get_neighbor_tiles(tile), true)
			
	var deadendds_amount = 0
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		if tile.is_dead_end:
			deadendds_amount += 1
	print("Deadends amount: %d" % deadendds_amount)
	pass

func _configure_all_tiles_with_room_check():
	# Configure each tile based on its neighbors with room check
	var total_tiles = all_spawned_tiles.size()
	var tiles_configured: int = 0
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		var neighbors: Array[DungeonTile] = _get_neighbor_tiles(tile)
		tile.configure_tile_based_on_neighbours_with_room_check(neighbors, room_assignment, spawned_doors_coords_new)

		tiles_configured += 1
		# Await каждые 100 тайлов
		if tiles_configured % 100 == 0:
			await _await_frame()

func _get_neighbor_tiles(tile: DungeonTile) -> Array[DungeonTile]:
	var neighbors: Array[DungeonTile] = []
	var coord: Vector3i = tile.coord
	
	# Check all 6 directions: top, bottom, forward, back, right, left
	var neighbor_offsets: Array[Vector3i] = [
		Vector3i(0, 1, 0), # Top (ceiling check)
		Vector3i(0, -1, 0), # Bottom (floor check)
		Vector3i(0, 0, 1), # Forward (wall check)
		Vector3i(0, 0, -1), # Back (wall check)
		Vector3i(1, 0, 0), # Right (wall check)
		Vector3i(-1, 0, 0) # Left (wall check)
	]
	
	for offset in neighbor_offsets:
		var neighbor_coord: Vector3i = coord + offset
		var neighbor_tile: DungeonTile = _get_tile_at_coord(neighbor_coord)
		if neighbor_tile != null:
			neighbors.append(neighbor_tile)
	
	return neighbors

func _get_tile_at_coord(coord: Vector3i) -> DungeonTile:
	# Find tile at the given coordinate
	for tile in all_spawned_tiles.keys():
		if tile.coord == coord:
			return tile
	return null

func _find_dead_end_rooms(floor_y: int) -> Array[ResourceDungeonRoom]:
	# Find rooms on the given floor that have exactly one door connection
	var dead_end_rooms: Array[ResourceDungeonRoom] = []

	if not apartment_rooms_by_floor.has(floor_y):
		return dead_end_rooms

	var rooms_on_floor: Array[ResourceDungeonRoom] = apartment_rooms_by_floor[floor_y]

	for room in rooms_on_floor:
		var connections: Array = room_connections.get(room, [])
		if connections.size() == 1:
			dead_end_rooms.append(room)

	return dead_end_rooms

func _connect_dead_end_rooms(floor_y: int, initial_dead_end_rooms: Array[ResourceDungeonRoom]):
	# Connect dead-end rooms (rooms with exactly 1 door) either with doors (if adjacent) or tunnels (if not adjacent)
	# Continuously find and connect current dead-end rooms until no more pairs can be found
	var connected_pairs: int = 0

	# Keep finding and connecting dead-end rooms until we can't find more pairs
	while true:
		# Get current dead-end rooms (rooms with exactly 1 connection)
		var current_dead_ends: Array[ResourceDungeonRoom] = _find_dead_end_rooms(floor_y)

		# Filter to only include rooms that were initially dead-end (to avoid connecting rooms that gained connections from other paths)
		var valid_dead_ends: Array[ResourceDungeonRoom] = []
		for room in current_dead_ends:
			if initial_dead_end_rooms.has(room):
				valid_dead_ends.append(room)

		if valid_dead_ends.size() < 2:
			# If only one dead-end room remains, try to connect it to a random non-dead-end room
			if valid_dead_ends.size() == 1:
				var remaining_dead_end = valid_dead_ends[0]

				# Find a random room that is not a dead-end and not already connected to our remaining dead-end
				var target_room = _find_random_unconnected_room(remaining_dead_end, floor_y)
				if target_room != null:
					# Group tiles by room for both rooms
					var tiles_by_room: Dictionary[ResourceDungeonRoom, Array] = {}
					for tile in all_spawned_tiles.keys():
						if tile.coord.y != floor_y:
							continue
						var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
						if room == null or (room != remaining_dead_end and room != target_room):
							continue
						if not tiles_by_room.has(room):
							tiles_by_room[room] = []
						tiles_by_room[room].append(tile)

					# Sort tiles in each room to ensure deterministic order
					for room in tiles_by_room:
						tiles_by_room[room].sort_custom(_sort_tiles_by_coord)

					# Connect the remaining dead-end to the target room
					var room1: ResourceDungeonRoom = remaining_dead_end
					var room2: ResourceDungeonRoom = target_room


					# Check if rooms are adjacent (can connect with doors)
					if _rooms_are_neighbors(room1, room2, floor_y, tiles_by_room):
						await _spawn_doors_between_rooms(room1, room2, floor_y, tiles_by_room)
					else:
						await _create_tunnel_between_rooms(room1, room2, floor_y, tiles_by_room)

					connected_pairs += 1
			break

		# Group tiles by room for current dead-end rooms
		var tiles_by_room: Dictionary[ResourceDungeonRoom, Array] = {}
		for tile in all_spawned_tiles.keys():
			if tile.coord.y != floor_y:
				continue
			var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
			if room == null or not valid_dead_ends.has(room):
				continue
			if not tiles_by_room.has(room):
				tiles_by_room[room] = []
			tiles_by_room[room].append(tile)

		# Sort tiles in each room to ensure deterministic order
		for room in tiles_by_room:
			tiles_by_room[room].sort_custom(_sort_tiles_by_coord)

		# Shuffle and pick first two rooms to connect
		var shuffled_dead_ends = valid_dead_ends.duplicate()
		_shuffle_array(shuffled_dead_ends)

		var room1: ResourceDungeonRoom = shuffled_dead_ends[0]
		var room2: ResourceDungeonRoom = shuffled_dead_ends[1]


		# Check if rooms are already connected
		var room1_connections = room_connections.get(room1, [])
		if room1_connections.has(room2):
			connected_pairs += 1
			continue

		# Check if rooms are adjacent (can connect with doors)
		if _rooms_are_neighbors(room1, room2, floor_y, tiles_by_room):
			await _spawn_doors_between_rooms(room1, room2, floor_y, tiles_by_room)
		else:
			await _create_tunnel_between_rooms(room1, room2, floor_y, tiles_by_room)

		connected_pairs += 1

		# Prevent infinite loops - limit to reasonable number of connections
		if connected_pairs > 50:
			break


func _create_tunnel_between_rooms(room1: ResourceDungeonRoom, room2: ResourceDungeonRoom, floor_y: int, tiles_by_room: Dictionary[ResourceDungeonRoom, Array]):
	# Create a tunnel connecting two non-adjacent rooms
	# The tunnel will cut through walls and connect through doors
	var tiles1 = tiles_by_room.get(room1, [])
	var tiles2 = tiles_by_room.get(room2, [])

	if tiles1.is_empty() or tiles2.is_empty():
		return

	# Find the closest pair of tiles between the two rooms
	var closest_pair: Dictionary = _find_closest_tile_pair(tiles1, tiles2)
	if not closest_pair.has("tile1") or not closest_pair.has("tile2"):
		return

	var start_tile: DungeonTile = closest_pair.tile1
	var end_tile: DungeonTile = closest_pair.tile2


	# Find positions adjacent to the room tiles where the tunnel should connect
	# Avoid positions near rooms already connected to the source rooms
	var start_connected_rooms = room_connections.get(room1, [])
	var end_connected_rooms = room_connections.get(room2, [])

	var start_adjacent_pos: Vector3i = _find_best_adjacent_position(start_tile.coord, end_tile.coord, floor_y, start_connected_rooms)
	var end_adjacent_pos: Vector3i = _find_best_adjacent_position(end_tile.coord, start_tile.coord, floor_y, end_connected_rooms)


	# Create a path between the adjacent positions
	# Create an orthogonal L-shaped path (no diagonals)
	var path_coords: Array[Vector3i] = _create_orthogonal_path(start_adjacent_pos, end_adjacent_pos, floor_y)

	# Create tiles along the path if they don't exist
	for coord in path_coords:
		if _get_tile_at_coord(coord) == null:
			# Create a new tile for the tunnel
			var world_position: Vector3 = Vector3(
				coord.x * TILE_SIZE.x,
				coord.y * TILE_SIZE.y,
				coord.z * TILE_SIZE.z
			)

			var tunnel_tile: DungeonTile = DUNGEON_TILE.instantiate()
			tunnel_tile.position = world_position
			tunnel_tile.coord = coord
			tunnel_tile.master_dungeon = self
			dungeon_tiles.add_child(tunnel_tile)
			tunnel_tile.owner = _get_edited_scene_root()

			# Assign tunnel tile to the special tunnel room
			all_spawned_tiles[tunnel_tile] = tunnel_room
			room_assignment[tunnel_tile] = tunnel_room

	# Spawn doors connecting room tiles to adjacent tunnel tiles
	if not path_coords.is_empty():
		# Connect start room tile to first tunnel tile (should be adjacent)
		var first_tunnel_coord = path_coords[0]
		var first_tunnel_tile = _get_tile_at_coord(first_tunnel_coord)
		if first_tunnel_tile != null:
			var offset = first_tunnel_coord - start_tile.coord
			await _spawn_door_between_tiles(start_tile, first_tunnel_tile, offset, floor_y)

		# Connect end room tile to last tunnel tile (only if path reaches the end destination)
		var expected_end_coord = end_adjacent_pos
		var last_tunnel_coord = path_coords[path_coords.size() - 1]

		if last_tunnel_coord == expected_end_coord:
			# Path successfully reached the destination
			var last_tunnel_tile = _get_tile_at_coord(last_tunnel_coord)
			if last_tunnel_tile != null:
				var offset = last_tunnel_coord - end_tile.coord
				await _spawn_door_between_tiles(end_tile, last_tunnel_tile, offset, floor_y)

	# Configure the newly created tunnel tiles
	var tunnel_tiles_to_configure = []
	for coord in path_coords:
		var tunnel_tile = _get_tile_at_coord(coord)
		if tunnel_tile != null:
			tunnel_tiles_to_configure.append(tunnel_tile)

	# Configure tunnel tiles with room check
	for tile in tunnel_tiles_to_configure:
		var neighbors = _get_neighbor_tiles(tile)
		tile.configure_tile_based_on_neighbours_with_room_check(neighbors, room_assignment, spawned_doors_coords_new)

func _find_random_unconnected_room(dead_end_room: ResourceDungeonRoom, floor_y: int) -> ResourceDungeonRoom:
	# Find a random room that is not a dead-end and not already connected to the given dead-end room
	var candidate_rooms: Array[ResourceDungeonRoom] = []

	if not apartment_rooms_by_floor.has(floor_y):
		return null

	var rooms_on_floor: Array[ResourceDungeonRoom] = apartment_rooms_by_floor[floor_y]
	var dead_end_connections = room_connections.get(dead_end_room, [])

	for room in rooms_on_floor:
		# Skip if this is the dead-end room itself
		if room == dead_end_room:
			continue

		# Check if room is not a dead-end (has more than 1 connection)
		var room_connections_list = room_connections.get(room, [])
		if room_connections_list.size() <= 1:
			continue # This is also a dead-end or isolated room

		# Check if not already connected to our dead-end room
		if dead_end_connections.has(room):
			continue # Already connected

		# This room is a valid candidate
		candidate_rooms.append(room)

	if candidate_rooms.is_empty():
		return null

	# Return a random candidate
	return candidate_rooms[rng.randi() % candidate_rooms.size()]

func _find_best_adjacent_position(room_coord: Vector3i, target_coord: Vector3i, floor_y: int, rooms_to_avoid = []) -> Vector3i:
	# Find the best adjacent position to the room tile for tunnel connection
	# Prefer the direction that points toward the target
	# Ensure the position is free (no tile exists there)
	# Avoid positions that are adjacent to rooms we want to avoid
	var direction_to_target = (target_coord - room_coord).sign()

	# Collect all coordinates of tiles belonging to rooms we want to avoid
	var avoided_coords: Array[Vector3i] = []
	for room in rooms_to_avoid:
		for tile in all_spawned_tiles.keys():
			if all_spawned_tiles[tile] == room and tile.coord.y == floor_y:
				avoided_coords.append(tile.coord)

	# Try to find an adjacent position that points in the direction of the target
	var candidates = []

	# Primary direction (toward target)
	if direction_to_target.x != 0:
		candidates.append(room_coord + Vector3i(direction_to_target.x, 0, 0))
	if direction_to_target.z != 0:
		candidates.append(room_coord + Vector3i(0, 0, direction_to_target.z))

	# Secondary directions (perpendicular)
	if direction_to_target.x == 0: # Target is along Z axis, try X directions
		candidates.append(room_coord + Vector3i(1, 0, 0))
		candidates.append(room_coord + Vector3i(-1, 0, 0))
	if direction_to_target.z == 0: # Target is along X axis, try Z directions
		candidates.append(room_coord + Vector3i(0, 0, 1))
		candidates.append(room_coord + Vector3i(0, 0, -1))

	# Filter candidates to only include positions that are free (no tile exists)
	# and not adjacent to rooms we want to avoid
	var free_candidates = []
	for candidate in candidates:
		if _get_tile_at_coord(candidate) == null:
			# Check if this candidate is adjacent to any avoided room tiles
			var is_near_avoided_room = false
			for avoided_coord in avoided_coords:
				var distance = (candidate - avoided_coord).abs()
				# If candidate is adjacent (distance 1 in any direction) to an avoided tile
				if (distance.x <= 1 and distance.y == 0 and distance.z <= 1) and distance.x + distance.z > 0:
					is_near_avoided_room = true
					break

			if not is_near_avoided_room:
				free_candidates.append(candidate)

	# Return the first free candidate (prioritizes direction toward target)
	if not free_candidates.is_empty():
		return free_candidates[0]

	# If no free candidates found, try all 4 directions as fallback
	var fallback_candidates = [
		room_coord + Vector3i(1, 0, 0),
		room_coord + Vector3i(-1, 0, 0),
		room_coord + Vector3i(0, 0, 1),
		room_coord + Vector3i(0, 0, -1)
	]

	for fallback in fallback_candidates:
		if _get_tile_at_coord(fallback) == null:
			# Also check if fallback is not adjacent to avoided rooms
			var is_near_avoided_room = false
			for avoided_coord in avoided_coords:
				var distance = (fallback - avoided_coord).abs()
				if (distance.x <= 1 and distance.y == 0 and distance.z <= 1) and distance.x + distance.z > 0:
					is_near_avoided_room = true
					break

			if not is_near_avoided_room:
				return fallback

	# If still no free position found, return a default (though this should be rare)
	return room_coord + Vector3i(1, 0, 0)

func _find_closest_tile_pair(tiles1, tiles2) -> Dictionary:
	# Find the closest pair of tiles between two arrays of tiles
	var closest_pair: Dictionary = {}
	var min_distance: float = INF

	for tile1 in tiles1:
		for tile2 in tiles2:
			var distance: float = (tile1.coord - tile2.coord).length()
			if distance < min_distance:
				min_distance = distance
				closest_pair = {"tile1": tile1, "tile2": tile2}

	return closest_pair

func _create_orthogonal_path(start_coord: Vector3i, end_coord: Vector3i, floor_y: int) -> Array[Vector3i]:
	# Create an L-shaped orthogonal path (Manhattan distance) from start to end
	# First move in one direction, then turn 90 degrees to reach the destination
	# Stop if path encounters existing non-tunnel tiles
	var path: Array[Vector3i] = []

	var delta_x: int = end_coord.x - start_coord.x
	var delta_z: int = end_coord.z - start_coord.z

	# If start and end are the same, return empty path
	if delta_x == 0 and delta_z == 0:
		return path

	# Helper function to check if a position is blocked by existing non-tunnel tiles
	var is_position_blocked = func(coord: Vector3i) -> bool:
		var existing_tile = _get_tile_at_coord(coord)
		if existing_tile != null:
			var room = all_spawned_tiles.get(existing_tile, null)
			return room != null and room != tunnel_room # Blocked if it's a non-tunnel room tile
		return false

	# Choose which direction to go first (prioritize the larger distance)
	var first_direction_x: bool = abs(delta_x) >= abs(delta_z)

	# Current position for path building
	var current_x: int = start_coord.x
	var current_z: int = start_coord.z

	if first_direction_x:
		# First move horizontally (X direction) - include start position
		var x_step: int = sign(delta_x) if delta_x != 0 else 0
		while current_x != end_coord.x:
			var test_coord = Vector3i(current_x, floor_y, current_z)
			if is_position_blocked.call(test_coord):
				return path # Return partial path without the blocked position
			path.append(test_coord)
			current_x += x_step

		# Then move vertically (Z direction) from current position to end
		var z_step: int = sign(delta_z) if delta_z != 0 else 0
		while current_z != end_coord.z:
			var test_coord = Vector3i(current_x, floor_y, current_z)
			if is_position_blocked.call(test_coord):
				return path # Return partial path without the blocked position
			path.append(test_coord)
			current_z += z_step
	else:
		# First move vertically (Z direction) - include start position
		var z_step: int = sign(delta_z) if delta_z != 0 else 0
		while current_z != end_coord.z:
			var test_coord = Vector3i(current_x, floor_y, current_z)
			if is_position_blocked.call(test_coord):
				return path # Return partial path without the blocked position
			path.append(test_coord)
			current_z += z_step

		# Then move horizontally (X direction) from current position to end
		var x_step: int = sign(delta_x) if delta_x != 0 else 0
		while current_x != end_coord.x:
			var test_coord = Vector3i(current_x, floor_y, current_z)
			if is_position_blocked.call(test_coord):
				return path # Return partial path without the blocked position
			path.append(test_coord)
			current_x += x_step

	# Add the final end position (if not blocked)
	var end_test_coord = Vector3i(end_coord.x, floor_y, end_coord.z)
	if not is_position_blocked.call(end_test_coord):
		path.append(end_test_coord)

	return path


func _get_dead_end_tiles_with_open_direction() -> Array[Dictionary]:
	# Найти все тайлы с 3 стенами (тупики) и определить открытое направление
	# ТОЛЬКО для тайлов с полом (floor tiles)
	var dead_end_tiles: Array[Dictionary] = []

	for tile in all_spawned_tiles.keys():
		# КРИТИЧНО: Фильтровать только тайлы с полом
		# У верхних тайлов комнат нет floor, поэтому они автоматически отфильтруются
		if tile.floor == null or tile.floor.is_queued_for_deletion():
			continue
		
		# Проверить, сколько стен у тайла активно
		var active_walls: Array[String] = []
		if tile.wall_f != null and not tile.wall_f.is_queued_for_deletion():
			active_walls.append("forward")
		if tile.wall_r != null and not tile.wall_r.is_queued_for_deletion():
			active_walls.append("right")
		if tile.wall_b != null and not tile.wall_b.is_queued_for_deletion():
			active_walls.append("back")
		if tile.wall_l != null and not tile.wall_l.is_queued_for_deletion():
			active_walls.append("left")

		# Если ровно 3 стены - это тупик
		if active_walls.size() == 3:
			# Определить открытое направление (единственная стена, которая отсутствует)
			var open_direction: String = ""
			var possible_directions = ["forward", "right", "back", "left"]
			for direction in possible_directions:
				if not active_walls.has(direction):
					open_direction = direction
					break

			if open_direction != "":
				dead_end_tiles.append({
					"tile": tile,
					"open_direction": open_direction
				})

	return dead_end_tiles

func _spawn_blocked_doors_on_open_edges(valid_floor_ys: Array[int]):
	# Финальный проход по всем тайлам - спавн заблокированных дверей на краях открытых в пустоту направлений
	var blocked_door_prefab = load("res://assets/prefabs/environment/dungeon_doors/door_blocked_multistory_building.tscn")
	if blocked_door_prefab == null:
		print("ERROR: Could not load blocked door prefab")
		return

	var doors_spawned = 0

	for tile in all_spawned_tiles.keys():
		# Проверить, что тайл находится на валидном уровне этажа
		if not valid_floor_ys.has(tile.coord.y):
			continue

		# Определить открытые направления (где нет стен)
		var open_directions: Array[String] = []
		if tile.wall_f == null or tile.wall_f.is_queued_for_deletion():
			open_directions.append("forward")
		if tile.wall_r == null or tile.wall_r.is_queued_for_deletion():
			open_directions.append("right")
		if tile.wall_b == null or tile.wall_b.is_queued_for_deletion():
			open_directions.append("back")
		if tile.wall_l == null or tile.wall_l.is_queued_for_deletion():
			open_directions.append("left")

		# Для каждого открытого направления проверить, есть ли соседний тайл
		for direction in open_directions:
			var neighbor_offset: Vector3i = Vector3i(0, 0, 0)
			match direction:
				"forward":
					neighbor_offset = Vector3i(0, 0, -1)
				"right":
					neighbor_offset = Vector3i(1, 0, 0)
				"back":
					neighbor_offset = Vector3i(0, 0, 1)
				"left":
					neighbor_offset = Vector3i(-1, 0, 0)

			var neighbor_coord = tile.coord + neighbor_offset
			var neighbor_tile = _get_tile_at_coord(neighbor_coord)

			# Если соседа нет - спавнить заблокированную дверь
			if neighbor_tile == null:
				# Проверить, что у тайла есть пол
				if tile.floor == null or tile.floor.is_queued_for_deletion():
					continue

				# Создать заблокированную дверь
				var blocked_door = blocked_door_prefab.instantiate()
				if blocked_door == null:
					continue

				# Определить позицию двери на краю тайла
				var door_position: Vector3 = tile.position
				var door_rotation_y: float = 0.0

				# Сместить позицию в зависимости от направления (на край тайла)
				match direction:
					"forward": # Z-
						door_position.z -= TILE_SIZE.z / 2.0 # -2.0
						door_rotation_y = 0.0
					"right": # X+
						door_position.x += TILE_SIZE.x / 2.0 # +2.0
						door_rotation_y = deg_to_rad(90)
					"back": # Z+
						door_position.z += TILE_SIZE.z / 2.0 # +2.0
						door_rotation_y = deg_to_rad(180)
					"left": # X-
						door_position.x -= TILE_SIZE.x / 2.0 # -2.0
						door_rotation_y = deg_to_rad(-90)

				blocked_door.rotation.y = door_rotation_y
				blocked_door.position = door_position

				var door_name = "BlockedDoor_%s_%d_%d_%d" % [direction, tile.coord.x, tile.coord.y, tile.coord.z]
				blocked_door.name = door_name

				dungeon_tiles.add_child(blocked_door)
				blocked_door.owner = _get_edited_scene_root()

				doors_spawned += 1

	print("Spawned ", doors_spawned, " blocked doors on open edges")

func _get_rooms_on_floor(floor_y: int) -> Array[ResourceDungeonRoom]:
	# Получить все комнаты на данном этаже
	if not apartment_rooms_by_floor.has(floor_y):
		return []
	return apartment_rooms_by_floor[floor_y].duplicate()

func spawn_stairs_between_floors():
	# Спавн лестниц между этажами
	# Лестницы размещаются на каждом этаже (кроме последнего) и соединяют его со следующим этажом
	if floors_heights.is_empty():
		return

	# DEBUG: Вывести все двери
	print("DEBUG: spawn_stairs_between_floors: Total doors: ", spawned_doors_coords_new.size())
	for door_key in spawned_doors_coords_new.keys():
		var coords_str = door_key.split("-")
		if coords_str.size() == 2:
			var coord1_parts = coords_str[0].split("_")
			var coord2_parts = coords_str[1].split("_")
			if coord1_parts.size() == 3 and coord2_parts.size() == 3:
				var door_coord1 = Vector3i(int(coord1_parts[0]), int(coord1_parts[1]), int(coord1_parts[2]))
				var door_coord2 = Vector3i(int(coord2_parts[0]), int(coord2_parts[1]), int(coord2_parts[2]))
				print("DEBUG: Door: ", door_key, " -> ", door_coord1, "-", door_coord2)

	# Вычислить накопительные высоты этажей (как в generate_dungeon)
	var floor_y_positions: Array[int] = []
	var current_y: int = 0
	for floor_height in floors_heights:
		floor_y_positions.append(current_y)
		current_y += floor_height

	var floors_count: int = floors_heights.size()

	# Пройтись по всем этажам кроме последнего
	for floor_num in range(floors_count - 1):
		var floor_y: int = floor_y_positions[floor_num]
		var floor_height: int = floors_heights[floor_num]
		var next_floor_height: int = floors_heights[floor_num + 1]

		# Получить комнаты на этом этаже
		var rooms_on_floor: Array[ResourceDungeonRoom] = _get_rooms_on_floor(floor_y)
		if rooms_on_floor.is_empty():
			continue

		# Получить тайлы по комнатам на этом этаже
		var tiles_by_room: Dictionary[ResourceDungeonRoom, Array] = {}
		for tile in all_spawned_tiles.keys():
			if tile.coord.y != floor_y:
				continue
			var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
			if room == null or not rooms_on_floor.has(room):
				continue
			if not tiles_by_room.has(room):
				tiles_by_room[room] = []
			tiles_by_room[room].append(tile)

		# Sort tiles in each room to ensure deterministic order
		for room in tiles_by_room:
			tiles_by_room[room].sort_custom(_sort_tiles_by_coord)

		# Фильтровать комнаты с тайлами
		var rooms_with_tiles: Array[ResourceDungeonRoom] = []
		for room in rooms_on_floor:
			if tiles_by_room.has(room) and tiles_by_room[room].size() > 0:
				rooms_with_tiles.append(room)

		if rooms_with_tiles.is_empty():
			continue

		# Определить количество лестниц для этого этажа
		var target_stairs_count: int = rng.randi_range(min_stairs_per_floor, max_stairs_per_floor)
		target_stairs_count = min(target_stairs_count, rooms_with_tiles.size()) # Не больше количества комнат
		
		print("DEBUG: Floor ", floor_y, " target_stairs_count: ", target_stairs_count, " rooms_with_tiles: ", rooms_with_tiles.size())

		# Выбрать комнаты для размещения лестниц (на максимальном расстоянии друг от друга)
		var selected_rooms: Array[ResourceDungeonRoom] = []
		var available_rooms: Array[ResourceDungeonRoom] = rooms_with_tiles.duplicate()
		_shuffle_array(available_rooms)

		# Выбрать первые target_stairs_count комнат
		for i in range(min(target_stairs_count, available_rooms.size())):
			selected_rooms.append(available_rooms[i])

		# Разместить лестницы в выбранных комнатах
		print("DEBUG: Spawning stairs for floor_y=", floor_y, ", total doors on this floor: ", _count_doors_on_floor(floor_y))
		for room in selected_rooms:
			var room_tiles = tiles_by_room[room]
			print("DEBUG: Room has ", room_tiles.size(), " tiles")

			# Найти подходящий тайл в комнате (не занятый другими объектами и не рядом с дверями)
			var suitable_tiles: Array[DungeonTile] = []
			for tile in room_tiles:
				if not spawned_stairs_coords.has(tile.coord):
					var is_near_door = _is_coord_near_door(tile.coord, floor_y)
					if not is_near_door:
						suitable_tiles.append(tile)
					else:
						print("DEBUG: Tile at ", tile.coord, " is near door, skipping")
				else:
					print("DEBUG: Tile at ", tile.coord, " already has stairs, skipping")

			if suitable_tiles.is_empty():
				print("DEBUG: No suitable tiles found in room, skipping")
				continue

			# Выбрать случайный подходящий тайл
			var selected_tile: DungeonTile = suitable_tiles[rng.randi() % suitable_tiles.size()]
			print("DEBUG: Selected tile for stairs: ", selected_tile.coord, " (floor_y=", floor_y, ")")
			
			# Дополнительная проверка перед спавном
			if _is_coord_near_door(selected_tile.coord, floor_y):
				print("ERROR: Selected tile ", selected_tile.coord, " is near door! Skipping spawn.")
				continue

			# Спавнить лестницу
			await _spawn_stairs_at_coord(selected_tile.coord, floor_height)
			await _await_frame()

func _count_doors_on_floor(floor_y: int) -> int:
	# Подсчитать количество дверей на этаже
	var count = 0
	for door_key in spawned_doors_coords_new.keys():
		var coords_str = door_key.split("-")
		if coords_str.size() != 2:
			continue
		
		var coord1_parts = coords_str[0].split("_")
		if coord1_parts.size() != 3:
			continue
		
		var door_coord1_y = int(coord1_parts[1])
		if door_coord1_y == floor_y or door_coord1_y == floor_y + 1:
			count += 1
	return count

func _is_coord_near_door(coord: Vector3i, floor_y: int) -> bool:
	# Проверить, находится ли координата рядом с дверью на том же этаже
	# Дверь находится между двумя тайлами, поэтому проверяем оба тайла и их соседей
	for door_key in spawned_doors_coords_new.keys():
		# Распарсить координаты двери из ключа формата "x1_y1_z1-x2_y2_z2"
		var coords_str = door_key.split("-")
		if coords_str.size() != 2:
			continue
		
		var coord1_parts = coords_str[0].split("_")
		var coord2_parts = coords_str[1].split("_")
		
		if coord1_parts.size() != 3 or coord2_parts.size() != 3:
			continue
		
		var door_coord1 = Vector3i(int(coord1_parts[0]), int(coord1_parts[1]), int(coord1_parts[2]))
		var door_coord2 = Vector3i(int(coord2_parts[0]), int(coord2_parts[1]), int(coord2_parts[2]))
		
		# Проверить, что дверь на том же этаже (или на этаже выше/ниже, так как двери 2 тайла высотой)
		if door_coord1.y != floor_y and door_coord1.y != floor_y + 1:
			continue
		
		# Проверить, находится ли coord рядом с любым из тайлов двери
		# Проверяем сам тайл и соседние тайлы в горизонтальной плоскости
		var check_coords = [
			door_coord1,
			door_coord2,
			door_coord1 + Vector3i(1, 0, 0), # Сосед справа
			door_coord1 + Vector3i(-1, 0, 0), # Сосед слева
			door_coord1 + Vector3i(0, 0, 1), # Сосед сзади
			door_coord1 + Vector3i(0, 0, -1), # Сосед спереди
			door_coord2 + Vector3i(1, 0, 0),
			door_coord2 + Vector3i(-1, 0, 0),
			door_coord2 + Vector3i(0, 0, 1),
			door_coord2 + Vector3i(0, 0, -1)
		]
		
		for check_coord in check_coords:
			# Проверяем только координаты на том же этаже
			if check_coord.y == floor_y and check_coord == coord:
				print("DEBUG: _is_coord_near_door: coord ", coord, " matches door at ", door_coord1, "-", door_coord2, " (check_coord=", check_coord, ")")
				return true
	
	return false

func _spawn_stairs_at_coord(coord: Vector3i, floor_height: int):
	# Спавнить лестницу на заданной координате
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	print("DEBUG: Spawning stairs at ", coord, " (client? ", not multiplayer.is_server(), ")")

	var stairs_tile: StairsTile = STAIRS_1.instantiate()
	stairs_tile.position = world_position
	stairs_tile.name = "Stairs_%d_%d_%d" % [coord.x, coord.y, coord.z]
	stairs_tile.tunnel_requested.connect(_on_stairs_tunnel_requested)

	dungeon_tiles.add_child(stairs_tile)
	stairs_tile.owner = _get_edited_scene_root()

	# Конфигурировать высоту лестницы
	await stairs_tile.configure_stairs_height(floor_height, rng)

	# Записать в словарь спавненных лестниц
	spawned_stairs_coords[coord] = stairs_tile


const STAIRS_TUNNEL_TYPE_HORIZONTAL := "horizontal"


func _on_stairs_tunnel_requested(_stairs_tile: StairsTile, origin_global: Vector3, target_global: Vector3, tunnel_type: String):
	var start_coord: Vector3i = _world_to_tile_coord(origin_global)
	var end_coord: Vector3i = _world_to_tile_coord(target_global)
	var original_end_coord: Vector3i = end_coord
	
	if start_coord == end_coord:
		return
	
	var allow_diagonal := tunnel_type != STAIRS_TUNNEL_TYPE_HORIZONTAL
	var base_path_coords: Array[Vector3i] = _create_stairs_tunnel_path(start_coord, end_coord, allow_diagonal)
	if base_path_coords.is_empty():
		return
	
	var combined_path_coords: Array[Vector3i] = base_path_coords.duplicate()
	var pending_doors: Array = []
	var existing_room_connection_created := false
	
	# Find the correct floor Y for the end coordinate
	# The target_global position is on the upper floor, we need to find which floor that is
	var target_floor_y = end_coord.y
	
	# Calculate actual floor Y positions from floors_heights (cumulative heights)
	var floor_y_positions: Array[int] = []
	var current_y: int = 0
	for floor_height in floors_heights:
		floor_y_positions.append(current_y)
		current_y += floor_height
	
	# Find the closest floor that matches or is below end_coord.y
	for i in range(floor_y_positions.size() - 1, -1, -1): # Iterate backwards
		if floor_y_positions[i] <= end_coord.y:
			target_floor_y = floor_y_positions[i]
			break
	
	# Update end_coord to use the correct floor Y
	end_coord.y = target_floor_y

	var end_tile: DungeonTile = _get_tile_at_coord(end_coord)
	var end_tile_room = all_spawned_tiles.get(end_tile, null) if end_tile else null

	if tunnel_type == STAIRS_TUNNEL_TYPE_HORIZONTAL:
		var room_tile_at_target: DungeonTile = _get_tile_at_coord(original_end_coord)
		var room_at_target = all_spawned_tiles.get(room_tile_at_target, null) if room_tile_at_target else null
		if room_tile_at_target != null and room_at_target != tunnel_room:
			var connecting_coord = _get_last_coord_before_target(base_path_coords, original_end_coord)
			if connecting_coord != null:
				var offset = room_tile_at_target.coord - connecting_coord
				if (abs(offset.x) + abs(offset.y) + abs(offset.z)) == 1:
					pending_doors.append({
						"room_tile": room_tile_at_target,
						"tunnel_coord": connecting_coord
					})
					existing_room_connection_created = true

		var nearest_room_tile: DungeonTile = _find_nearest_room_tile_on_floor(end_coord, end_coord.y)
		if nearest_room_tile != null:
			var top_adjacent_coord: Vector3i = _find_best_adjacent_position(nearest_room_tile.coord, end_coord, nearest_room_tile.coord.y, [])
			if top_adjacent_coord != nearest_room_tile.coord:
				# Use orthogonal path for horizontal connection to ensure walkability (90 degree turns)
				var connection_path: Array[Vector3i] = _create_orthogonal_path(end_coord, top_adjacent_coord, end_coord.y)
				
				if connection_path.is_empty():
					# Fallback if path generation fails (shouldn't happen often with orthogonal path unless blocked)
					combined_path_coords.append(top_adjacent_coord)
				else:
					for coord in connection_path:
						combined_path_coords.append(coord)
				
	
				pending_doors.append({
				"room_tile": nearest_room_tile,
				"tunnel_coord": top_adjacent_coord
			})


	var tunnel_coords: Array[Vector3i] = []
	var seen: Dictionary = {}
	var base_with_support = _expand_path_with_vertical_support(base_path_coords)
	for coord in base_with_support:
		_append_unique_coord(tunnel_coords, seen, coord)
	for coord in combined_path_coords:
		_append_unique_coord(tunnel_coords, seen, coord)
	if tunnel_coords.is_empty():
		return
	
	var created_tiles: Array[DungeonTile] = []
	for coord in tunnel_coords:
		var tile_info = _ensure_tunnel_tile_at_coord(coord)
		var tunnel_tile: DungeonTile = tile_info.get("tile", null)
		if tunnel_tile == null:
			continue
		if tile_info.get("created", false):
			created_tiles.append(tunnel_tile)
	
	for tile in created_tiles:
		var neighbors = _get_neighbor_tiles(tile)
		tile.configure_tile_based_on_neighbours(neighbors)
	
	for door_request in pending_doors:
		var room_tile: DungeonTile = door_request.get("room_tile", null)
		var tunnel_coord: Vector3i = door_request.get("tunnel_coord", Vector3i.ZERO)
		if room_tile == null:
			continue
		var tunnel_tile = _get_tile_at_coord(tunnel_coord)
		if tunnel_tile == null:
			continue
		var offset = tunnel_tile.coord - room_tile.coord
		if (abs(offset.x) + abs(offset.y) + abs(offset.z)) != 1:
			continue
		await _spawn_door_between_tiles(room_tile, tunnel_tile, offset, room_tile.coord.y)


func _find_nearest_room_tile_on_floor(target_coord: Vector3i, floor_y: int) -> DungeonTile:
	var closest_tile: DungeonTile = null
	var min_distance: float = INF
	for tile in all_spawned_tiles.keys():
		if tile.coord.y != floor_y:
			continue
		var room = all_spawned_tiles.get(tile, null)
		if room == null or room == tunnel_room:
			continue
		var distance = (tile.coord - target_coord).length()
		if distance < min_distance:
			min_distance = distance
			closest_tile = tile
	return closest_tile


func _create_stairs_tunnel_path(start_coord: Vector3i, end_coord: Vector3i, allow_diagonal: bool = true) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	if not allow_diagonal:
		return _create_manhattan_path(start_coord, end_coord)
	
	var delta: Vector3i = end_coord - start_coord
	var steps: int = max(abs(delta.x), abs(delta.y), abs(delta.z))
	if steps == 0:
		return coords
	
	var last_coord: Vector3i = start_coord
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var sample := Vector3(
			start_coord.x + delta.x * t,
			start_coord.y + delta.y * t,
			start_coord.z + delta.z * t
		)
		var grid_coord := Vector3i(
			int(round(sample.x)),
			int(round(sample.y)),
			int(round(sample.z))
		)
		
		if grid_coord == last_coord:
			continue
		
		if coords.is_empty() or coords.back() != grid_coord:
			coords.append(grid_coord)
			last_coord = grid_coord
	
	return coords


func _create_manhattan_path(start_coord: Vector3i, end_coord: Vector3i) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	var current: Vector3i = start_coord
	while current != end_coord:
		if current.x != end_coord.x:
			current.x += _step_towards(current.x, end_coord.x)
		elif current.z != end_coord.z:
			current.z += _step_towards(current.z, end_coord.z)
		elif current.y != end_coord.y:
			current.y += _step_towards(current.y, end_coord.y)
		
		if coords.is_empty() or coords.back() != current:
			coords.append(current)
	
	return coords


func _step_towards(current: int, target: int) -> int:
	if target > current:
		return 1
	elif target < current:
		return -1
	return 0


func _ensure_tunnel_tile_at_coord(coord: Vector3i) -> Dictionary:
	var existing_tile = _get_tile_at_coord(coord)
	if existing_tile != null:
		return {"tile": existing_tile, "created": false}
	
	var world_position := Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	var tunnel_tile: DungeonTile = DUNGEON_TILE.instantiate()
	tunnel_tile.position = world_position
	tunnel_tile.coord = coord
	tunnel_tile.master_dungeon = self
	dungeon_tiles.add_child(tunnel_tile)
	tunnel_tile.owner = _get_edited_scene_root()
	
	all_spawned_tiles[tunnel_tile] = tunnel_room
	room_assignment[tunnel_tile] = tunnel_room
	
	return {"tile": tunnel_tile, "created": true}


func _world_to_tile_coord(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		int(round(world_pos.x / float(TILE_SIZE.x))),
		int(round(world_pos.y / float(TILE_SIZE.y))),
		int(round(world_pos.z / float(TILE_SIZE.z)))
	)


func _expand_path_with_vertical_support(base_path: Array[Vector3i]) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	var seen: Dictionary = {}
	for coord in base_path:
		_append_unique_coord(coords, seen, coord)
		for depth in range(1, 3):
			var support_coord = coord + Vector3i(0, -depth, 0)
			_append_unique_coord(coords, seen, support_coord)
	return coords


func _append_unique_coord(coords: Array[Vector3i], seen: Dictionary, coord: Vector3i) -> void:
	var key = "%d_%d_%d" % [coord.x, coord.y, coord.z]
	if seen.has(key):
		return
	seen[key] = true
	coords.append(coord)


func _get_last_coord_before_target(path: Array[Vector3i], target_coord: Vector3i):
	if path.is_empty():
		return null
	for i in range(path.size() - 1, -1, -1):
		var coord: Vector3i = path[i]
		if coord != target_coord:
			return coord
	return null


func _get_neighbor_offset_for_direction(direction: String) -> Vector3i:
	# Получить смещение соседа для заданного направления
	match direction:
		"forward":
			return Vector3i(0, 0, -1)
		"right":
			return Vector3i(1, 0, 0)
		"back":
			return Vector3i(0, 0, 1)
		"left":
			return Vector3i(-1, 0, 0)
	return Vector3i.ZERO


func _remove_wall_in_direction(tile: DungeonTile, direction: String):
	# Удалить стену тайла в заданном направлении
	match direction:
		"forward":
			if tile.wall_f != null and not tile.wall_f.is_queued_for_deletion():
				tile.wall_f.queue_free()
				tile.wall_f = null
		"right":
			if tile.wall_r != null and not tile.wall_r.is_queued_for_deletion():
				tile.wall_r.queue_free()
				tile.wall_r = null
		"back":
			if tile.wall_b != null and not tile.wall_b.is_queued_for_deletion():
				tile.wall_b.queue_free()
				tile.wall_b = null
		"left":
			if tile.wall_l != null and not tile.wall_l.is_queued_for_deletion():
				tile.wall_l.queue_free()
				tile.wall_l = null


func _check_door_exists(tile1: DungeonTile, tile2: DungeonTile) -> bool:
	# Проверить, существует ли уже дверь между двумя тайлами
	var door_key1 = "%d_%d_%d-%d_%d_%d" % [tile1.coord.x, tile1.coord.y, tile1.coord.z, tile2.coord.x, tile2.coord.y, tile2.coord.z]
	var door_key2 = "%d_%d_%d-%d_%d_%d" % [tile2.coord.x, tile2.coord.y, tile2.coord.z, tile1.coord.x, tile1.coord.y, tile1.coord.z]
	return spawned_doors_coords_new.has(door_key1) or spawned_doors_coords_new.has(door_key2)


func _connect_dead_end_tiles_with_doors(valid_floor_ys: Array[int]):
	var dead_end_tiles = _get_dead_end_tiles_with_open_direction()
	print("DEBUG: Found ", dead_end_tiles.size(), " dead-end tiles with floors")
	
	var doors_created = 0
	var doors_skipped = 0
	
	for dead_end in dead_end_tiles:
		var tile: DungeonTile = dead_end["tile"]
		var open_direction: String = dead_end["open_direction"]
		
		print("DEBUG: Processing dead-end tile at ", tile.coord, " with open_direction=", open_direction)
		
		# Проверить, что тайл находится на валидном уровне этажа
		if not valid_floor_ys.has(tile.coord.y):
			doors_skipped += 1
			print("  SKIPPED: not on valid floor_y")
			continue
		
		# Проверить, что у тайла есть пол
		if tile.floor == null or tile.floor.is_queued_for_deletion():
			doors_skipped += 1
			print("  SKIPPED: no floor")
			continue
		
		# Построить список направлений для попытки, начиная с открытого направления
		var directions_to_try: Array[String] = [open_direction]
		var all_directions = ["forward", "right", "back", "left"]
		for dir in all_directions:
			if dir != open_direction:
				directions_to_try.append(dir)
		
		# Попытаться найти подходящего соседа в любом из направлений
		var door_spawned = false
		var skip_reasons: Array[String] = []
		
		for direction in directions_to_try:
			var neighbor_offset = _get_neighbor_offset_for_direction(direction)
			var neighbor_coord = tile.coord + neighbor_offset
			var neighbor_tile = _get_tile_at_coord(neighbor_coord)
			
			print("  Trying direction: ", direction, " neighbor_coord=", neighbor_coord)
			
			# Пропустить, если соседа нет
			if neighbor_tile == null:
				skip_reasons.append("  %s: no neighbor tile" % direction)
				print("    -> No neighbor")
				continue
			
			# КРИТИЧНО: Проверить, что оба тайла на одном Y-уровне (горизонтальные соседи)
			if tile.coord.y != neighbor_tile.coord.y:
				skip_reasons.append("  %s: different Y-level (tile=%d, neighbor=%d)" % [direction, tile.coord.y, neighbor_tile.coord.y])
				print("    -> Different Y-level")
				continue
			
			# Удалить стены между тайлами (используем проверенную функцию)
			print("    -> Removing walls...")
			_remove_wall_between_tiles(tile, neighbor_tile, neighbor_offset)
			
			# Проверить, если дверь уже существует
			if _check_door_exists(tile, neighbor_tile):
				# Стены уже убрали, проход обеспечен
				print("    -> Door already exists, passage ensured")
				door_spawned = true
				break
			
			print("    -> Spawning door...")
			await _spawn_door_between_tiles(tile, neighbor_tile, neighbor_offset, tile.coord.y)
			doors_created += 1
			door_spawned = true
			break
		
		if not door_spawned:
			doors_skipped += 1
			print("DEBUG: Dead-end at ", tile.coord, " could not find valid neighbor:")
			for reason in skip_reasons:
				print(reason)
	
	print("DEBUG: Created ", doors_created, " doors for dead-end tiles, skipped ", doors_skipped)

func clear_stairs_on_tiles_with_no_floor():
	# луп по всем лестницам
	# если тайл на котором лестница не имеет пола - удали лестницу
	var stairs_to_remove: Array[Vector3i] = []
	
	for coord in spawned_stairs_coords.keys():
		# Получить тайл на этой координате
		var tile: DungeonTile = _get_tile_at_coord(coord)
		
		# Если тайл существует, проверить наличие пола
		if tile != null:
			# Если пола нет или он помечен на удаление - добавить в список для удаления
			if tile.floor == null or tile.floor.is_queued_for_deletion():
				stairs_to_remove.append(coord)
		else:
			# Если тайл не существует - тоже удалить лестницу
			stairs_to_remove.append(coord)
	
	# Удалить лестницы
	var removed_count = 0
	for coord in stairs_to_remove:
		var stairs_node = spawned_stairs_coords.get(coord, null)
		if stairs_node != null and is_instance_valid(stairs_node):
			stairs_node.queue_free()
			removed_count += 1
		spawned_stairs_coords.erase(coord)
	
	if removed_count > 0:
		print("Removed ", removed_count, " stairs on tiles with no floor")

func spawn_pickups():
	# Don't spawn pickups in editor
	if Engine.is_editor_hint():
		return
	
	# Ensure GameSpawner spawn_path is set to DungeonTiles
	if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
		var dungeon_tiles_node = GameManager._game_level.get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
		if dungeon_tiles_node != null:
			var dungeon_tiles_path = GameManager._game_spawner.get_path_to(dungeon_tiles_node)
			GameManager._game_spawner.spawn_path = dungeon_tiles_path
	
	# Build weighted item dictionary from item_spawns array
	if item_spawns.is_empty() or items_to_spawn_amount <= 0:
		return
	
	# Calculate total weight for weighted random selection
	var total_weight: float = 0.0
	for item_spawn in item_spawns:
		if item_spawn != null and item_spawn.item_resource != null:
			total_weight += item_spawn.spawn_weight
	
	if total_weight <= 0.0:
		push_warning("spawn_pickups: No valid items with positive weight in item_spawns")
		return
	
	# Determine spawn point (starting point for players) - use origin (0,0,0) as reference
	var spawn_point: Vector3 = Vector3(0, 0, 0)
	
	# Collect all tiles with floors (exclude stairs)
	var available_tiles: Array[DungeonTile] = []
	var dead_end_tiles: Array[DungeonTile] = []
	
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(tile.coord):
			continue
		
		available_tiles.append(tile)
		
		# Check if tile is a dead-end (3 walls, 1 opening)
		var wall_count: int = 0
		if tile.wall_f != null and not tile.wall_f.is_queued_for_deletion():
			wall_count += 1
		if tile.wall_r != null and not tile.wall_r.is_queued_for_deletion():
			wall_count += 1
		if tile.wall_b != null and not tile.wall_b.is_queued_for_deletion():
			wall_count += 1
		if tile.wall_l != null and not tile.wall_l.is_queued_for_deletion():
			wall_count += 1
		
		if wall_count == 3:
			dead_end_tiles.append(tile)
	
	if available_tiles.is_empty():
		push_warning("spawn_pickups: No available tiles found for spawning pickups")
		return
	
	print("spawn_pickups: Found ", available_tiles.size(), " available tiles, ", dead_end_tiles.size(), " dead-end tiles")
	
	# Shuffle dead-end tiles using seeded RNG
	_shuffle_array(dead_end_tiles)
	
	# Track spawned pickup positions for Farthest Point Sampling
	var spawned_positions: Array[Vector3] = []
	var items_remaining: int = items_to_spawn_amount
	var total_pickups_spawned: int = 0
	
	# Phase 1: Spawn items in dead-ends (with 20% skip chance)
	for tile in dead_end_tiles:
		if items_remaining <= 0:
			break
		
		# 20% chance to skip this dead end
		if rng.randf() < 0.2:
			continue
		
		# Choose random weighted item
		var selected_item_spawn: ResourceItemSpawn = _choose_weighted_item_spawn(item_spawns, total_weight)
		if selected_item_spawn == null or selected_item_spawn.item_resource == null:
			continue
		
		# Check distance from spawn point (elevator/start area)
		var tile_distance = _get_tile_distance_from_spawn_point(tile, spawn_point)
		if tile_distance < selected_item_spawn.spawn_distance_from_elevator_min or tile_distance > selected_item_spawn.spawn_distance_from_elevator_max:
			continue # Skip this tile - doesn't meet distance requirements
		
		var weapon_resource = selected_item_spawn.item_resource
		
		# Check if weapon_resource has pickup_prefab_path
		if weapon_resource.pickup_prefab_path == null or weapon_resource.pickup_prefab_path == "":
			push_warning("spawn_pickups: Weapon resource '%s' has no pickup_prefab_path" % weapon_resource.weapon_name)
			continue
		
		# Randomize pickup position within tile bounds
		var random_offset_x: float = rng.randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = rng.randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var pickup_position = tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
		
		# Spawn pickup through MultiplayerSpawner for synchronization
		if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
			var spawn_data = {"type": "pickup", "path": str(weapon_resource.pickup_prefab_path)}
			var pickup = GameManager._game_spawner.spawn(spawn_data)
			if pickup != null:
				# Set weapon_resource on the pickup (InteractivePickup class)
				if pickup is InteractivePickup:
					pickup.weapon_resource = weapon_resource.duplicate()
				
				# MultiplayerSpawner adds to spawn_path automatically, but we need to set position
				pickup.position = pickup_position
				pickup.owner = _get_edited_scene_root()
				# Set multiplayer authority to server
				pickup.set_multiplayer_authority(1)
				
				spawned_positions.append(pickup_position)
				items_remaining -= 1
				total_pickups_spawned += 1
		
		# Yield every 10 pickups to avoid frame drops
		if total_pickups_spawned % 10 == 0:
			await _await_frame()
	
	print("spawn_pickups: Spawned ", total_pickups_spawned, " items in dead-ends, ", items_remaining, " items remaining")
	
	# Phase 2: Spawn remaining items using Farthest Point Sampling
	# This ensures items are well-distributed across the level
	while items_remaining > 0:
		var farthest_tile: DungeonTile = null
		var max_min_distance: float = 0.0
		
		# Choose random weighted item first to check distance requirements
		var selected_item_spawn: ResourceItemSpawn = _choose_weighted_item_spawn(item_spawns, total_weight)
		if selected_item_spawn == null or selected_item_spawn.item_resource == null:
			items_remaining -= 1
			continue
		
		# Find the tile with the maximum minimum distance to all spawned positions
		# that also meets distance requirements from spawn point
		for tile in available_tiles:
			if not is_instance_valid(tile):
				continue
			
			# Check distance from spawn point (elevator/start area)
			var tile_distance = _get_tile_distance_from_spawn_point(tile, spawn_point)
			if tile_distance < selected_item_spawn.spawn_distance_from_elevator_min or tile_distance > selected_item_spawn.spawn_distance_from_elevator_max:
				continue # Skip this tile - doesn't meet distance requirements
			
			var tile_center = tile.position
			var min_distance: float = INF
			
			# Calculate minimum distance to any spawned pickup
			if spawned_positions.is_empty():
				# First item - just pick this tile if it meets requirements
				farthest_tile = tile
				break
			else:
				for spawned_pos in spawned_positions:
					var distance = tile_center.distance_to(spawned_pos)
					if distance < min_distance:
						min_distance = distance
			
			# Update farthest tile if this is farther from all spawned pickups
			if min_distance > max_min_distance:
				max_min_distance = min_distance
				farthest_tile = tile
		
		if farthest_tile == null:
			# No suitable tile found for this item - skip it
			items_remaining -= 1
			continue
		
		var weapon_resource = selected_item_spawn.item_resource
		
		# Check if weapon_resource has pickup_prefab_path
		if weapon_resource.pickup_prefab_path == null or weapon_resource.pickup_prefab_path == "":
			push_warning("spawn_pickups: Weapon resource '%s' has no pickup_prefab_path" % weapon_resource.weapon_name)
			items_remaining -= 1
			continue
		
		# Randomize pickup position within tile bounds
		var random_offset_x: float = rng.randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = rng.randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var pickup_position = farthest_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
		
		# Spawn pickup through MultiplayerSpawner for synchronization
		if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
			var spawn_data = {"type": "pickup", "path": str(weapon_resource.pickup_prefab_path)}
			var pickup = GameManager._game_spawner.spawn(spawn_data)
			if pickup != null:
				# Set weapon_resource on the pickup (InteractivePickup class)
				if pickup is InteractivePickup:
					pickup.weapon_resource = weapon_resource.duplicate()
				
				# MultiplayerSpawner adds to spawn_path automatically, but we need to set position
				pickup.position = pickup_position
				pickup.owner = _get_edited_scene_root()
				# Set multiplayer authority to server
				pickup.set_multiplayer_authority(1)
				
				spawned_positions.append(pickup_position)
				items_remaining -= 1
				total_pickups_spawned += 1
		else:
			# If spawn failed, still decrement to avoid infinite loop
			items_remaining -= 1
		
		# Yield every 10 pickups to avoid frame drops
		if total_pickups_spawned % 10 == 0:
			await _await_frame()
	
	print("spawn_pickups: Total pickups spawned: ", total_pickups_spawned)

func _choose_weighted_item_spawn(items: Array[ResourceItemSpawn], total_weight: float) -> ResourceItemSpawn:
	# Weighted random selection for item spawns
	if items.is_empty() or total_weight <= 0.0:
		return null
	
	# Choose random value
	var random_value: float = rng.randf() * total_weight
	var current_weight: float = 0.0
	
	# Find which item corresponds to the random value
	for item_spawn in items:
		if item_spawn == null or item_spawn.item_resource == null:
			continue
		current_weight += item_spawn.spawn_weight
		if random_value <= current_weight:
			return item_spawn
	
	# Fallback: return first valid item
	for item_spawn in items:
		if item_spawn != null and item_spawn.item_resource != null:
			return item_spawn
	
	return null

func spawn_mobs():
	# Don't spawn mobs in editor
	if Engine.is_editor_hint():
		return
	
	# Use mobs_amount_to_spawn to spawn mobs in random tiles with floor (except first floor)
	# Spawn on all peers using seeded RNG for consistency (same as dungeon generation and pickups)
	if mobs_amount_to_spawn <= 0:
		return
	
	# Get game_level (NavigationRegion3D) as parent for mobs so they can use navigation
	var game_level = get_parent()
	if not is_instance_valid(game_level):
		push_warning("spawn_mobs: Could not find game_level parent")
		return
	
	# Collect tiles with floors from all floors except the first (floor_y = 0)
	var available_tiles: Array[DungeonTile] = []
	
	# Determine the first floor Y value (should be 0, but let's get it from floors_heights)
	var first_floor_y: int = 0
	
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles on first floor (Y = 0)
		if tile.coord.y == first_floor_y:
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(tile.coord):
			continue
		available_tiles.append(tile)
	
	if available_tiles.is_empty():
		push_warning("spawn_mobs: No available tiles found for spawning mobs")
		return
	
	print("spawn_mobs: Found ", available_tiles.size(), " available tiles for mob spawning")
	
	# Spawn mobs
	var mobs_to_spawn: int = min(mobs_amount_to_spawn, available_tiles.size())
	for i in range(mobs_to_spawn):
		# Choose a random tile using seeded RNG (ensures same selection on all clients)
		var random_tile: DungeonTile = available_tiles[rng.randi() % available_tiles.size()]
		
		# Randomize mob position within tile bounds using seeded RNG
		var random_offset_x: float = rng.randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = rng.randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var mob_position = random_tile.position + Vector3(random_offset_x, 1.0, random_offset_z) # 1 unit above floor
		
		# Give mob a unique, consistent name based on spawn order and tile coordinate
		# This ensures RPCs can find the correct mob on all peers
		var mob_name = "Mob_%d_%d_%d_%d" % [
			random_tile.coord.x,
			random_tile.coord.y,
			random_tile.coord.z,
			i
		]
		
		# Spawn mob through MultiplayerSpawner for proper synchronization
		# Only spawn on server - MultiplayerSpawner will replicate to all clients
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			if is_instance_valid(GameManager):
				GameManager.spawn_mob(mob_name, mob_position, mob_position)
		elif not multiplayer.has_multiplayer_peer():
			# Single player - spawn directly
			var mob = AI_CHARACTER.instantiate()
			if mob != null:
				mob.name = mob_name
				mob.position = mob_position
				if mob is AiCharacter:
					mob.home_position = mob_position
				game_level.add_child(mob)
				mob.owner = _get_edited_scene_root()
		
		# Yield every 10 mobs to avoid frame drops
		if i % 10 == 0:
			await _await_frame()
	
	print("spawn_mobs: Total mobs spawned: ", mobs_to_spawn)

func _get_tile_distance_from_spawn_point(tile: DungeonTile, spawn_point: Vector3) -> float:
	# Calculate horizontal distance (ignoring Y) from tile to spawn point in tile units
	# This approximates the distance players would walk
	var tile_pos_2d = Vector2(tile.position.x, tile.position.z)
	var spawn_pos_2d = Vector2(spawn_point.x, spawn_point.z)
	var distance_world = tile_pos_2d.distance_to(spawn_pos_2d)
	# Convert to tile units (TILE_SIZE.x = 4)
	var distance_tiles = distance_world / TILE_SIZE.x
	return distance_tiles

func spawn_props():
	# Spawn props to random tiles with floor using global props_by_weight dictionary
	# This is similar to procedural_dungeon implementation, but uses a single global dictionary
	# Don't spawn props in editor
	if Engine.is_editor_hint():
		return
	
	# Ensure GameSpawner spawn_path is set to DungeonTiles
	if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
		var dungeon_tiles_node = GameManager._game_level.get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
		if dungeon_tiles_node != null:
			var dungeon_tiles_path = GameManager._game_spawner.get_path_to(dungeon_tiles_node)
			GameManager._game_spawner.spawn_path = dungeon_tiles_path
	
	# Check if we have props to spawn
	if props_by_weight.is_empty() or props_amount_to_spawn <= 0:
		return
	
	# Get all tiles with floors (excluding tiles with stairs)
	var tiles_with_floors: Array[DungeonTile] = []
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(tile.coord):
			continue
		tiles_with_floors.append(tile)
	
	# Sort tiles to ensure deterministic order before random selection
	tiles_with_floors.sort_custom(_sort_tiles_by_coord)
	
	if tiles_with_floors.is_empty():
		print("spawn_props: No tiles with floors found")
		return
	
	print("spawn_props: Found ", tiles_with_floors.size(), " tiles with floors, spawning ", props_amount_to_spawn, " props")
	
	# Spawn props using props_amount_to_spawn
	var props_to_spawn: int = min(props_amount_to_spawn, tiles_with_floors.size() * 10) # Allow multiple props per tile
	
	for i in range(props_to_spawn):
		# Choose a random tile with floor (multiple props can occupy same tile)
		var random_tile: DungeonTile = tiles_with_floors[rng.randi() % tiles_with_floors.size()]
		
		# Choose prop using weighted random selection
		var prop_path: StringName = _choose_weighted_prop(props_by_weight)
		if prop_path.is_empty():
			continue
		
		# Randomize prop position within tile bounds
		# TILE_SIZE is Vector3i(4, 2, 4) and tile's origin is at its bottom center
		# So we randomize X and Z in range [-TILE_SIZE.x/2, TILE_SIZE.x/2] = [-2, 2]
		# And Y is slightly above floor (0.1 to account for floor height)
		var random_offset_x: float = rng.randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = rng.randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var prop_position = random_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
		
		# Spawn prop through MultiplayerSpawner for synchronization
		if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
			var spawn_data = {"type": "prop", "path": str(prop_path)}
			var prop = GameManager._game_spawner.spawn(spawn_data)
			if prop != null:
				# MultiplayerSpawner adds to spawn_path automatically, but we need to set position
				prop.position = prop_position
				prop.owner = _get_edited_scene_root()
				# Set multiplayer authority to server
				prop.set_multiplayer_authority(1)
		
		# Yield every 10 props to avoid frame drops
		if i % 10 == 0:
			await _await_frame()
	
	print("spawn_props: Total props spawned: ", props_to_spawn)

func _choose_weighted_prop(props_dict: Dictionary[StringName, float]) -> StringName:
	# Weighted random selection from props dictionary
	if props_dict.is_empty():
		return StringName()
	
	# Calculate total weight
	var total_weight: float = 0.0
	for weight in props_dict.values():
		total_weight += weight
	
	if total_weight <= 0.0:
		return StringName()
	
	# Choose random value
	var random_value: float = rng.randf() * total_weight
	var current_weight: float = 0.0
	
	# Find which prop corresponds to the random value
	for prop_path in props_dict.keys():
		current_weight += props_dict[prop_path]
		if random_value <= current_weight:
			return prop_path
	
	# Fallback: return first prop
	return props_dict.keys()[0] if props_dict.size() > 0 else StringName()

func spawn_wall_torches():
	# Don't spawn torches in editor
	if Engine.is_editor_hint():
		return
	
	# Ensure GameSpawner spawn_path is set to DungeonTiles
	if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
		var dungeon_tiles_node = GameManager._game_level.get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
		if dungeon_tiles_node != null:
			var dungeon_tiles_path = GameManager._game_spawner.get_path_to(dungeon_tiles_node)
			GameManager._game_spawner.spawn_path = dungeon_tiles_path
	
	# Check if we have torches to spawn
	if torches_on_walls_amount <= 0:
		return
	
	# Gather all tiles with floors (excluding tiles with stairs)
	var tiles_with_floors: Array[DungeonTile] = []
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(tile.coord):
			continue
		tiles_with_floors.append(tile)
	
	# Sort tiles to ensure deterministic order before shuffling
	tiles_with_floors.sort_custom(_sort_tiles_by_coord)
	
	if tiles_with_floors.is_empty():
		print("spawn_wall_torches: No tiles with floors found")
		return
	
	print("spawn_wall_torches: Found ", tiles_with_floors.size(), " tiles with floors, spawning up to ", torches_on_walls_amount, " torches")
	
	# Shuffle tiles using seeded RNG for deterministic generation
	_shuffle_array(tiles_with_floors)
	
	# Spawn torches on random tiles (one torch per tile at max)
	var torches_to_spawn: int = min(torches_on_walls_amount, tiles_with_floors.size())
	var torches_spawned: int = 0
	
	for i in range(torches_to_spawn):
		var tile: DungeonTile = tiles_with_floors[i]
		
		# Call spawn_wall_torch on the tile
		tile.spawn_wall_torch()
		torches_spawned += 1
		
		# Yield every 10 torches to avoid frame drops
		if i % 10 == 0:
			await _await_frame()
	
	print("spawn_wall_torches: Total torches spawned: ", torches_spawned)

func spawn_debug_spheres_on_stairs_ends():
	# Spawn debug spheres at the end of each staircase to visualize where they lead
	print("DEBUG: Spawning debug spheres for ", spawned_stairs_coords.size(), " stairs")
	
	for stair_coord in spawned_stairs_coords.keys():
		var stairs_tile: StairsTile = spawned_stairs_coords[stair_coord]
		
		if stairs_tile == null or not is_instance_valid(stairs_tile):
			continue
			
		if not is_instance_valid(stairs_tile.stair_end_platform):
			continue
		
		# Create debug sphere
		var debug_sphere = MeshInstance3D.new()
		var sphere_mesh = SphereMesh.new()
		sphere_mesh.radius = 0.5
		sphere_mesh.height = 1.0
		debug_sphere.mesh = sphere_mesh
		debug_sphere.name = "STAIR_ENDPOINT_DEBUG"
		
		# Create yellow emissive material
		var debug_material = StandardMaterial3D.new()
		debug_material.albedo_color = Color(1.0, 1.0, 0.0, 1.0) # Yellow
		debug_material.emission_enabled = true
		debug_material.emission = Color(1.0, 1.0, 0.0, 1.0) # Yellow emission
		debug_material.emission_energy_multiplier = 2.0
		debug_sphere.material_override = debug_material
		
		# Get stair end position
		var stair_end_pos = stairs_tile.stair_end_platform.global_position
		
		# Convert to tile coordinate for X and Z only
		var stair_end_coord_raw: Vector3i = _world_to_tile_coord(stair_end_pos)
		
		# Find the NEXT floor after the stair's current floor
		var stair_floor_y = stair_coord.y
		var target_floor_y = stair_floor_y # Default to same floor if not found
		
		# Calculate actual floor Y positions from floors_heights (cumulative heights)
		var floor_y_positions: Array[int] = []
		var current_y: int = 0
		for floor_height in floors_heights:
			floor_y_positions.append(current_y)
			current_y += floor_height
		
		print("DEBUG FLOOR CALC: stair at y=", stair_floor_y, " floor_positions=", floor_y_positions)
		
		# Find the current floor index and get the NEXT floor
		for i in range(floor_y_positions.size()):
			if floor_y_positions[i] == stair_floor_y:
				# Found the current floor, now get the NEXT floor
				if i + 1 < floor_y_positions.size():
					target_floor_y = floor_y_positions[i + 1]
					print("  -> Found floor at index ", i, ", next floor y=", target_floor_y)
				break
		
		var stair_end_coord = Vector3i(stair_end_coord_raw.x, target_floor_y, stair_end_coord_raw.z)
		
		print("DEBUG: Stair at ", stair_coord, " -> looking for endpoint at: ", stair_end_coord)
		
		# Find the tile at this position
		var endpoint_tile: DungeonTile = _get_tile_at_coord(stair_end_coord)
		
		# DEBUG: Check if tile exists and what room it belongs to
		if endpoint_tile != null:
			var tile_room = all_spawned_tiles.get(endpoint_tile, null)
			print("  Tile found! Room: ", tile_room, " (is tunnel: ", tile_room == tunnel_room, ")")
		else:
			print("  Tile NOT found! Checking all_spawned_tiles...")
			# Check if ANY tile exists at this coordinate
			var found_any_tile_at_coord = false
			for tile in all_spawned_tiles.keys():
				if tile.coord == stair_end_coord:
					found_any_tile_at_coord = true
					var room = all_spawned_tiles.get(tile, null)
					print("    -> Found tile in all_spawned_tiles at ", stair_end_coord, " room: ", room)
					break
			if not found_any_tile_at_coord:
				print("    -> NO tile exists at coord ", stair_end_coord, " in all_spawned_tiles!")
		
		# Position the sphere at the center of the tile on the floor level
		var sphere_pos = Vector3(
			stair_end_coord.x * TILE_SIZE.x,
			stair_end_coord.y * TILE_SIZE.y + 1.0, # Slightly above floor
			stair_end_coord.z * TILE_SIZE.z
		)
		debug_sphere.position = sphere_pos
		dungeon_tiles.add_child(debug_sphere)
		debug_sphere.owner = _get_edited_scene_root()
		if Engine.is_editor_hint() == false:
			debug_sphere.visible = false
		# Log wall information for the endpoint tile
		if endpoint_tile != null:
			var wall_count = 0
			if endpoint_tile.wall_f != null and not endpoint_tile.wall_f.is_queued_for_deletion():
				wall_count += 1
			if endpoint_tile.wall_r != null and not endpoint_tile.wall_r.is_queued_for_deletion():
				wall_count += 1
			if endpoint_tile.wall_b != null and not endpoint_tile.wall_b.is_queued_for_deletion():
				wall_count += 1
			if endpoint_tile.wall_l != null and not endpoint_tile.wall_l.is_queued_for_deletion():
				wall_count += 1
			
			var tile_room = all_spawned_tiles.get(endpoint_tile, null)
			var is_in_tunnel = (tile_room == tunnel_room)
			
			print("  Sphere: ", stair_end_coord, " walls: ", wall_count, " is_tunnel: ", is_in_tunnel)
			
			# Check if we need to create a connecting tunnel
			if wall_count >= 3 or is_in_tunnel:
				print("  -> PROBLEMATIC endpoint! Creating connecting tunnel...")
				
				# Find nearest room tile on this floor (not tunnel)
				var nearest_room_tile: DungeonTile = _find_nearest_room_tile_on_floor(stair_end_coord, target_floor_y)
				
				if nearest_room_tile != null:
					print("    Found nearest room tile at: ", nearest_room_tile.coord)
					
					# Create orthogonal path to the nearest room
					var connecting_path: Array[Vector3i] = _create_orthogonal_path(
						stair_end_coord,
						nearest_room_tile.coord,
						target_floor_y
					)
					
					if not connecting_path.is_empty():
						print("    Creating tunnel with ", connecting_path.size(), " tiles")
						
						# Spawn tunnel tiles along the path
						var spawned_tunnel_tiles: Array[DungeonTile] = []
						for path_coord in connecting_path:
							var existing_tile = _get_tile_at_coord(path_coord)
							if existing_tile == null:
								# Create new tile
								var world_position := Vector3(
									path_coord.x * TILE_SIZE.x,
									path_coord.y * TILE_SIZE.y,
									path_coord.z * TILE_SIZE.z
								)
								var tunnel_tile: DungeonTile = DUNGEON_TILE.instantiate()
								tunnel_tile.position = world_position
								tunnel_tile.coord = path_coord
								tunnel_tile.master_dungeon = self
								dungeon_tiles.add_child(tunnel_tile)
								tunnel_tile.owner = _get_edited_scene_root()
								all_spawned_tiles[tunnel_tile] = tunnel_room
								spawned_tunnel_tiles.append(tunnel_tile)
							else:
								spawned_tunnel_tiles.append(existing_tile)
						
						# Configure tiles to remove walls
						
						for index in spawned_tunnel_tiles.size():
							var tile = spawned_tunnel_tiles[index]
							if is_instance_valid(tile):
								tile.configure_tile_based_on_neighbours(_get_neighbor_tiles(tile), true, index > 0)
						
						print("    Created connection from tunnel to room (configured ", spawned_tunnel_tiles.size(), " tiles)")
					else:
						print("    WARNING: Could not create path to nearest room")
				else:
					print("    WARNING: No nearest room found on floor y=", target_floor_y)
		else:
			print("  Sphere: ", stair_end_coord, " ERROR: No tile found!")
			
func spawn_light_stands():
	# Don't spawn light stands in editor
	if Engine.is_editor_hint():
		return
	
	# Ensure GameSpawner spawn_path is set to DungeonTiles
	if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
		var dungeon_tiles_node = GameManager._game_level.get_node_or_null("MultistoryBuildingDungeon/DungeonTiles")
		if dungeon_tiles_node != null:
			var dungeon_tiles_path = GameManager._game_spawner.get_path_to(dungeon_tiles_node)
			GameManager._game_spawner.spawn_path = dungeon_tiles_path
	
	# Check if we have light stands to spawn
	if light_stands_amount <= 0:
		return
	
	# Gather all tiles with floors and NO walls (excluding tiles with stairs)
	var tiles_with_floors_no_walls: Array[DungeonTile] = []
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(tile.coord):
			continue
		
		# Check if tile has NO walls (all walls are null or deleted)
		var has_wall: bool = false
		if tile.wall_f != null and is_instance_valid(tile.wall_f) and not tile.wall_f.is_queued_for_deletion():
			has_wall = true
		if tile.wall_r != null and is_instance_valid(tile.wall_r) and not tile.wall_r.is_queued_for_deletion():
			has_wall = true
		if tile.wall_b != null and is_instance_valid(tile.wall_b) and not tile.wall_b.is_queued_for_deletion():
			has_wall = true
		if tile.wall_l != null and is_instance_valid(tile.wall_l) and not tile.wall_l.is_queued_for_deletion():
			has_wall = true
		
		# Only add tiles with no walls
		if not has_wall:
			tiles_with_floors_no_walls.append(tile)
	
	# Sort tiles to ensure deterministic order
	tiles_with_floors_no_walls.sort_custom(_sort_tiles_by_coord)
	
	if tiles_with_floors_no_walls.is_empty():
		print("spawn_light_stands: No tiles with floors and no walls found")
		return
	
	print("spawn_light_stands: Found ", tiles_with_floors_no_walls.size(), " tiles with floors and no walls, spawning up to ", light_stands_amount, " light stands")
	
	# Get the resource path from LIGHT_STAND PackedScene
	var light_stand_path: String = LIGHT_STAND.resource_path
	if light_stand_path.is_empty():
		push_error("spawn_light_stands: LIGHT_STAND resource_path is empty!")
		return
	
	# Track spawned light stand positions for Farthest Point Sampling
	var spawned_positions: Array[Vector3] = []
	var light_stands_remaining: int = min(light_stands_amount, tiles_with_floors_no_walls.size())
	var total_light_stands_spawned: int = 0
	
	# Spawn light stands using Farthest Point Sampling
	# This ensures light stands are well-distributed across the level
	while light_stands_remaining > 0:
		var farthest_tile: DungeonTile = null
		var max_min_distance: float = 0.0
		
		# Find the tile with the maximum minimum distance to all spawned positions
		for tile in tiles_with_floors_no_walls:
			if not is_instance_valid(tile):
				continue
			
			var tile_center = tile.position
			var min_distance: float = INF
			
			# Calculate minimum distance to any spawned light stand
			if spawned_positions.is_empty():
				# First light stand - just pick this tile
				farthest_tile = tile
				break
			else:
				for spawned_pos in spawned_positions:
					var distance = tile_center.distance_to(spawned_pos)
					if distance < min_distance:
						min_distance = distance
			
			# Update farthest tile if this is farther from all spawned light stands
			if min_distance > max_min_distance:
				max_min_distance = min_distance
				farthest_tile = tile
		
		if farthest_tile == null:
			# No suitable tile found - break
			break
		
		# Randomize light stand position within tile bounds
		var random_offset_x: float = rng.randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = rng.randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var light_stand_position = farthest_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
		
		# Spawn light stand through MultiplayerSpawner for synchronization
		if multiplayer.is_server() and is_instance_valid(GameManager) and is_instance_valid(GameManager._game_spawner):
			var spawn_data = {"type": "prop", "path": light_stand_path}
			var light_stand = GameManager._game_spawner.spawn(spawn_data)
			if light_stand != null:
				# MultiplayerSpawner adds to spawn_path automatically, but we need to set position
				light_stand.position = light_stand_position
				light_stand.owner = _get_edited_scene_root()
				# Set multiplayer authority to server
				light_stand.set_multiplayer_authority(1)
				
				spawned_positions.append(light_stand_position)
				light_stands_remaining -= 1
				total_light_stands_spawned += 1
				
				# Remove tile from available tiles to avoid placing multiple light stands on same tile
				tiles_with_floors_no_walls.erase(farthest_tile)
		
		# Yield every 10 light stands to avoid frame drops
		if total_light_stands_spawned % 10 == 0:
			await _await_frame()
	
	print("spawn_light_stands: Total light stands spawned: ", total_light_stands_spawned)
