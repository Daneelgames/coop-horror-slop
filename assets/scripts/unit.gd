extends CharacterBody3D
class_name Unit

@export var health_current : float = 100
@export var health_max : float = 100

func take_damage(dmg):
	if is_dead():
		return
	health_current -= dmg
	if  health_current <= 0:
		death()
	

func death():
	pass

func is_dead():
	return health_current <= 0
