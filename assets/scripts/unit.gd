extends CharacterBody3D
class_name Unit

@export var mesh_animation_player: AnimationPlayer
@export var health_current : float = 100
@export var health_max : float = 100

@export var take_damage_anims : Array[StringName]= []
@export var death_anims : Array[StringName]= []

var is_taking_damage = false

@rpc("any_peer", "call_local", "reliable")
func rpc_take_damage(dmg):
	# Only allow server to call this RPC
	# When server calls .rpc(), remote_sender_id is 0 on server, 1 on clients
	# When client calls, remote_sender_id is the client's peer ID
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	take_damage(dmg)

func take_damage(dmg):
	if is_dead():
		return
	health_current -= dmg
	if  health_current <= 0:
		death()
	else:
		play_damage_anim()
		
func death():
	play_death_anim()

func play_damage_anim():
	if is_taking_damage:
		return
	if take_damage_anims.is_empty():
		return
	is_taking_damage = true
	mesh_animation_player.play(take_damage_anims.pick_random())
	await mesh_animation_player.animation_finished
	is_taking_damage = false
	
func play_death_anim():
	if death_anims.is_empty():
		return
	mesh_animation_player.play(death_anims.pick_random())
	pass

func is_dead():
	return health_current <= 0
