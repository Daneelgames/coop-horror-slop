@tool
extends Node3D
class_name ProceduralDungeon

const DUNGEON_TILE = preload("uid://cefhqgvoa83r2")
const TILE_SIZE : Vector3i = Vector3i(4,4,4) # tile's origin is at its bottom center
enum ROOM_SPAWN_TYPE {RANDOM, CIRCLE}
@export var room_spawn_type : ROOM_SPAWN_TYPE
@export var rooms_circle_spawn_radius_in_tiles : int = 10
@export var min_distance_between_rooms_in_tiles : int = 10
@export var max_distance_between_rooms_in_tiles : int = 20
@export var rooms_resources : Array[ResourceDungeonRoom]
@export var spawned_room_tiles : Dictionary[ResourceDungeonRoom, Array] # value is Array[DungeonTile]
@export var all_spawned_tiles : Dictionary[DungeonTile, ResourceDungeonRoom]

@export var gen : bool = false:
	set(v):
		gen = false
		generate_dungeon()

@export var clr : bool = false:
	set(v):
		clr = false
		clear()

@onready var dungeon_tiles: Node3D = %DungeonTiles
func clear():
	if is_instance_valid(dungeon_tiles):
		for child in dungeon_tiles.get_children():
			child.queue_free()
	spawned_room_tiles.clear()
	all_spawned_tiles.clear()
	
func generate_dungeon():
	# Clear existing tiles
	clear()
	# Duplicate room resources
	for index in rooms_resources.size():
		rooms_resources[index] = rooms_resources[index].duplicate()
	
	# Generate base coordinates for each room considering min_distance_between_rooms_in_tiles
	var room_base_coords: Array[Vector3i] = []
	
	if room_spawn_type == ROOM_SPAWN_TYPE.CIRCLE:
		# Spawn rooms in circular formation
		var room_count: int = rooms_resources.size()
		if room_count > 0:
			var angle_step: float = (2.0 * PI) / room_count
			for room_index in room_count:
				var room: ResourceDungeonRoom = rooms_resources[room_index]
				var angle: float = room_index * angle_step
				var x: float = rooms_circle_spawn_radius_in_tiles * cos(angle)
				var z: float = rooms_circle_spawn_radius_in_tiles * sin(angle)
				var base_coord: Vector3i = Vector3i(
					int(round(x)),
					room.base_room_height,
					int(round(z))
				)
				room_base_coords.append(base_coord)
	else:
		# RANDOM spawn type - use original random positioning logic
		var max_attempts: int = 1000
		
		for room_index in rooms_resources.size():
			var room: ResourceDungeonRoom = rooms_resources[room_index]
			var base_coord: Vector3i = Vector3i.ZERO
			var found_position: bool = false
			
			# Try to find a valid position
			for attempt in range(max_attempts):
				# Generate random tile coordinates
				var x: int = randi_range(-50, 50)
				var z: int = randi_range(-50, 50)
				var y: int = room.base_room_height
				base_coord = Vector3i(x, y, z)
				
				# Check if this position is far enough from all existing rooms
				var valid_position: bool = true
				for existing_coord in room_base_coords:
					var distance: float = Vector3i(existing_coord.x - base_coord.x, 0, existing_coord.z - base_coord.z).length()
					if distance < min_distance_between_rooms_in_tiles or distance > max_distance_between_rooms_in_tiles:
						valid_position = false
						break
				
				if valid_position:
					found_position = true
					break
			
			# If we couldn't find a valid position, use a fallback position
			if not found_position:
				# Place rooms in a grid pattern as fallback
				var grid_size: int = int(ceil(sqrt(rooms_resources.size())))
				var grid_x: int = room_index % grid_size
				var grid_z: int = int(floor(room_index / float(grid_size)))
				base_coord = Vector3i(
					grid_x * min_distance_between_rooms_in_tiles,
					room.base_room_height,
					grid_z * min_distance_between_rooms_in_tiles
				)
			
			room_base_coords.append(base_coord)
	
	# Now spawn tiles at the calculated base coordinates
	for room_index in rooms_resources.size():
		var room: ResourceDungeonRoom = rooms_resources[room_index]
		var base_coord: Vector3i = room_base_coords[room_index]
		
		# Convert tile coordinates to world position
		# TILE_SIZE is Vector3i(4,4,4) and tile's origin is at its bottom center
		var world_position: Vector3 = Vector3(
			base_coord.x * TILE_SIZE.x,
			base_coord.y * TILE_SIZE.y,
			base_coord.z * TILE_SIZE.z
		)
		
		# Place tile at the base coordinate
		var tile: DungeonTile = DUNGEON_TILE.instantiate()
		tile.position = world_position
		tile.coord = base_coord
		dungeon_tiles.add_child(tile)
		tile.owner = get_tree().edited_scene_root
		all_spawned_tiles[tile] = room
		# Store tile in spawned_room_tiles dictionary
		if not spawned_room_tiles.has(room):
			spawned_room_tiles[room] = []
		spawned_room_tiles[room].append(tile)
	
	# Run random walkers for each room to spawn additional tiles
	for room in rooms_resources:
		await _run_random_walker_for_room(room)
	
	# Apply mirroring for each room
	for room in rooms_resources:
		if room.mirror_x or room.mirror_z:
			await _apply_mirroring_for_room(room)
	
	# Expand rooms vertically upward
	await _expand_rooms_vertically()
	
	# Configure all tiles based on their neighbors
	_configure_all_tiles_based_on_neighbours()

