@tool
extends LevelGenerator
class_name MultistoryBuildingDungeon

const DUNGEON_TILE = preload("uid://cefhqgvoa83r2")
const STAIRS_1 = preload("res://assets/prefabs/environment/dungeon_walls/stairs_1.tscn")
const DOORS_PREFABS = [preload("uid://biuu4fqetp2o8")]
const TILE_SIZE : Vector3i = Vector3i(4, 2, 4) # tile's origin is at its bottom center

@export var floors_heights : Array[int] = [2, 3, 4, 5, 6]
@export var rooms_per_floor_min_max : Vector2i = Vector2i(3, 8)  # Минимальное и максимальное количество комнат на этаж
@export var apartment_side_size_min_max : Vector2i = Vector2i(2, 5)
@export var min_stairs_per_floor: int = 1  # Минимальное количество лестниц на этаж
@export var max_stairs_per_floor: int = 3  # Максимальное количество лестниц на этаж

@export var gen : bool = false:
	set(v):
		if Engine.is_editor_hint() == false:
			return
		gen = false
		generate_dungeon()

@export var clr : bool = false:
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

@export var all_spawned_tiles : Dictionary[DungeonTile, ResourceDungeonRoom]
@export var room_assignment: Dictionary[DungeonTile, ResourceDungeonRoom] = {}  # Для проверки принадлежности к комнате
@export var spawned_stairs_coords : Dictionary[Vector3i, Node] # coord, stairs node
@export var spawned_doors_coords_new : Dictionary[String, Node] # "coord1-coord2", door node
@export var apartment_rooms_by_floor: Dictionary[int, Array] = {}  # floor_y -> Array[ResourceDungeonRoom]

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
		await _await_frame()  # Await после каждого этажа
	
	# Спавн лестниц между этажами
	for floor_num in range(floors_count - 1):
		var floor_y: int = floor_y_positions[floor_num]
		var floor_above_y: int = floor_y_positions[floor_num + 1]
		_spawn_stairs_between_floors(floor_y, floor_above_y)
		await _await_frame()
	
	# Объединение комнат дверьми на каждом этаже (до конфигурации тайлов!)
	for floor_num in range(floors_count):
		var floor_y: int = floor_y_positions[floor_num]
		await _connect_rooms_with_doors_on_floor(floor_y)
		await _await_frame()
	
	# Конфигурация тайлов с проверкой комнат
	await _configure_all_tiles_with_room_check()
	await _await_frame()
	
	level_generated.emit()
	await _await_frame()

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
	var first_room_x_start: int = -first_room_width / 2
	var first_room_z_start: int = -first_room_depth / 2
	var first_room_x_end: int = first_room_x_start + first_room_width
	var first_room_z_end: int = first_room_z_start + first_room_depth
	
	var first_room = await _generate_apartment(first_room_x_start, first_room_x_end, first_room_z_start, first_room_z_end, floor_y, floor_height)
	if first_room != null:
		apartments_on_floor.append(first_room)
		rooms_data.append({
			"room": first_room,
			"x_start": first_room_x_start,
			"x_end": first_room_x_end,
			"z_start": first_room_z_start,
			"z_end": first_room_z_end
		})
	
	# Генерировать остальные комнаты
	var rooms_created: int = 1
	var max_attempts: int = rooms_count * 100  # Максимум попыток на комнату
	var attempts: int = 0
	
	while rooms_created < rooms_count and attempts < max_attempts:
		attempts += 1
		
		# Определить размер новой комнаты
		var room_width: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
		var room_depth: int = rng.randi_range(apartment_side_size_min_max.x, apartment_side_size_min_max.y)
		
		# Найти позицию для новой комнаты по касательной к существующим
		var room_pos: Dictionary = _find_tangent_position(rooms_data, room_width, room_depth)
		
		if room_pos.has("x_start"):
			# Создать комнату
			var apartment_room = await _generate_apartment(
				room_pos.x_start, room_pos.x_end,
				room_pos.z_start, room_pos.z_end,
				floor_y, floor_height
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
			"touches": true  # Касается по правой стене
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
			"touches": true  # Касается по левой стене
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
			"touches": true  # Касается по верхней стене
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
			"touches": true  # Касается по нижней стене
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
			return true  # Касаются по Z
	
	# Проверить пересечение по Z и касание по X
	if not (z1_end <= z2_start or z1_start >= z2_end):
		# Есть перекрытие по Z
		if x1_end == x2_start or x1_start == x2_end:
			return true  # Касаются по X
	
	return false

func _generate_apartment(x_start: int, x_end: int, z_start: int, z_end: int, floor_y: int, floor_height: int) -> ResourceDungeonRoom:
	# Создать комнату для квартиры
	var apartment_room = ResourceDungeonRoom.new()
	apartment_room.base_room_height = floor_y
	
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
	print("_connect_rooms_with_doors_on_floor: Called for floor_y=", floor_y)
	
	if not apartment_rooms_by_floor.has(floor_y):
		print("_connect_rooms_with_doors_on_floor: No rooms found for floor_y=", floor_y)
		return
	
	var rooms_on_floor: Array[ResourceDungeonRoom] = apartment_rooms_by_floor[floor_y]
	print("_connect_rooms_with_doors_on_floor: Found ", rooms_on_floor.size(), " rooms on floor_y=", floor_y)
	
	if rooms_on_floor.size() <= 1:
		print("_connect_rooms_with_doors_on_floor: Only ", rooms_on_floor.size(), " room(s), skipping")
		return  # Нет смысла объединять одну комнату или меньше
	
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
	
	print("_connect_rooms_with_doors_on_floor: Found ", tiles_found, " tiles on floor_y=", floor_y, " grouped into ", tiles_by_room.size(), " rooms")
	
	# Фильтровать комнаты - оставить только те, у которых есть тайлы на этом этаже
	var rooms_with_tiles: Array[ResourceDungeonRoom] = []
	for room in rooms_on_floor:
		if tiles_by_room.has(room) and tiles_by_room[room].size() > 0:
			rooms_with_tiles.append(room)
		else:
			print("_connect_rooms_with_doors_on_floor: WARNING - Room has no tiles on floor_y=", floor_y)
	
	if rooms_with_tiles.size() <= 1:
		print("_connect_rooms_with_doors_on_floor: Only ", rooms_with_tiles.size(), " room(s) with tiles, skipping")
		return
	
	# Найти комнату с наименьшим количеством тайлов
	var unconnected_rooms: Array[ResourceDungeonRoom] = rooms_with_tiles.duplicate()
	var connected_rooms: Array[ResourceDungeonRoom] = []
	
	# Найти комнату с минимальным количеством тайлов
	var min_tiles_count: int = 999999  # Используем большое число вместо INF
	var start_room: ResourceDungeonRoom = null
	print("_connect_rooms_with_doors_on_floor: Searching for start room among ", unconnected_rooms.size(), " rooms")
	
	for room in unconnected_rooms:
		var tiles_count: int = tiles_by_room.get(room, []).size()
		print("_connect_rooms_with_doors_on_floor: Room has ", tiles_count, " tiles, current min=", min_tiles_count)
		if tiles_count > 0:
			if tiles_count < min_tiles_count:
				min_tiles_count = tiles_count
				start_room = room
				print("_connect_rooms_with_doors_on_floor: New candidate start room with ", tiles_count, " tiles")
	
	if start_room == null:
		print("_connect_rooms_with_doors_on_floor: ERROR - Could not find start room! rooms_with_tiles=", rooms_with_tiles.size(), ", tiles_by_room=", tiles_by_room.size(), ", unconnected_rooms=", unconnected_rooms.size())
		# Вывести информацию о комнатах
		for room in unconnected_rooms:
			var tiles_count: int = tiles_by_room.get(room, []).size()
			print("  Room tiles count: ", tiles_count)
		return
	
	print("_connect_rooms_with_doors_on_floor: Starting with room that has ", min_tiles_count, " tiles")
	
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
		print("_connect_rooms_with_doors_on_floor: Found ", rooms_to_connect.size(), " rooms to connect")
		
		for room_to_connect in rooms_to_connect:
			# Найти комнату из connected_rooms, которая соседствует с room_to_connect
			var source_room: ResourceDungeonRoom = null
			for connected_room in connected_rooms:
				if _rooms_are_neighbors(connected_room, room_to_connect, floor_y, tiles_by_room):
					source_room = connected_room
					break
			
			if source_room == null:
				# Если не нашли соседнюю, используем ближайшую
				print("_connect_rooms_with_doors_on_floor: No neighboring room found, using closest")
				source_room = _find_closest_room(room_to_connect, connected_rooms, floor_y, tiles_by_room)
			
			if source_room != null:
				print("_connect_rooms_with_doors_on_floor: Connecting rooms, source_room tiles=", tiles_by_room.get(source_room, []).size(), ", target_room tiles=", tiles_by_room.get(room_to_connect, []).size())
				# Заспавнить двери между source_room и room_to_connect
				await _spawn_doors_between_rooms(source_room, room_to_connect, floor_y, tiles_by_room)
			else:
				print("_connect_rooms_with_doors_on_floor: ERROR - Could not find source room!")
			
			# Добавить найденную комнату в соединенные
			connected_rooms.append(room_to_connect)
			unconnected_rooms.erase(room_to_connect)
		
		rooms_processed += 1
		if rooms_processed % 5 == 0:
			await _await_frame()
	
	print("_connect_rooms_with_doors_on_floor: Connected ", rooms_on_floor.size(), " rooms on floor_y=", floor_y, ", total doors spawned: ", spawned_doors_coords_new.size())

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
	var tiles1: Array = tiles_by_room.get(room1, [])
	var tiles2: Array = tiles_by_room.get(room2, [])
	
	print("_spawn_doors_between_rooms: room1 has ", tiles1.size(), " tiles, room2 has ", tiles2.size(), " tiles at floor_y=", floor_y)
	
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
			Vector3i(1, 0, 0),   # Right
			Vector3i(-1, 0, 0),  # Left
			Vector3i(0, 0, 1),   # Forward
			Vector3i(0, 0, -1)   # Backward
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
	
	print("_spawn_doors_between_rooms: Found ", door_candidates.size(), " door candidates")
	
	# Заспавнить дверь на одном из кандидатов
	if door_candidates.size() > 0:
		# Выбрать случайный кандидат
		var candidate: Dictionary = door_candidates[rng.randi() % door_candidates.size()]
		var tile1: DungeonTile = candidate.tile1
		var tile2: DungeonTile = candidate.tile2
		var offset: Vector3i = candidate.offset
		
		# Удалить стены между тайлами (на нижнем уровне)
		_remove_wall_between_tiles(tile1, tile2, offset)
		
		# Удалить стены между верхними тайлами (если они есть)
		var upper_tile1: DungeonTile = _get_tile_at_coord(Vector3i(tile1.coord.x, tile1.coord.y + 1, tile1.coord.z))
		var upper_tile2: DungeonTile = _get_tile_at_coord(Vector3i(tile2.coord.x, tile2.coord.y + 1, tile2.coord.z))
		if upper_tile1 != null and upper_tile2 != null:
			_remove_wall_between_tiles(upper_tile1, upper_tile2, offset)
		
		# Заспавнить дверь на одном из тайлов
		await _spawn_door_between_tiles(tile1, tile2, offset, floor_y)
	else:
		print("_spawn_doors_between_rooms: WARNING - No door candidates found between rooms!")

func _remove_wall_between_tiles(tile1: DungeonTile, tile2: DungeonTile, offset: Vector3i):
	# Удалить стены между двумя соседними тайлами
	# offset - направление от tile1 к tile2
	
	print("_remove_wall_between_tiles: Removing wall between tiles, offset=", offset)
	
	# У tile1 удалить стену в направлении offset
	if offset == Vector3i(1, 0, 0):
		# tile2 справа от tile1 - удалить правую стену tile1
		print("_remove_wall_between_tiles: Removing wall_r from tile1, wall_l from tile2")
		if is_instance_valid(tile1.wall_r):
			tile1.wall_r.queue_free()
			tile1.wall_r = null
		# У tile2 удалить левую стену
		if is_instance_valid(tile2.wall_l):
			tile2.wall_l.queue_free()
			tile2.wall_l = null
	elif offset == Vector3i(-1, 0, 0):
		# tile2 слева от tile1 - удалить левую стену tile1
		print("_remove_wall_between_tiles: Removing wall_l from tile1, wall_r from tile2")
		if is_instance_valid(tile1.wall_l):
			tile1.wall_l.queue_free()
			tile1.wall_l = null
		# У tile2 удалить правую стену
		if is_instance_valid(tile2.wall_r):
			tile2.wall_r.queue_free()
			tile2.wall_r = null
	elif offset == Vector3i(0, 0, 1):
		# tile2 вперед от tile1 (Z+) - удалить переднюю стену tile1 (wall_f)
		print("_remove_wall_between_tiles: Removing wall_f from tile1, wall_b from tile2")
		if is_instance_valid(tile1.wall_f):
			tile1.wall_f.queue_free()
			tile1.wall_f = null
		# У tile2 удалить заднюю стену (wall_b)
		if is_instance_valid(tile2.wall_b):
			tile2.wall_b.queue_free()
			tile2.wall_b = null
	elif offset == Vector3i(0, 0, -1):
		# tile2 назад от tile1 (Z-) - удалить заднюю стену tile1 (wall_b)
		print("_remove_wall_between_tiles: Removing wall_b from tile1, wall_f from tile2")
		if is_instance_valid(tile1.wall_b):
			tile1.wall_b.queue_free()
			tile1.wall_b = null
		# У tile2 удалить переднюю стену (wall_f)
		if is_instance_valid(tile2.wall_f):
			tile2.wall_f.queue_free()
			tile2.wall_f = null
	else:
		print("_remove_wall_between_tiles: WARNING - Unknown offset: ", offset)

func _spawn_door_between_tiles(tile1: DungeonTile, tile2: DungeonTile, offset: Vector3i, floor_y: int):
	# Заспавнить дверь между двумя тайлами
	# Используем tile1 как позицию для двери
	var door_tile: DungeonTile = tile1
	
	# Проверить, что тайл на нижнем уровне этажа (floor_y)
	if door_tile.coord.y != floor_y:
		print("_spawn_door_between_tiles: Tile Y (", door_tile.coord.y, ") != floor_y (", floor_y, ")")
		return
	
	# Проверить, что у тайла есть пол (нет соседа снизу на том же уровне этажа)
	var neighbor_below: DungeonTile = _get_tile_at_coord(door_tile.coord + Vector3i(0, -1, 0))
	if neighbor_below != null:
		if neighbor_below.coord.y >= floor_y:
			print("_spawn_door_between_tiles: Tile has neighbor below at same floor level")
			return
	
	# Проверить, что над тайлом есть тайл (двери 2 тайла высотой)
	var upper_coord: Vector3i = Vector3i(door_tile.coord.x, door_tile.coord.y + 1, door_tile.coord.z)
	var upper_tile: DungeonTile = _get_tile_at_coord(upper_coord)
	
	if upper_tile == null:
		# Создать тайл сверху
		var room: ResourceDungeonRoom = all_spawned_tiles.get(door_tile, null)
		if room != null:
			_spawn_tile_at_coord_for_door(room, upper_coord)
			upper_tile = _get_tile_at_coord(upper_coord)
	
	if upper_tile == null:
		print("_spawn_door_between_tiles: ERROR - Could not create upper tile!")
		return
	
	# Проверить, что здесь еще нет двери между этими тайлами
	var test_coord1 = tile1.coord
	var test_coord2 = tile2.coord
	var test_sorted_coords = [test_coord1, test_coord2]
	test_sorted_coords.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))))
	var test_coord1_str = "%d_%d_%d" % [test_sorted_coords[0].x, test_sorted_coords[0].y, test_sorted_coords[0].z]
	var test_coord2_str = "%d_%d_%d" % [test_sorted_coords[1].x, test_sorted_coords[1].y, test_sorted_coords[1].z]
	var test_pair_key = test_coord1_str + "-" + test_coord2_str
	if spawned_doors_coords_new.has(test_pair_key):
		print("_spawn_door_between_tiles: Door already exists between ", tile1.coord, " and ", tile2.coord)
		return
	
	# Выбрать случайный префаб двери
	var door_prefab = DOORS_PREFABS[rng.randi() % DOORS_PREFABS.size()]
	var door = door_prefab.instantiate()
	if door == null:
		print("_spawn_door_between_tiles: ERROR - Failed to instantiate door!")
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
	print("_spawn_door_between_tiles: Spawned door between ", tile1.coord, " and ", tile2.coord, ", key=", pair_key)

