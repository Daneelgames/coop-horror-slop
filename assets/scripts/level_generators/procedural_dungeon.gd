@tool
extends LevelGenerator
class_name ProceduralDungeon

const DUNGEON_TILE = preload("uid://cefhqgvoa83r2")
const STAIRS_1 = preload("res://assets/prefabs/environment/dungeon_walls/stairs_1.tscn")
const AI_CHARACTER = preload("res://addons/fpc/ai_character.tscn")
#const TILE_SIZE : Vector3i = Vector3i(4,4,4) # tile's origin is at its bottom center
const TILE_SIZE : Vector3i = Vector3i(4,2,4) # tile's origin is at its bottom center
enum ROOM_SPAWN_TYPE {RANDOM, CIRCLE}
@export var room_spawn_type : ROOM_SPAWN_TYPE
@export var rooms_circle_spawn_radius_in_tiles : int = 10
@export var min_distance_between_rooms_in_tiles : int = 10
@export var max_distance_between_rooms_in_tiles : int = 20
@export var rooms_resources : Array[ResourceDungeonRoom]
@export var spawned_room_tiles : Dictionary[ResourceDungeonRoom, Array] # value is Array[DungeonTile]
@export var all_spawned_tiles : Dictionary[DungeonTile, ResourceDungeonRoom]
@export var spawned_stairs_coords : Dictionary[Vector3i, Node] # coord, stairs node
@export var tunnel_tiles_coords : Dictionary[Vector3i, DungeonTile] # coord, tile
@export var debug_tile_islands : bool = false
@export var mobs_amount_to_spawn = 30
@export var pickup_items_to_spawn_dict : Dictionary[ResourceWeapon, int] # item, amount

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
func clear():
	if is_instance_valid(dungeon_tiles):
		for child in dungeon_tiles.get_children():
			child.queue_free()
	spawned_room_tiles.clear()
	all_spawned_tiles.clear()
	spawned_stairs_coords.clear()
	tunnel_tiles_coords.clear()

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
	await get_tree().process_frame
	await collect_tile_islands()
	await connect_islands_with_stairs()
	await spawn_props()
	
	await get_tree().process_frame
	level_generated.emit()
	await get_tree().process_frame
	
	await spawn_mobs()
	await spawn_pickups()
	

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
		var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, room1, room2)
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
				var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, last_room, first_room)
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
			var tunnel_tiles = await _create_tunnel_between_tiles(tile1.coord, tile2.coord, room, target_room)
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
	
	# Also track farthest pair as fallback
	var farthest_horizontal_distance: float = -1
	var farthest_tile1: DungeonTile = null
	var farthest_tile2: DungeonTile = null
	
	# Check all pairs of tiles
	for tile1 in tiles1:
		for tile2 in tiles2:
			# Calculate horizontal distance (ignoring Y)
			var horizontal_offset: Vector3i = Vector3i(
				tile1.coord.x - tile2.coord.x,
				0,
				tile1.coord.z - tile2.coord.z
			)
			var horizontal_distance: float = horizontal_offset.length()
			
			# Track farthest pair as fallback
			if horizontal_distance > farthest_horizontal_distance:
				farthest_horizontal_distance = horizontal_distance
				farthest_tile1 = tile1
				farthest_tile2 = tile2
			
			# Only consider pairs with horizontal distance of 3 or more tiles
			if horizontal_distance >= 3.0:
				var distance: float = (tile1.coord - tile2.coord).length()
				if distance < closest_distance:
					closest_distance = distance
					closest_tile1 = tile1
					closest_tile2 = tile2
	
	# If no pairs meet minimum distance, use farthest pair as fallback
	if closest_tile1 == null or closest_tile2 == null:
		if farthest_tile1 != null and farthest_tile2 != null:
			return [farthest_tile1, farthest_tile2]
		return []
	
	return [closest_tile1, closest_tile2]

