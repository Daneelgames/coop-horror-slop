@tool
extends Node3D
class_name DungeonTile

@export var coord: Vector3i
@onready var floor: Node3D = %Floor
@onready var ceiling: Node3D = %Ceiling
@onready var wall_f: Node3D = %WallF
@onready var wall_r: Node3D = %WallR
@onready var wall_b: Node3D = %WallB
@onready var wall_l: Node3D = %WallL
@onready var torch_point_right: Node3D = %TorchPointRight
@onready var torch_point_back: Node3D = %TorchPointBack
@onready var torch_point_left: Node3D = %TorchPointLeft
@onready var torch_point_front: Node3D = %TorchPointFront

const FLOOR_PATH = "res://assets/prefabs/environment/dungeon_walls/floor_1.tscn"
var is_dead_end = false
var master_dungeon: LevelGenerator

func spawn_floor():
	var new_node = Node3D.new()
	add_child(new_node)
	new_node.position = Vector3.ZERO
	new_node.rotation_degrees = Vector3.ZERO
	new_node.name = 'Floor'
	await get_tree().process_frame
	
	floor = new_node
	var new_floor = load(FLOOR_PATH).instantiate()
	floor.add_child(new_floor)
	new_floor.position = Vector3(2, 0, -2)
	new_floor.rotation_degrees = Vector3(0, 0, 0)
	pass

func configure_tile_based_on_neighbours(neighbor_tiles: Array[DungeonTile], ask_neighbor_to_reconfigure = false, force_spawn_floor = false):
	# should check every direction - top for ceiling, bottom for floor, and walls
	# no floor or ceiling or wall should be present between two neighboring tiles
	is_dead_end = false
	var walls_amount = 4
	
	for neighbor in neighbor_tiles:
		var offset: Vector3i = neighbor.coord - coord
		var cleared = false
		# Check vertical neighbors (ceiling/floor) - only exact Y difference
		if offset == Vector3i(0, 1, 0):
			# Neighbor above - destroy ceiling
			if is_instance_valid(ceiling):
				ceiling.queue_free()
			cleared = true
		elif offset == Vector3i(0, -1, 0):
			# Neighbor below - destroy floor
			if is_instance_valid(floor):
				floor.queue_free()
			cleared = true
		
		# Check horizontal neighbors (walls) - only if on same Y level
		elif offset.y == 0:
			if offset == Vector3i(0, 0, -1):
				# Neighbor forward (Z+) - destroy forward wall
				if is_instance_valid(wall_f):
					wall_f.queue_free()
				cleared = true
				walls_amount -= 1
			elif offset == Vector3i(0, 0, 1):
				# Neighbor back (Z-) - destroy back wall
				if is_instance_valid(wall_b):
					wall_b.queue_free()
				cleared = true
				walls_amount -= 1
			elif offset == Vector3i(1, 0, 0):
				# Neighbor right (X+) - destroy right wall
				if is_instance_valid(wall_r):
					wall_r.queue_free()
				cleared = true
				walls_amount -= 1
			elif offset == Vector3i(-1, 0, 0):
				# Neighbor left (X-) - destroy left wall
				if is_instance_valid(wall_l):
					wall_l.queue_free()
				cleared = true
				walls_amount -= 1
		if cleared and ask_neighbor_to_reconfigure:
			neighbor.configure_tile_based_on_neighbours(master_dungeon._get_neighbor_tiles(neighbor))

	if walls_amount == 3:
		is_dead_end = true
	if force_spawn_floor and is_instance_valid(floor) == false:
		spawn_floor()
		

