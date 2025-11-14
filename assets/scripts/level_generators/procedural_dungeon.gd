@tool
extends Node3D
class_name ProceduralDungeon

const DUNGEON_TILE = preload("uid://cefhqgvoa83r2")
const STAIRS_1 = preload("res://assets/prefabs/environment/dungeon_walls/stairs_1.tscn")
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
	await connect_rooms_with_tunnels()
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

func connect_rooms_with_tunnels():
	# connect each room in order of their spawn
	# find two closest tiles between two rooms 
	# and connect them with a tunnel of tiles
	# tunnel walker should only be able to walk in straight directions: up down left right front back
	# after making a vertical step, walker should make 2 horizontal steps minimum before making another vertical one
	# use tiles counter and await frame every 100 tile
	
	if rooms_resources.size() < 2:
		return  # Need at least 2 rooms to connect
	
	var tiles_spawned: int = 0
	
	# Connect each room to the next one in order
	for room_index in range(rooms_resources.size() - 1):
		var room1: ResourceDungeonRoom = rooms_resources[room_index]
		var room2: ResourceDungeonRoom = rooms_resources[room_index + 1]
		
		if not spawned_room_tiles.has(room1) or spawned_room_tiles[room1].is_empty():
			continue
		if not spawned_room_tiles.has(room2) or spawned_room_tiles[room2].is_empty():
			continue
		
		# Find closest tiles between the two rooms
		var closest_pair = _find_closest_tiles_between_rooms(room1, room2)
		if closest_pair.is_empty():
			continue
		
		var tile1: DungeonTile = closest_pair[0]
		var tile2: DungeonTile = closest_pair[1]
		
		# Create tunnel between the two tiles
		var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, room1)
		tiles_spawned += tunnel_tiles.size()
		
		# Await frame every 100 tiles
		if tiles_spawned >= 100:
			tiles_spawned = 0
			await get_tree().process_frame
	
	# Connect last room back to first room (circular connection)
	if rooms_resources.size() >= 2:
		var last_room: ResourceDungeonRoom = rooms_resources[rooms_resources.size() - 1]
		var first_room: ResourceDungeonRoom = rooms_resources[0]
		
		if spawned_room_tiles.has(last_room) and not spawned_room_tiles[last_room].is_empty() and \
		   spawned_room_tiles.has(first_room) and not spawned_room_tiles[first_room].is_empty():
			
			# Find closest tiles between the two rooms
			var closest_pair = _find_closest_tiles_between_rooms(last_room, first_room)
			if not closest_pair.is_empty():
				var tile1: DungeonTile = closest_pair[0]
				var tile2: DungeonTile = closest_pair[1]
				
				# Create tunnel between the two tiles
				var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, last_room)
				tiles_spawned += tunnel_tiles.size()
				
				# Await frame every 100 tiles
				if tiles_spawned >= 100:
					tiles_spawned = 0
					await get_tree().process_frame
	
	# Create extra tunnels based on rooms_indexes_to_make_extra_tunnels_to
	for room_index in rooms_resources.size():
		var room: ResourceDungeonRoom = rooms_resources[room_index]
		
		if not spawned_room_tiles.has(room) or spawned_room_tiles[room].is_empty():
			continue
		
		# Check if this room has extra tunnel connections specified
		if room.rooms_indexes_to_make_extra_tunnels_to.is_empty():
			continue
		
		# Create tunnels to each specified room index
		for target_room_index in room.rooms_indexes_to_make_extra_tunnels_to:
			# Validate target room index
			if target_room_index < 0 or target_room_index >= rooms_resources.size():
				continue
			
			# Skip if trying to connect to itself
			if target_room_index == room_index:
				continue
			
			var target_room: ResourceDungeonRoom = rooms_resources[target_room_index]
			
			if not spawned_room_tiles.has(target_room) or spawned_room_tiles[target_room].is_empty():
				continue
			
			# Find closest tiles between the two rooms
			var closest_pair = _find_closest_tiles_between_rooms(room, target_room)
			if closest_pair.is_empty():
				continue
			
			var tile1: DungeonTile = closest_pair[0]
			var tile2: DungeonTile = closest_pair[1]
			
			# Create tunnel between the two tiles
			var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, room)
			tiles_spawned += tunnel_tiles.size()
			
			# Await frame every 100 tiles
			if tiles_spawned >= 100:
				tiles_spawned = 0
				await get_tree().process_frame


func _find_closest_tiles_between_rooms(room1: ResourceDungeonRoom, room2: ResourceDungeonRoom) -> Array:
	# Find the two closest tiles between room1 and room2
	if not spawned_room_tiles.has(room1) or not spawned_room_tiles.has(room2):
		return []
	
	var tiles1: Array = spawned_room_tiles[room1]
	var tiles2: Array = spawned_room_tiles[room2]
	
	if tiles1.is_empty() or tiles2.is_empty():
		return []
	
	var closest_distance: float = INF
	var closest_tile1: DungeonTile = null
	var closest_tile2: DungeonTile = null
	
	# Check all pairs of tiles
	for tile1 in tiles1:
		for tile2 in tiles2:
			var distance: float = (tile1.coord - tile2.coord).length()
			if distance < closest_distance:
				closest_distance = distance
				closest_tile1 = tile1
				closest_tile2 = tile2
	
	if closest_tile1 == null or closest_tile2 == null:
		return []
	
	return [closest_tile1, closest_tile2]