func _create_tunnel_between_tiles(start_coord: Vector3i, end_coord: Vector3i, room: ResourceDungeonRoom, target_room: ResourceDungeonRoom) -> Array:
	# Create a tunnel path between two coordinates
	var tunnel_tiles: Array[DungeonTile] = []
	var current_coord: Vector3i = start_coord
	var last_step_was_vertical: bool = false
	var horizontal_steps_since_vertical: int = 0
	var last_horizontal_direction: Vector3i = Vector3i(1, 0, 0)  # Default to X+ direction
	var max_iterations: int = 10000  # Safety limit
	var iteration: int = 0
	var target_base_y: int = target_room.base_room_height
	
	while current_coord != end_coord and iteration < max_iterations:
		iteration += 1
		var offset: Vector3i = end_coord - current_coord
		
		# Determine next step direction
		var next_coord: Vector3i = current_coord
		var can_move_vertically: bool = not last_step_was_vertical and horizontal_steps_since_vertical >= 2
		var is_vertical_step: bool = false
		
		# Priority: move vertically if allowed and needed, otherwise move horizontally
		var vertical_direction: int = 0
		
		# Check if we need to continue going down to reach target base Y height
		# But still require at least 2 horizontal steps between vertical steps
		var needs_to_go_down: bool = current_coord.y > target_base_y
		
		if needs_to_go_down and can_move_vertically:
			# Continue going down until reaching target base Y height
			# But only if we've made at least 2 horizontal steps since last vertical step
			vertical_direction = -1
			next_coord = Vector3i(current_coord.x, current_coord.y - 1, current_coord.z)
			last_step_was_vertical = true
			horizontal_steps_since_vertical = 0
			is_vertical_step = true
		elif can_move_vertically and offset.y != 0:
			# Move vertically based on offset - will spawn stairs
			var y_step: int = 1 if offset.y > 0 else -1
			vertical_direction = y_step
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
			
			# # Spawn stairs at both positions
			# if _is_coord_free(stair1_coord):
			# 	_spawn_stairs_at_coord(room, stair1_coord, last_horizontal_direction, vertical_direction)
			# if _is_coord_free(stair2_coord):
			# 	_spawn_stairs_at_coord(room, stair2_coord, last_horizontal_direction, vertical_direction)
			
			# Also spawn regular tiles at the destination level - create 2-tile-high tunnel
			# Spawn tile at base level
			if _is_coord_free(next_coord):
				_spawn_tile_at_coord(room, next_coord)
				var new_tile = _get_tile_at_coord(next_coord)
				if new_tile != null:
					tunnel_tiles.append(new_tile)
			
			# Spawn tile at level above to create 2-tile-high tunnel
			var upper_coord: Vector3i = Vector3i(next_coord.x, next_coord.y + 1, next_coord.z)
			if _is_coord_free(upper_coord):
				_spawn_tile_at_coord(room, upper_coord)
				var upper_tile = _get_tile_at_coord(upper_coord)
				if upper_tile != null:
					tunnel_tiles.append(upper_tile)
		else:
			# Spawn regular tiles for horizontal movement - create 2-tile-high tunnel
			# Spawn tile at base level
			if _is_coord_free(next_coord):
				_spawn_tile_at_coord(room, next_coord)
				var new_tile = _get_tile_at_coord(next_coord)
				if new_tile != null:
					tunnel_tiles.append(new_tile)
			
			# Spawn tile at level above to create 2-tile-high tunnel
			var upper_coord: Vector3i = Vector3i(next_coord.x, next_coord.y + 1, next_coord.z)
			if _is_coord_free(upper_coord):
				_spawn_tile_at_coord(room, upper_coord)
				var upper_tile = _get_tile_at_coord(upper_coord)
				if upper_tile != null:
					tunnel_tiles.append(upper_tile)
		
		current_coord = next_coord
	
	return tunnel_tiles

