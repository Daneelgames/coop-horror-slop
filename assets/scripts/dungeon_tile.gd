@tool
extends Node3D
class_name DungeonTile

@export var coord : Vector3i
@onready var floor: Node3D = %Floor
@onready var ceiling: Node3D = %Ceiling
@onready var wall_f: Node3D = %WallF
@onready var wall_r: Node3D = %WallR
@onready var wall_b: Node3D = %WallB
@onready var wall_l: Node3D = %WallL
@onready var tmp: Node3D = %TMP

func configure_tile_based_on_neighbours(neighbor_tiles : Array[DungeonTile]):
	# should check every direction - top for ceiling, bottom for floor, and walls
	# no floor or ceiling or wall should be present between two neighboring tiles
	tmp.queue_free()
	
	
	for neighbor in neighbor_tiles:
		var offset: Vector3i = neighbor.coord - coord
		
		# Check vertical neighbors (ceiling/floor) - only exact Y difference
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
				if is_instance_valid(wall_f):
					wall_f.queue_free()
			elif offset == Vector3i(0, 0, 1):
				# Neighbor back (Z-) - destroy back wall
				if is_instance_valid(wall_b):
					wall_b.queue_free()
			elif offset == Vector3i(1, 0, 0):
				# Neighbor right (X+) - destroy right wall
				if is_instance_valid(wall_r):
					wall_r.queue_free()
			elif offset == Vector3i(-1, 0, 0):
				# Neighbor left (X-) - destroy left wall
				if is_instance_valid(wall_l):
					wall_l.queue_free() 