func _create_tunnel_between_tiles(start_coord: Vector3i, end_coord: Vector3i, room: ResourceDungeonRoom) -> Array:
	# Create a tunnel path between two coordinates
	var tunnel_tiles: Array[DungeonTile] = []
	var current_coord: Vector3i = start_coord
	var last_step_was_vertical: bool = false
	var horizontal_steps_since_vertical: int = 0
	var last_horizontal_direction: Vector3i = Vector3i(1, 0, 0)  # Default to X+ direction
	var max_iterations: int = 10000  # Safety limit
	var iteration: int = 0
	
	while current_coord != end_coord and iteration < max_iterations:
		iteration += 1
		var offset: Vector3i = end_coord - current_coord
		
		# Determine next step direction
		var next_coord: Vector3i = current_coord
		var can_move_vertically: bool = not last_step_was_vertical and horizontal_steps_since_vertical >= 2
		var is_vertical_step: bool = false
		
		# Priority: move vertically if allowed and needed, otherwise move horizontally
		if can_move_vertically and offset.y != 0:
			# Move vertically - will spawn stairs
			var y_step: int = 1 if offset.y > 0 else -1
			next_coord = Vector3i(current_coord.x, current_coord.y + y_step, current_coord.z)
			last_step_was_vertical = true
			horizontal_steps_since_vertical = 0
			is_vertical_step = true
		else:
			# Move horizontally - prioritize the axis with the largest difference
			if abs(offset.x) >= abs(offset.z):
				# Move in X direction
				if offset.x > 0:
					next_coord = Vector3i(current_coord.x + 1, current_coord.y, current_coord.z)
					last_horizontal_direction = Vector3i(1, 0, 0)
				elif offset.x < 0:
					next_coord = Vector3i(current_coord.x - 1, current_coord.y, current_coord.z)
					last_horizontal_direction = Vector3i(-1, 0, 0)
				else:
					# X is done, move in Z direction
					if offset.z > 0:
						next_coord = Vector3i(current_coord.x, current_coord.y, current_coord.z + 1)
						last_horizontal_direction = Vector3i(0, 0, 1)
					elif offset.z < 0:
						next_coord = Vector3i(current_coord.x, current_coord.y, current_coord.z - 1)
						last_horizontal_direction = Vector3i(0, 0, -1)
			else:
				# Move in Z direction
				if offset.z > 0:
					next_coord = Vector3i(current_coord.x, current_coord.y, current_coord.z + 1)
					last_horizontal_direction = Vector3i(0, 0, 1)
				elif offset.z < 0:
					next_coord = Vector3i(current_coord.x, current_coord.y, current_coord.z - 1)
					last_horizontal_direction = Vector3i(0, 0, -1)
				else:
					# Z is done, move in X direction
					if offset.x > 0:
						next_coord = Vector3i(current_coord.x + 1, current_coord.y, current_coord.z)
						last_horizontal_direction = Vector3i(1, 0, 0)
					elif offset.x < 0:
						next_coord = Vector3i(current_coord.x - 1, current_coord.y, current_coord.z)
						last_horizontal_direction = Vector3i(-1, 0, 0)
			
			last_step_was_vertical = false
			horizontal_steps_since_vertical += 1
		
		# Spawn tile or stairs based on step type
		if is_vertical_step:
			# Spawn two stairs side by side along the tunnel's movement direction
			# Place stairs along the horizontal movement direction (not perpendicular)
			var stair_dir: Vector3i = last_horizontal_direction
			
			# If no horizontal direction yet (first step is vertical), default to X direction
			if stair_dir == Vector3i.ZERO:
				stair_dir = Vector3i(1, 0, 0)
			
			# Spawn two stairs side by side along the movement direction
			var stair1_coord: Vector3i = Vector3i(
				current_coord.x - stair_dir.x,
				current_coord.y,
				current_coord.z - stair_dir.z
			)
			var stair2_coord: Vector3i = Vector3i(
				current_coord.x + stair_dir.x,
				current_coord.y,
				current_coord.z + stair_dir.z
			)
			
			# Spawn stairs at both positions
			if _is_coord_free(stair1_coord):
				_spawn_stairs_at_coord(room, stair1_coord)
			if _is_coord_free(stair2_coord):
				_spawn_stairs_at_coord(room, stair2_coord)
			
			# Also spawn regular tile at the destination level
			if _is_coord_free(next_coord):
				_spawn_tile_at_coord(room, next_coord)
				var new_tile = _get_tile_at_coord(next_coord)
				if new_tile != null:
					tunnel_tiles.append(new_tile)
		else:
			# Spawn regular tile for horizontal movement
			if _is_coord_free(next_coord):
				_spawn_tile_at_coord(room, next_coord)
				var new_tile = _get_tile_at_coord(next_coord)
				if new_tile != null:
					tunnel_tiles.append(new_tile)
		
		current_coord = next_coord
	
	return tunnel_tiles

func _spawn_stairs_at_coord(room: ResourceDungeonRoom, coord: Vector3i):
	# Spawn stairs at the specified coordinate
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	var stairs = STAIRS_1.instantiate()
	stairs.position = world_position
	dungeon_tiles.add_child(stairs)
	stairs.owner = get_tree().edited_scene_root