func _spawn_stairs_at_coord(room: ResourceDungeonRoom, coord: Vector3i, tunnel_direction: Vector3i = Vector3i.ZERO, vertical_direction: int = 0, island_idx_a: int = -1, island_idx_b: int = -1):
	# Spawn stairs at the specified coordinate
	var world_position: Vector3 = Vector3(
		coord.x * TILE_SIZE.x,
		coord.y * TILE_SIZE.y,
		coord.z * TILE_SIZE.z
	)
	
	# Get the tile at this coordinate for debugging
	var tile_at_coord: DungeonTile = _get_tile_at_coord(coord)
	var tile_has_floor: bool = false
	var tile_position: Vector3 = Vector3.ZERO
	
	if tile_at_coord != null:
		tile_position = tile_at_coord.position
		tile_has_floor = is_instance_valid(tile_at_coord.floor)
		print("DEBUG _spawn_stairs_at_coord: Tile at coord ", coord, " - position: ", tile_position, ", has_floor: ", tile_has_floor)
	else:
		print("DEBUG _spawn_stairs_at_coord: WARNING - No tile found at coord ", coord)
	
	# Compare positions
	var position_difference: Vector3 = world_position - tile_position
	print("DEBUG _spawn_stairs_at_coord: Stair world_position: ", world_position, ", tile_position: ", tile_position, ", difference: ", position_difference)
	
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
	
	print('DEBUG _spawn_stairs_at_coord: tunnel_direction: %s, vertical_direction: %s, rotation_y: %.2f' % [tunnel_direction, vertical_direction, rad_to_deg(rotation_y)])

	
	
	stairs.position = world_position
	dungeon_tiles.add_child(stairs)
	
	# Cache stairs coord
	spawned_stairs_coords[coord] = stairs
	
	# Build stairs name with island indexes
	var stairs_name: String = str(tunnel_direction) + "_" + str(vertical_direction)
	if island_idx_a >= 0 and island_idx_b >= 0:
		stairs_name = "islands_" + str(island_idx_a) + "_" + str(island_idx_b) + "_" + stairs_name
	stairs.name += "_" + stairs_name
	stairs.owner = get_tree().edited_scene_root
	
	# Final verification after spawning
	print("DEBUG _spawn_stairs_at_coord: Stair spawned at ", stairs.position, " for coord ", coord, ", tile has floor: ", tile_has_floor, ", connects islands ", island_idx_a, " and ", island_idx_b)

@export var tiles_coords_islands: Dictionary[int, Array] #island index, array of tile coords Vector3i

func collect_tile_islands():
	# collect tiles into local disconnected tiles list
	# use flood fill algorithm to flood islands from each tile from disconnected tiles list
	# only tiles that have floor can go into islands
	# if tiles are neighboring with each other in horizontal plane, have the same y coord and both have floors - they both should be set to single island
	# debug amount of found islands in tiles_coords_islands
	
	tiles_coords_islands.clear()
	
	# First, collect all tiles that have floors, grouped by Y coordinate
	var tiles_by_y: Dictionary[int, Array] = {}
	var tiles_with_floors_count: int = 0
	var tiles_without_floors_count: int = 0
	
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		
		# Check if tile has a floor (floor node exists and is valid)
		if is_instance_valid(tile.floor):
			var y_coord: int = tile.coord.y
			if not tiles_by_y.has(y_coord):
				tiles_by_y[y_coord] = []
			tiles_by_y[y_coord].append(tile)
			tiles_with_floors_count += 1
		else:
			tiles_without_floors_count += 1
	
	print("DEBUG collect_tile_islands: Tiles with floors: ", tiles_with_floors_count, ", without floors: ", tiles_without_floors_count)
	
	# Process each Y level separately
	var island_index: int = 0
	var visited_tiles: Dictionary[DungeonTile, bool] = {}
	
	for y_coord in tiles_by_y.keys():
		var tiles_at_y: Array = tiles_by_y[y_coord]
		
		# Flood fill for each unvisited tile at this Y level
		for start_tile in tiles_at_y:
			if visited_tiles.has(start_tile):
				continue
			
			# Verify start tile still has floor before starting flood fill
			if not is_instance_valid(start_tile.floor):
				print("DEBUG collect_tile_islands: Skipping start_tile at ", start_tile.coord, " - no floor")
				continue
			
			# Start a new island with flood fill
			var island_tiles: Array[Vector3i] = []
			var queue: Array[DungeonTile] = [start_tile]
			visited_tiles[start_tile] = true
			var tiles_added_to_island: int = 0
			var tiles_skipped_no_floor: int = 0
			
			# Horizontal neighbor offsets (only X and Z, Y stays 0)
			var horizontal_offsets: Array[Vector3i] = [
				Vector3i(1, 0, 0),   # Right
				Vector3i(-1, 0, 0),  # Left
				Vector3i(0, 0, 1),   # Forward
				Vector3i(0, 0, -1)   # Backward
			]
			
			# BFS flood fill
			while not queue.is_empty():
				var current_tile: DungeonTile = queue.pop_front()
				
				# Verify tile still has floor before adding to island
				if not is_instance_valid(current_tile.floor):
					tiles_skipped_no_floor += 1
					print("DEBUG collect_tile_islands: Skipping tile at ", current_tile.coord, " - no floor during flood fill")
					continue
				
				island_tiles.append(current_tile.coord)
				tiles_added_to_island += 1
				
				# Add Label3D showing island index (if debug enabled)
				if debug_tile_islands:
					var label: Label3D = Label3D.new()
					label.text = str(island_index)
					label.no_depth_test = true
					label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
					label.position = Vector3(0, 0, 0)  # Position above the tile
					label.pixel_size = 0.01
					current_tile.add_child(label)
					label.owner = get_tree().edited_scene_root
				
				# Check horizontal neighbors
				for offset in horizontal_offsets:
					var neighbor_coord: Vector3i = current_tile.coord + offset
					var neighbor_tile: DungeonTile = _get_tile_at_coord(neighbor_coord)
					
					# Check if neighbor exists, has floor, same Y level, and not visited
					if neighbor_tile != null and \
					   is_instance_valid(neighbor_tile.floor) and \
					   neighbor_tile.coord.y == y_coord and \
					   not visited_tiles.has(neighbor_tile):
						visited_tiles[neighbor_tile] = true
						queue.append(neighbor_tile)
			
			# Store this island
			if not island_tiles.is_empty():
				tiles_coords_islands[island_index] = island_tiles
				print("DEBUG collect_tile_islands: Created island ", island_index, " at Y=", y_coord, " with ", tiles_added_to_island, " tiles (skipped ", tiles_skipped_no_floor, " tiles without floors)")
				island_index += 1
	
	# Debug: print amount of found islands
	print("DEBUG: Found ", tiles_coords_islands.size(), " tile islands")
	for island_idx in tiles_coords_islands.keys():
		print("  Island ", island_idx, ": ", tiles_coords_islands[island_idx].size(), " tiles")
	
	# Check for duplicate coordinates across islands
	var all_coords: Dictionary[Vector3i, Array] = {}
	for island_idx in tiles_coords_islands.keys():
		for coord in tiles_coords_islands[island_idx]:
			if not all_coords.has(coord):
				all_coords[coord] = []
			all_coords[coord].append(island_idx)
	
	var duplicate_count: int = 0
	for coord in all_coords.keys():
		if all_coords[coord].size() > 1:
			duplicate_count += 1
			print("DEBUG collect_tile_islands: WARNING - Coordinate ", coord, " appears in ", all_coords[coord].size(), " islands: ", all_coords[coord])
	
	if duplicate_count > 0:
		print("DEBUG collect_tile_islands: ERROR - Found ", duplicate_count, " coordinates that appear in multiple islands!")
	else:
		print("DEBUG collect_tile_islands: OK - No duplicate coordinates found across islands")

