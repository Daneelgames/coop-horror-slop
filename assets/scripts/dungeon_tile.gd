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
@onready var tmp: Node3D = %TMP

var is_dead_end = false
var master_dungeon: LevelGenerator

func configure_tile_based_on_neighbours(neighbor_tiles: Array[DungeonTile], ask_neighbor_to_reconfigure = false):
	# should check every direction - top for ceiling, bottom for floor, and walls
	# no floor or ceiling or wall should be present between two neighboring tiles
	if tmp:
		tmp.queue_free()
		tmp = null
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


func configure_tile_based_on_neighbours_with_room_check(neighbor_tiles: Array[DungeonTile], room_assignment: Dictionary[DungeonTile, ResourceDungeonRoom], doors_coords: Dictionary[String, Node] = {}):
	# should check every direction - top for ceiling, bottom for floor, and walls
	# no floor or ceiling or wall should be present between two neighboring tiles
	# BUT: if tiles belong to different rooms, walls should remain UNLESS there's a door between them
	if tmp:
		tmp.queue_free()
		tmp = null

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
