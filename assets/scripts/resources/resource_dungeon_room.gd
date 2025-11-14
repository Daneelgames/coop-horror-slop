extends Resource
class_name ResourceDungeonRoom

@export var base_room_height : int = 0
@export var target_tiles_amount : int = 10
@export_range(0.0001, 0.999) var walker_change_floor_height_chance : float = 0.05
@export var mirror_x : bool = false
@export var mirror_z : bool = false
@export var default_vertical_wall_tiles_amount : int = 1