func connect_islands_with_stairs():
	print("DEBUG connect_islands_with_stairs: Starting, total islands: ", tiles_coords_islands.size())
	var total_connections_attempted: int = 0
	var total_connections_found: int = 0
	var total_stairs_spawned: int = 0
	var spawned_stair_coords: Dictionary[Vector3i, bool] = {}  # Track where stairs have been spawned
	var connected_island_pairs: Dictionary[String, bool] = {}  # Track which island pairs have been connected
	
	for island_idx_a in tiles_coords_islands.keys():
		var island_height_a = tiles_coords_islands[island_idx_a][0].y
		for island_idx_b in tiles_coords_islands.keys():
			if island_idx_a == island_idx_b:
				continue
			var island_height_b = tiles_coords_islands[island_idx_b][0].y
			if island_height_a == island_height_b:
				continue
			
			# Only connect islands on adjacent floors (Y difference must be exactly 1)
			var height_difference: int = abs(island_height_a - island_height_b)
			if height_difference != 1:
				print("DEBUG connect_islands_with_stairs: SKIP - Island ", island_idx_a, " (Y=", island_height_a, ") and island ", island_idx_b, " (Y=", island_height_b, ") are not on adjacent floors (difference: ", height_difference, ")")
				continue
			
			# Create a unique key for this island pair (always use smaller index first to avoid duplicates)
			var pair_key: String
			if island_idx_a < island_idx_b:
				pair_key = str(island_idx_a) + "_" + str(island_idx_b)
			else:
				pair_key = str(island_idx_b) + "_" + str(island_idx_a)
			
			# Skip if this island pair has already been connected
			if connected_island_pairs.has(pair_key):
				print("DEBUG connect_islands_with_stairs: SKIP - Island pair ", pair_key, " already connected")
				continue
			
			print("DEBUG connect_islands_with_stairs: Checking island ", island_idx_a, " (Y=", island_height_a, ", ", tiles_coords_islands[island_idx_a].size(), " tiles) vs island ", island_idx_b, " (Y=", island_height_b, ", ", tiles_coords_islands[island_idx_b].size(), " tiles)")
			
			tiles_coords_islands[island_idx_a].shuffle()

			# loop over tiles coords in island_idx_a
			# loop over tiles coords in island_idx_b
			# if tiles are neighboring with each other in horizontal plane - spawn stairs prefab in center of the bottom one tile
			
			var found_connection: bool = false
			var adjacent_pairs_checked: int = 0
			
			# Loop over tiles coords in island_idx_a
			for coord_a in tiles_coords_islands[island_idx_a]:
				if found_connection:
					break
				
				# Loop over tiles coords in island_idx_b
				for coord_b in tiles_coords_islands[island_idx_b]:
					adjacent_pairs_checked += 1
					total_connections_attempted += 1
					
					# Verify coordinates belong to different islands
					# Check if both coordinates belong to the same island (across all islands)
					var same_island: bool = false
					var found_in_island_idx: int = -1
					for island_idx in tiles_coords_islands.keys():
						var island_coords: Array = tiles_coords_islands[island_idx]
						if coord_a in island_coords and coord_b in island_coords:
							same_island = true
							found_in_island_idx = island_idx
							break
					
					if same_island:
						print("DEBUG connect_islands_with_stairs: SKIP - coord_a ", coord_a, " and coord_b ", coord_b, " both in same island ", found_in_island_idx)
						continue  # Skip if coordinates belong to the same island
					
					# Check if tiles are neighboring in horizontal plane (adjacent X or Z, different Y)
					var horizontal_distance: Vector3i = Vector3i(
						coord_a.x - coord_b.x,
						0,
						coord_a.z - coord_b.z
					)
					
					# Check if horizontally adjacent (manhattan distance of 1 in horizontal plane)
					var is_horizontally_adjacent: bool = (abs(horizontal_distance.x) == 1 and horizontal_distance.z == 0) or \
														(abs(horizontal_distance.z) == 1 and horizontal_distance.x == 0)
					
					if is_horizontally_adjacent:
						total_connections_found += 1
						print("DEBUG connect_islands_with_stairs: Found adjacent pair - coord_a ", coord_a, " coord_b ", coord_b)
						
						# Get tiles at both coordinates and verify they have floors
						var tile_a: DungeonTile = _get_tile_at_coord(coord_a)
						var tile_b: DungeonTile = _get_tile_at_coord(coord_b)
						
						# Only spawn stairs if both tiles exist and have floors
						if tile_a == null:
							print("DEBUG connect_islands_with_stairs: SKIP - tile_a is null at ", coord_a)
							continue
						if tile_b == null:
							print("DEBUG connect_islands_with_stairs: SKIP - tile_b is null at ", coord_b)
							continue
						
						var tile_a_has_floor: bool = is_instance_valid(tile_a.floor)
						var tile_b_has_floor: bool = is_instance_valid(tile_b.floor)
						
						if not tile_a_has_floor:
							print("DEBUG connect_islands_with_stairs: SKIP - tile_a at ", coord_a, " has no floor")
							continue
						if not tile_b_has_floor:
							print("DEBUG connect_islands_with_stairs: SKIP - tile_b at ", coord_b, " has no floor")
							continue
						
						print("DEBUG connect_islands_with_stairs: Both tiles have floors - proceeding to spawn stairs")
						
						# Determine which tile is the bottom one
						var bottom_coord: Vector3i
						var top_coord: Vector3i
						var bottom_tile: DungeonTile
						var vertical_direction: int
						var tunnel_direction: Vector3i
						
						if coord_a.y < coord_b.y:
							bottom_coord = coord_a
							top_coord = coord_b
							bottom_tile = tile_a
							vertical_direction = 1  # Going up
						else:
							bottom_coord = coord_b
							top_coord = coord_a
							bottom_tile = tile_b
							vertical_direction = -1  # Going down
						
						# Calculate tunnel direction (from bottom to top horizontally)
						tunnel_direction = Vector3i(
							sign(top_coord.x - bottom_coord.x),
							0,
							sign(top_coord.z - bottom_coord.z)
						)
						
						# Check if stairs already spawned at this coordinate
						if spawned_stair_coords.has(bottom_coord):
							print("DEBUG connect_islands_with_stairs: SKIP - stairs already spawned at ", bottom_coord)
							continue
						
						# Check if bottom tile has a ceiling - if it does, skip this pair (ceiling would block stairs)
						if bottom_tile != null:
							if is_instance_valid(bottom_tile.ceiling):
								print("DEBUG connect_islands_with_stairs: SKIP - bottom tile at ", bottom_coord, " has ceiling, would block stairs")
								continue
						
						# Get the room for the bottom tile
						if bottom_tile != null and all_spawned_tiles.has(bottom_tile):
							var room: ResourceDungeonRoom = all_spawned_tiles[bottom_tile]
							
							print("DEBUG connect_islands_with_stairs: SPAWNING STAIRS at ", bottom_coord, " (bottom), top at ", top_coord, " tunnel_dir=", tunnel_direction, " vert_dir=", vertical_direction, " connecting islands ", island_idx_a, " and ", island_idx_b)
							
							# Spawn stairs prefab in center of the bottom tile
							_spawn_stairs_at_coord(room, bottom_coord, tunnel_direction, vertical_direction, island_idx_a, island_idx_b)
							spawned_stair_coords[bottom_coord] = true  # Mark this coordinate as used
							connected_island_pairs[pair_key] = true  # Mark this island pair as connected
							total_stairs_spawned += 1
							found_connection = true
							break
						else:
							print("DEBUG connect_islands_with_stairs: SKIP - bottom_tile is null or not in all_spawned_tiles")
			
			if found_connection:
				print("DEBUG connect_islands_with_stairs: Found connection between island ", island_idx_a, " and ", island_idx_b, " (checked ", adjacent_pairs_checked, " pairs)")
			else:
				print("DEBUG connect_islands_with_stairs: No connection found between island ", island_idx_a, " and ", island_idx_b, " (checked ", adjacent_pairs_checked, " pairs)")
	
	print("DEBUG connect_islands_with_stairs: COMPLETE - Attempted: ", total_connections_attempted, ", Found adjacent: ", total_connections_found, ", Spawned stairs: ", total_stairs_spawned)

