extends Resource
class_name ResourceWeapon

enum WEAPON_TYPE {TORCH, RUSTY_PIPE, FIRE_AXE}
@export var weapon_name : StringName = &'Weapon'
@export var weapon_type : WEAPON_TYPE = WEAPON_TYPE.TORCH
@export var pickup_prefab_path : StringName
@export var weapon_prefab_path : StringName

@export var damage_min_max : Vector2i = Vector2i(30,60)
@export var weapon_blocking_angle = 160
@export var push_forward_on_attack_force : float = 5
@export var weapon_durability_current : float = 100
@export var weapon_durability_max : float = 100


@export_category('TORCH DURABILITY BURNING')
@export var reducing_durability_when_in_hands : bool = false
@export var in_hands_reduce_durability_speed := 0.5
