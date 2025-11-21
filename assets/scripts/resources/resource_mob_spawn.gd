extends Resource
class_name ResourceMobSpawn

@export var mob_prefab_path : StringName
@export var mobs_to_spawn_amount : int = 5
@export var spawn_distance_from_elevator_min = 10.0 # Distance in world units from elevator
@export var spawn_distance_from_elevator_max = 100.0 # Distance in world units from elevator