@export var tunnel_props_amount : int = 400
@export var default_props_in_tunnels : Dictionary[StringName, float] # , prop path, drop weight

func spawn_props():
	# For each resource room - spawn amount of props to spawn amount, choosing props from props by weight
	# Spawn props to random tiles with floor
	
	# Cache tunnel tiles first
	_cache_tunnel_tiles()
	
	# First, spawn props for each room
	for room in rooms_resources:
		if not spawned_room_tiles.has(room) or spawned_room_tiles[room].is_empty():
			continue
		
		# Get tiles with floors for this room (excluding tiles with stairs)
		var tiles_with_floors: Array[DungeonTile] = []
		for tile in spawned_room_tiles[room]:
			if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
				continue
			# Skip tiles that have stairs
			if spawned_stairs_coords.has(tile.coord):
				continue
			tiles_with_floors.append(tile)
		
		if tiles_with_floors.is_empty():
			continue
		
		# Check if room has props to spawn
		if room.props_to_spawn_amount <= 0 or room.props_by_weight.is_empty():
			continue
		
		# Spawn props for this room
		for i in range(room.props_to_spawn_amount):
			# Choose a random tile with floor (multiple props can occupy same tile)
			var random_tile: DungeonTile = tiles_with_floors[randi() % tiles_with_floors.size()]
			
			# Choose prop using weighted random selection
			var prop_path: StringName = _choose_weighted_prop(room.props_by_weight)
			if prop_path.is_empty():
				continue
			
			# Load and instantiate prop
			var prop_scene = load(str(prop_path))
			if prop_scene == null:
				push_warning("Failed to load prop scene: " + str(prop_path))
				continue
			
			var prop = prop_scene.instantiate()
			if prop == null:
				continue
			
			# Randomize prop position within tile bounds
			# TILE_SIZE is Vector3i(4, 2, 4) and tile's origin is at its bottom center
			# So we randomize X and Z in range [-TILE_SIZE.x/2, TILE_SIZE.x/2] = [-2, 2]
			# And Y is slightly above floor (0.1 to account for floor height)
			var random_offset_x: float = randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
			var random_offset_z: float = randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
			prop.position = random_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
			
			dungeon_tiles.add_child(prop)
			prop.owner = get_tree().edited_scene_root
			
			# Yield every 10 props to avoid frame drops
			if i % 10 == 0:
				await get_tree().process_frame
	
	# Spawn default props in tunnels (tiles that don't belong to any room)
	if not default_props_in_tunnels.is_empty() and tunnel_props_amount > 0:
		# Get tunnel tiles with floors (excluding tiles with stairs)
		var tunnel_tiles_with_floors: Array[DungeonTile] = []
		for coord in tunnel_tiles_coords.keys():
			var tile: DungeonTile = tunnel_tiles_coords[coord]
			if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
				continue
			# Skip tiles that have stairs
			if spawned_stairs_coords.has(coord):
				continue
			tunnel_tiles_with_floors.append(tile)
		
		if tunnel_tiles_with_floors.is_empty():
			return
		
		# Spawn props in tunnels using tunnel_props_amount
		var tunnel_props_to_spawn: int = min(tunnel_props_amount, tunnel_tiles_with_floors.size() * 10)  # Allow multiple props per tile
		
		for i in range(tunnel_props_to_spawn):
			# Choose a random tunnel tile with floor (multiple props can occupy same tile)
			var random_tile: DungeonTile = tunnel_tiles_with_floors[randi() % tunnel_tiles_with_floors.size()]
			
			# Choose prop using weighted random selection
			var prop_path: StringName = _choose_weighted_prop(default_props_in_tunnels)
			if prop_path.is_empty():
				continue
			
			# Load and instantiate prop
			var prop_scene = load(str(prop_path))
			if prop_scene == null:
				push_warning("Failed to load tunnel prop scene: " + str(prop_path))
				continue
			
			var prop = prop_scene.instantiate()
			if prop == null:
				continue
			
			# Randomize prop position within tile bounds
			var random_offset_x: float = randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
			var random_offset_z: float = randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
			prop.position = random_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)
			
			dungeon_tiles.add_child(prop)
			prop.owner = get_tree().edited_scene_root
			
			# Yield every 10 props
			if i % 10 == 0:
				await get_tree().process_frame