func _spawn_door_at_tile(tile: DungeonTile, floor_y: int):
	# Заспавнить дверь на указанном тайле
	print("_spawn_door_at_tile: Attempting to spawn door at ", tile.coord, " floor_y=", floor_y)
	
	# Note: door existence check removed since doors are now stored by pairs
	# if spawned_doors_coords.has(tile.coord):
	# 	print("_spawn_door_at_tile: Door already exists at ", tile.coord)
	# 	return  # Дверь уже есть
	
	# Проверить, что тайл на нижнем уровне этажа (floor_y)
	# floor_y - это Y координата нижнего уровня текущего этажа
	if tile.coord.y != floor_y:
		print("_spawn_door_at_tile: Tile Y (", tile.coord.y, ") != floor_y (", floor_y, ")")
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
			print("_spawn_door_at_tile: Tile has neighbor below at same floor level (", neighbor_below.coord.y, " >= ", floor_y, ")")
			return  # У этого тайла нет пола (есть тайл того же этажа снизу)
	
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
	var door_direction: Vector3i = Vector3i.ZERO  # Направление к соседу из другой комнаты
	
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
		print("_spawn_door_at_tile: No neighbors from different room found")
		return  # Нет соседей из другой комнаты
	
	print("_spawn_door_at_tile: Found neighbor from different room, direction=", door_direction)
	
	# Проверить, что над тайлом есть тайл (двери 2 тайла высотой)
	var upper_coord: Vector3i = Vector3i(tile.coord.x, tile.coord.y + 1, tile.coord.z)
	var upper_tile: DungeonTile = _get_tile_at_coord(upper_coord)
	
	if upper_tile == null:
		print("_spawn_door_at_tile: No upper tile, creating one at ", upper_coord)
		# Создать тайл сверху
		var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
		if room != null:
			_spawn_tile_at_coord_for_door(room, upper_coord)
			upper_tile = _get_tile_at_coord(upper_coord)
		else:
			print("_spawn_door_at_tile: ERROR - Could not find room for tile!")
	
	if upper_tile == null:
		print("_spawn_door_at_tile: ERROR - Could not create upper tile!")
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
	print("_spawn_door_at_tile: Spawned door at ", tile.coord, " direction=", door_direction)

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
	dungeon_tiles.add_child(tile)
	tile.owner = _get_edited_scene_root()
	
	all_spawned_tiles[tile] = room
	room_assignment[tile] = room