func configure_tile_based_on_neighbours_with_room_check(neighbor_tiles: Array[DungeonTile], room_assignment: Dictionary[DungeonTile, ResourceDungeonRoom], doors_coords: Dictionary[String, Node] = {}):
	# should check every direction - top for ceiling, bottom for floor, and walls
	# no floor or ceiling or wall should be present between two neighboring tiles
	# BUT: if tiles belong to different rooms, walls should remain UNLESS there's a door between them
	is_dead_end = false
	var walls_amount = 4

	var current_tile_room: ResourceDungeonRoom = room_assignment.get(self, null)

	for neighbor in neighbor_tiles:
		var neighbor_room: ResourceDungeonRoom = room_assignment.get(neighbor, null)
		var offset: Vector3i = neighbor.coord - coord

		# Check if there's a door between these specific tiles (only for horizontal connections)
		var has_door_between: bool = false
		if offset.y == 0:
			# Create pair key (sorted to match how doors are stored)
			var coord1_str = "%d_%d_%d" % [min(coord.x, neighbor.coord.x), min(coord.y, neighbor.coord.y), min(coord.z, neighbor.coord.z)]
			var coord2_str = "%d_%d_%d" % [max(coord.x, neighbor.coord.x), max(coord.y, neighbor.coord.y), max(coord.z, neighbor.coord.z)]
			var pair_key = coord1_str + "-" + coord2_str
			has_door_between = doors_coords.has(pair_key)
			
		var connecting_same_room = false
		if current_tile_room == neighbor_room:
			connecting_same_room = true
		var connecting_room_with_tunnel = false

		if master_dungeon is MultistoryBuildingDungeon:
			if neighbor_room == master_dungeon.tunnel_room and current_tile_room != master_dungeon.tunnel_room:
				connecting_room_with_tunnel = true
			elif current_tile_room == master_dungeon.tunnel_room and neighbor_room != master_dungeon.tunnel_room:
				connecting_room_with_tunnel = true
				
		# If tiles belong to different rooms AND there's no door between them, don't remove walls
		if current_tile_room != neighbor_room and not has_door_between:
			if master_dungeon is MultistoryBuildingDungeon:
				if neighbor_room != master_dungeon.tunnel_room:
					continue
		if connecting_room_with_tunnel == false and connecting_same_room == false:
			continue

		# Remove walls/floors/ceilings as usual
		if offset == Vector3i(0, 1, 0):
			# Neighbor above - destroy ceiling
			if is_instance_valid(ceiling):
				ceiling.queue_free()
		elif offset == Vector3i(0, -1, 0):
			# Neighbor below - destroy floor
			if is_instance_valid(floor):
				floor.queue_free()

		# Check horizontal neighbors (walls) - only if on same Y level
		elif offset.y == 0:
			if offset == Vector3i(0, 0, -1):
				# Neighbor forward (Z+) - destroy forward wall
				walls_amount -= 1
				if is_instance_valid(wall_f):
					wall_f.queue_free()
			elif offset == Vector3i(0, 0, 1):
				# Neighbor back (Z-) - destroy back wall
				walls_amount -= 1
				if is_instance_valid(wall_b):
					wall_b.queue_free()
			elif offset == Vector3i(1, 0, 0):
				# Neighbor right (X+) - destroy right wall
				walls_amount -= 1
				if is_instance_valid(wall_r):
					wall_r.queue_free()
			elif offset == Vector3i(-1, 0, 0):
				# Neighbor left (X-) - destroy left wall
				walls_amount -= 1
				if is_instance_valid(wall_l):
					wall_l.queue_free()

	if walls_amount == 3:
		is_dead_end = true


func spawn_wall_torch():
	# Don't spawn in editor
	if Engine.is_editor_hint():
		return
	
	# Only server spawns
	if not multiplayer.is_server():
		return
	
	# Ensure GameManager and spawner are available
	if not is_instance_valid(GameManager) or not is_instance_valid(GameManager._game_spawner):
		return
	
	# Collect valid walls with their torch points
	# Structure: [{wall: Node3D, torch_point: Node3D, direction: String}]
	var valid_walls: Array[Dictionary] = []
	
	if is_instance_valid(wall_f) and not wall_f.is_queued_for_deletion():
		if is_instance_valid(torch_point_front):
			valid_walls.append({"wall": wall_f, "torch_point": torch_point_front, "direction": "front"})
	
	if is_instance_valid(wall_r) and not wall_r.is_queued_for_deletion():
		if is_instance_valid(torch_point_right):
			valid_walls.append({"wall": wall_r, "torch_point": torch_point_right, "direction": "right"})
	
	if is_instance_valid(wall_b) and not wall_b.is_queued_for_deletion():
		if is_instance_valid(torch_point_back):
			valid_walls.append({"wall": wall_b, "torch_point": torch_point_back, "direction": "back"})
	
	if is_instance_valid(wall_l) and not wall_l.is_queued_for_deletion():
		if is_instance_valid(torch_point_left):
			valid_walls.append({"wall": wall_l, "torch_point": torch_point_left, "direction": "left"})
	
	# No valid walls with torch points
	if valid_walls.is_empty():
		return
	
	# Choose random wall using master_dungeon's seeded RNG if available
	var selected_wall: Dictionary
	if is_instance_valid(master_dungeon) and master_dungeon.has_method("_get_rng"):
		var rng = master_dungeon._get_rng()
		selected_wall = valid_walls[rng.randi() % valid_walls.size()]
	elif is_instance_valid(master_dungeon) and master_dungeon.get("rng") != null:
		var rng = master_dungeon.rng
		selected_wall = valid_walls[rng.randi() % valid_walls.size()]
	else:
		# Fallback to random
		selected_wall = valid_walls[randi() % valid_walls.size()]
	
	var torch_point: Node3D = selected_wall.torch_point
	
	# Spawn torch using GameManager's spawner for network synchronization
	var torch_path = "res://assets/prefabs/weapons/weapon_torch_p_f.tscn"
	var spawn_data = {"type": "pickup", "path": torch_path}
	var torch = GameManager._game_spawner.spawn(spawn_data)
	
	if torch != null:
		# Set torch's global position and rotation to match torch_point
		torch.global_position = torch_point.global_position
		torch.global_rotation = torch_point.global_rotation
		torch.set_multiplayer_authority(1)