func _cache_tunnel_tiles():
	# Cache all tunnel tiles (tiles that don't belong to any room) in tunnel_tiles_coords
	tunnel_tiles_coords.clear()
	
	for tile in all_spawned_tiles.keys():
		if not is_instance_valid(tile):
			continue
		
		# Check if this tile belongs to any room
		var belongs_to_room: bool = false
		for room in rooms_resources:
			if spawned_room_tiles.has(room) and tile in spawned_room_tiles[room]:
				belongs_to_room = true
				break
		
		if not belongs_to_room:
			tunnel_tiles_coords[tile.coord] = tile

func _choose_weighted_prop(props_by_weight: Dictionary[StringName, float]) -> StringName:
	# Weighted random selection
	if props_by_weight.is_empty():
		return StringName()
	
	# Calculate total weight
	var total_weight: float = 0.0
	for weight in props_by_weight.values():
		total_weight += weight
	
	if total_weight <= 0.0:
		return StringName()
	
	# Choose random value
	var random_value: float = randf() * total_weight
	var current_weight: float = 0.0
	
	# Find which prop corresponds to the random value
	for prop_path in props_by_weight.keys():
		current_weight += props_by_weight[prop_path]
		if random_value <= current_weight:
			return prop_path
	
	# Fallback: return first prop
	return props_by_weight.keys()[0] if props_by_weight.size() > 0 else StringName()