func _spawn_stairs_between_floors(floor_y: int, floor_above_y: int):
	# Определить количество лестниц для этого этажа
	var stairs_count: int = rng.randi_range(min_stairs_per_floor, max_stairs_per_floor)
	
	# Получить все квартиры на нижнем этаже
	if not apartment_rooms_by_floor.has(floor_y):
		return
	
	var apartments: Array[ResourceDungeonRoom] = apartment_rooms_by_floor[floor_y]
	if apartments.is_empty():
		return
	
	# Собрать все тайлы с полом на нижнем этаже (кандидаты для лестниц)
	var candidate_tiles: Array[DungeonTile] = []
	for tile in all_spawned_tiles.keys():
		if tile.coord.y != floor_y:
			continue
		
		# Проверить, что у тайла есть пол (нет соседа снизу)
		var neighbor_below: DungeonTile = _get_tile_at_coord(tile.coord + Vector3i(0, -1, 0))
		if neighbor_below != null:
			continue  # У этого тайла нет пола
		
		# Проверить, что над этим тайлом есть тайл на верхнем этаже
		var tile_above: DungeonTile = _get_tile_at_coord(Vector3i(tile.coord.x, floor_above_y, tile.coord.z))
		if tile_above == null:
			continue  # Нет тайла сверху
		
		# Проверить, что у верхнего тайла есть пол (нет соседа снизу на его уровне)
		var neighbor_below_above: DungeonTile = _get_tile_at_coord(tile_above.coord + Vector3i(0, -1, 0))
		if neighbor_below_above == null:
			continue  # У верхнего тайла нет пола
		
		candidate_tiles.append(tile)
	
	if candidate_tiles.is_empty():
		print("_spawn_stairs_between_floors: No candidate tiles found for floor_y=", floor_y)
		return
	
	# Перемешать кандидатов
	_shuffle_array(candidate_tiles)
	
	# Спавнить лестницы
	var stairs_spawned: int = 0
	for tile in candidate_tiles:
		if stairs_spawned >= stairs_count:
			break
		
		# Проверить, что у нижнего тайла нет потолка (чтобы лестница могла пройти)
		# Это проверим позже при спавне - потолок может быть удален при конфигурации
		# Но для безопасности проверим сейчас
		if is_instance_valid(tile.ceiling):
			continue  # Пропустить - потолок заблокирует лестницу
		
		# Проверить, что здесь еще нет лестницы
		if spawned_stairs_coords.has(tile.coord):
			continue
		
		# Определить направление лестницы (случайное горизонтальное направление)
		var horizontal_directions: Array[Vector3i] = [
			Vector3i(1, 0, 0),   # Right
			Vector3i(-1, 0, 0),  # Left
			Vector3i(0, 0, 1),   # Forward
			Vector3i(0, 0, -1)   # Backward
		]
		var tunnel_direction: Vector3i = horizontal_directions[rng.randi() % horizontal_directions.size()]
		var vertical_direction: int = 1  # Вверх
		
		# Получить комнату для этого тайла
		var room: ResourceDungeonRoom = all_spawned_tiles.get(tile, null)
		if room == null:
			continue
		
		# Спавнить лестницу
		_spawn_stairs_at_coord(room, tile.coord, tunnel_direction, vertical_direction)
		stairs_spawned += 1
	
	print("_spawn_stairs_between_floors: Spawned ", stairs_spawned, " stairs between floor_y=", floor_y, " and floor_above_y=", floor_above_y)

