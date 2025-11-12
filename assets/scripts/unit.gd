extends CharacterBody3D
class_name Unit

@export var mesh_animation_player: AnimationPlayer
@export var health_current : float = 100
@export var health_max : float = 100

@export var take_damage_anims : Array[StringName]= []
@export var death_anims : Array[StringName]= []

@export var is_attacking = false 
@export var is_blocking = false
@export var is_taking_damage = false

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
	play_take_damage()
	if is_dead():
		return
	health_current -= dmg
	if  health_current <= 0:
		death()
	else:
		play_damage_anim()
		
func death():
	play_death()
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


#endregion
@onready var steps_audio_stream_player_3d: AudioStreamPlayer3D = %StepsAudioStreamPlayer3D

func play_foot_step():
	steps_audio_stream_player_3d.play()
	pass
@onready var attack_woosh_audio_stream_player_3d: AudioStreamPlayer3D = %AttackWooshAudioStreamPlayer3D

func play_attack_woosh():
	attack_woosh_audio_stream_player_3d.play()
	pass
	
@onready var hit_solid_audio_stream_player_3d: AudioStreamPlayer3D = %HitSolidAudioStreamPlayer3D
func play_hit_solid():
	hit_solid_audio_stream_player_3d.play()
	pass
	
@onready var take_damage_audio_stream_player_3d: AudioStreamPlayer3D = %TakeDamageAudioStreamPlayer3D
func play_take_damage():
	take_damage_audio_stream_player_3d.play()
	pass
	
@onready var death_audio_stream_player_3d: AudioStreamPlayer3D = %DeathAudioStreamPlayer3D
func play_death():
	death_audio_stream_player_3d.play()

func play_mesh_animation(moving_vector, auth, state):
	if is_attacking or is_taking_damage or is_dead() or is_blocking:
		return
	# For remote instances, use synced input_dir directly
	# For local instance, check if on floor to avoid playing walk animation while in air
	var should_walk = moving_vector != Vector2.ZERO
	if auth:
		should_walk = should_walk and is_on_floor()
	
	if should_walk:
		if state == "sprinting":
			if mesh_animation_player.current_animation != "run_forward":
				mesh_animation_player.play("run_forward", 0.2)
		else:
			if mesh_animation_player.current_animation != "walk_forward":
				mesh_animation_player.play("walk_forward", 0.2)
	else:
		if mesh_animation_player.current_animation != "idle":
			mesh_animation_player.play("idle", 0.2)