func spawn_mobs():
	# Use mobs_amount_to_spawn to spawn mobs in random tiles with floor in tunnels and in rooms except 1st room
	# Only spawn on server in multiplayer
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if mobs_amount_to_spawn <= 0:
		return
	
	# Get game_level (NavigationRegion3D) as parent for mobs so they can use navigation
	var game_level = get_parent()
	if not is_instance_valid(game_level):
		push_warning("spawn_mobs: Could not find game_level parent")
		return
	
	# Collect tiles with floors from tunnels and rooms (except 1st room)
	var available_tiles: Array[DungeonTile] = []
	
	# Add tunnel tiles
	for coord in tunnel_tiles_coords.keys():
		var tile: DungeonTile = tunnel_tiles_coords[coord]
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(coord):
			continue
		available_tiles.append(tile)
	
	# Add room tiles (except 1st room)
	if rooms_resources.size() > 1:
		for room_index in range(1, rooms_resources.size()):
			var room: ResourceDungeonRoom = rooms_resources[room_index]
			if not spawned_room_tiles.has(room):
				continue
			
			for tile in spawned_room_tiles[room]:
				if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
					continue
				# Skip tiles that have stairs
				if spawned_stairs_coords.has(tile.coord):
					continue
				available_tiles.append(tile)
	
	if available_tiles.is_empty():
		push_warning("spawn_mobs: No available tiles found for spawning mobs")
		return
	
	# Spawn mobs
	var mobs_to_spawn: int = min(mobs_amount_to_spawn, available_tiles.size())
	for i in range(mobs_to_spawn):
		# Choose a random tile
		var random_tile: DungeonTile = available_tiles[randi() % available_tiles.size()]
		
		# Load and instantiate AI character
		var mob = AI_CHARACTER.instantiate()
		if mob == null:
			continue
		
		# Randomize mob position within tile bounds
		var random_offset_x: float = randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
		var random_offset_z: float = randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
		var mob_position = random_tile.position + Vector3(random_offset_x, 1.0, random_offset_z)  # 1 unit above floor
		mob.position = mob_position
		
		# Set home position for patrol (AiCharacter has home_position property)
		if mob is AiCharacter:
			mob.home_position = mob_position
		
		game_level.add_child(mob)
		mob.owner = get_tree().edited_scene_root
		
		# Yield every 10 mobs to avoid frame drops
		if i % 10 == 0:
			await get_tree().process_frame

