extends Resource
class_name ResourceWeapon

enum WEAPON_TYPE {
	TORCH, RUSTY_PIPE, MACHETE, 
	GOLD, DEMON_FANG, 
	HEALING_POTION, SCROLL_OF_LIFE, FLASH_BOMB, ROPE}
	
@export var item_price: int = 100
@export var item_sell_price: int = 50
@export var weapon_name: StringName = &'Weapon'
@export var weapon_type: WEAPON_TYPE = WEAPON_TYPE.TORCH
@export var pickup_prefab_path: StringName
@export var weapon_prefab_path: StringName

@export var damage_min_max: Vector2i = Vector2i(30, 60)
@export var fire_damage_min_max: Vector2i = Vector2i(0, 0)
@export var weapon_blocking_angle = 160
@export var push_forward_on_attack_force: float = 5
@export var weapon_durability_current: float = 100
@export var weapon_durability_max: float = 100


@export_category('TORCH DURABILITY BURNING')
@export var reducing_durability_when_in_hands: bool = false
@export var in_hands_reduce_durability_speed := 0.5

@export_category('CONSUMABLES')
@export var is_one_time_use : bool = false
@export var is_throw_on_use : bool = false
@export var thrown_projectile_prefab_path : StringName
@export var self_heal_hp_amount : float = 0

func is_consumable():
	if weapon_type == WEAPON_TYPE.HEALING_POTION or weapon_type == WEAPON_TYPE.SCROLL_OF_LIFE or weapon_type == WEAPON_TYPE.ROPE or weapon_type == WEAPON_TYPE.FLASH_BOMB:
		return true
	return false