func _is_coord_free(coord: Vector3i) -> bool:
	# Check if coord is free by looping over all_spawned_tiles
	for tile in all_spawned_tiles.keys():
		if tile.coord == coord:
			return false
	return true

func _run_random_walker_for_room(room: ResourceDungeonRoom):
	if not spawned_room_tiles.has(room) or spawned_room_tiles[room].is_empty():
		return
	
	var tiles_to_spawn: int = room.target_tiles_amount - spawned_room_tiles[room].size()
	if tiles_to_spawn <= 0:
		return
	
	# Start walker at the base tile (first tile)
	var walker_coord: Vector3i = spawned_room_tiles[room][0].coord
	var counter: int = 0
	var max_iterations: int = tiles_to_spawn * 1000  # Safety limit
	var last_step_was_vertical: bool = false
	
	while tiles_to_spawn > 0 and counter < max_iterations:
		counter += 1
		
		# Decide if walker moves vertically or horizontally
		# Never make two vertical steps in a row
		var should_move_vertically: bool = false
		if not last_step_was_vertical and randf() < room.walker_change_floor_height_chance:
			should_move_vertically = true
		
		if should_move_vertically:
			# Move vertically (up or down)
			var direction: int = 1 if randf() < 0.5 else -1
			var new_coord: Vector3i = Vector3i(walker_coord.x, walker_coord.y + direction, walker_coord.z)
			
			if _is_coord_free(new_coord):
				walker_coord = new_coord
				_spawn_tile_at_coord(room, walker_coord)
				tiles_to_spawn -= 1
				last_step_was_vertical = true
				if counter % 10 == 0:
					await get_tree().process_frame
			else:
				# Teleport to random spawned tile from this room
				if spawned_room_tiles[room].size() > 0:
					var random_tile: DungeonTile = spawned_room_tiles[room][randi() % spawned_room_tiles[room].size()]
					walker_coord = random_tile.coord
					last_step_was_vertical = false  # Reset on teleport
		else:
			# Move horizontally (in X or Z direction)
			var directions: Array[Vector3i] = [
				Vector3i(1, 0, 0),   # Right
				Vector3i(-1, 0, 0),  # Left
				Vector3i(0, 0, 1),   # Forward
				Vector3i(0, 0, -1)   # Backward
			]
			var direction: Vector3i = directions[randi() % directions.size()]
			var new_coord: Vector3i = walker_coord + direction
			
			if _is_coord_free(new_coord):
				walker_coord = new_coord
				_spawn_tile_at_coord(room, walker_coord)
				tiles_to_spawn -= 1
				last_step_was_vertical = false
				if counter % 10 == 0:
					await get_tree().process_frame
			else:
				# Teleport to random spawned tile from this room
				if spawned_room_tiles[room].size() > 0:
					var random_tile: DungeonTile = spawned_room_tiles[room][randi() % spawned_room_tiles[room].size()]
					walker_coord = random_tile.coord
					last_step_was_vertical = false  # Reset on teleport

