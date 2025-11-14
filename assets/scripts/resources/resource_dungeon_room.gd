extends Resource
class_name ResourceDungeonRoom

@export var base_room_height : int = 0
@export var target_tiles_amount : int = 10
@export_range(0.0001, 0.999) var walker_change_floor_height_chance : float = 0.05
@export var mirror_x : bool = false
@export var mirror_z : bool = false
@export var default_vertical_wall_tiles_amount : int = 1
@export var rooms_indexes_to_make_extra_tunnels_to : Array[int]

@export var props_to_spawn_amount : int = 10
@export var props_by_weight : Dictionary[StringName, float] # prop path, drop weight