func spawn_pickups():
	# Use item amount dictionary pickup_items_to_spawn_dict to spawn pickups in random tiles with floor
	# Only spawn on server in multiplayer
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if pickup_items_to_spawn_dict.is_empty():
		return
	
	# Collect all tiles with floors (from all rooms and tunnels)
	var available_tiles: Array[DungeonTile] = []
	
	# Add all room tiles
	for room in rooms_resources:
		if not spawned_room_tiles.has(room):
			continue
		for tile in spawned_room_tiles[room]:
			if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
				continue
			# Skip tiles that have stairs
			if spawned_stairs_coords.has(tile.coord):
				continue
			available_tiles.append(tile)
	
	# Add tunnel tiles
	for coord in tunnel_tiles_coords.keys():
		var tile: DungeonTile = tunnel_tiles_coords[coord]
		if not is_instance_valid(tile) or not is_instance_valid(tile.floor):
			continue
		# Skip tiles that have stairs
		if spawned_stairs_coords.has(coord):
			continue
		available_tiles.append(tile)
	
	if available_tiles.is_empty():
		push_warning("spawn_pickups: No available tiles found for spawning pickups")
		return
	
	# Spawn pickups for each item type
	var total_pickups_spawned: int = 0
	for weapon_resource in pickup_items_to_spawn_dict.keys():
		var amount: int = pickup_items_to_spawn_dict[weapon_resource]
		if amount <= 0:
			continue
		
		# Check if weapon_resource has pickup_prefab_path
		if weapon_resource.pickup_prefab_path == null or weapon_resource.pickup_prefab_path == "":
			push_warning("spawn_pickups: Weapon resource '%s' has no pickup_prefab_path" % weapon_resource.weapon_name)
			continue
		
		# Load pickup prefab
		var pickup_scene = load(str(weapon_resource.pickup_prefab_path))
		if pickup_scene == null:
			push_warning("spawn_pickups: Failed to load pickup scene: " + str(weapon_resource.pickup_prefab_path))
			continue
		
		# Spawn the specified amount of this pickup
		for i in range(amount):
			# Choose a random tile
			var random_tile: DungeonTile = available_tiles[randi() % available_tiles.size()]
			
			# Instantiate pickup
			var pickup = pickup_scene.instantiate()
			if pickup == null:
				continue
			
			# Set weapon_resource on the pickup (Interactive class)
			if pickup is Interactive:
				pickup.weapon_resource = weapon_resource.duplicate()
			
			# Randomize pickup position within tile bounds
			var random_offset_x: float = randf_range(-TILE_SIZE.x / 2.0, TILE_SIZE.x / 2.0)
			var random_offset_z: float = randf_range(-TILE_SIZE.z / 2.0, TILE_SIZE.z / 2.0)
			pickup.position = random_tile.position + Vector3(random_offset_x, 0.1, random_offset_z)  # Slightly above floor
			
			dungeon_tiles.add_child(pickup)
			pickup.owner = get_tree().edited_scene_root
			
			total_pickups_spawned += 1
			
			# Yield every 10 pickups to avoid frame drops
			if total_pickups_spawned % 10 == 0:
				await get_tree().process_frame