func _spawn_tile_at_coord(room: ResourceDungeonRoom, coord: Vector3i):
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	var tile: DungeonTile = DUNGEON_TILE.instantiate()
	tile.position = world_position
	tile.coord = coord
	dungeon_tiles.add_child(tile)
	tile.owner = get_tree().edited_scene_root
	all_spawned_tiles[tile] = room
	
	if not spawned_room_tiles.has(room):
		spawned_room_tiles[room] = []
	spawned_room_tiles[room].append(tile)

func _apply_mirroring_for_room(room: ResourceDungeonRoom):
	if not spawned_room_tiles.has(room) or spawned_room_tiles[room].is_empty():
		return
	
	# Get all tiles for this room before mirroring (to avoid mirroring mirrored tiles)
	var original_tiles = spawned_room_tiles[room].duplicate()
	var base_coord: Vector3i = original_tiles[0].coord
	
	# Mirror each tile
	for tile in original_tiles:
		var original_coord: Vector3i = tile.coord
		var mirrored_coord: Vector3i = original_coord
		
		# Apply mirroring around base coord
		if room.mirror_x:
			mirrored_coord = Vector3i(
				2 * base_coord.x - original_coord.x,
				mirrored_coord.y,
				mirrored_coord.z
			)
		
		if room.mirror_z:
			mirrored_coord = Vector3i(
				mirrored_coord.x,
				mirrored_coord.y,
				2 * base_coord.z - original_coord.z
			)
		
		# Only spawn if coord is free
		if _is_coord_free(mirrored_coord):
			_spawn_tile_at_coord(room, mirrored_coord)
			await get_tree().process_frame

func _expand_rooms_vertically():
	# Expand each room upward by spawning vertical wall tiles
	var t = 0
	for room in rooms_resources:
		if not spawned_room_tiles.has(room):
			continue
		
		# Get all tiles for this room (make a copy to avoid modifying while iterating)
		var tiles_to_expand = spawned_room_tiles[room].duplicate()
		
		# For each tile, spawn vertical wall tiles above it
		for tile in tiles_to_expand:
			var base_coord: Vector3i = tile.coord
			
			# Spawn tiles upward based on default_vertical_wall_tiles_amount
			for i in range(1, room.default_vertical_wall_tiles_amount + 1):
				var vertical_coord: Vector3i = Vector3i(base_coord.x, base_coord.y + i, base_coord.z)
				
				# Only spawn if coord is free
				if _is_coord_free(vertical_coord):
					# _spawn_tile_at_coord adds tiles to both all_spawned_tiles and spawned_room_tiles
					# so they will be configured later in _configure_all_tiles_based_on_neighbours()
					_spawn_tile_at_coord(room, vertical_coord)
					t += 1
					if t >= 100:
						t = 0
						await get_tree().process_frame

func _configure_all_tiles_based_on_neighbours():
	# Configure each tile based on its neighbors
	var total_tiles = all_spawned_tiles.size()
	print("DEBUG: Configuring ", total_tiles, " tiles")
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			print("WARNING: Invalid tile found in all_spawned_tiles")
			continue
		var neighbors: Array[DungeonTile] = _get_neighbor_tiles(tile)
		tile.configure_tile_based_on_neighbours(neighbors)

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