func _spawn_stairs_at_coord(room: ResourceDungeonRoom, coord: Vector3i, tunnel_direction: Vector3i = Vector3i.ZERO, vertical_direction: int = 0):
	# Spawn stairs at the specified coordinate
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	var stairs = STAIRS_1.instantiate()
	
	# Rotate stairs so the top part (blue arrow, negative Z) faces the tunnel direction
	# tunnel_direction indicates the horizontal direction from bottom to top tile
	# In Godot: 0° = +Z, 90° = -X, 180° = -Z, 270° = +X
	# Since stairs top is at -Z (180°), we need to rotate based on tunnel_direction
	var rotation_y: float = 0.0
	
	if tunnel_direction.x > 0:
		# Going in +X direction, stairs should face +X (270° or -90°)
		rotation_y = deg_to_rad(-90)
	elif tunnel_direction.x < 0:
		# Going in -X direction, stairs should face -X (90°)
		rotation_y = deg_to_rad(90)
	elif tunnel_direction.z > 0:
		# Going in +Z direction, stairs should face +Z (0°)
		# But stairs top is at -Z, so we need 180° rotation
		rotation_y = deg_to_rad(180)
	elif tunnel_direction.z < 0:
		# Going in -Z direction, stairs should face -Z (180°)
		# But stairs top is at -Z, so no rotation needed (0°)
		rotation_y = 0.0
	
	stairs.rotation.y = rotation_y
	stairs.rotation_degrees.y += 180
	
	stairs.position = world_position
	dungeon_tiles.add_child(stairs)
	
	# Cache stairs coord
	spawned_stairs_coords[coord] = stairs
	
	# Build stairs name
	var stairs_name: String = str(tunnel_direction) + "_" + str(vertical_direction)
	stairs.name += "_" + stairs_name
	stairs.owner = _get_edited_scene_root()

func _configure_all_tiles_with_room_check():
	# Configure each tile based on its neighbors with room check
	var total_tiles = all_spawned_tiles.size()
	print("DEBUG: Configuring ", total_tiles, " tiles with room check")
	var tiles_configured: int = 0
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			print("WARNING: Invalid tile found in all_spawned_tiles")
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
		Vector3i(0, 1, 0),   # Top (ceiling check)
		Vector3i(0, -1, 0),  # Bottom (floor check)
		Vector3i(0, 0, 1),   # Forward (wall check)
		Vector3i(0, 0, -1), # Back (wall check)
		Vector3i(1, 0, 0),   # Right (wall check)
		Vector3i(-1, 0, 0)  # Left (wall check)
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
