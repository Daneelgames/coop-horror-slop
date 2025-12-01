extends StairsCharacterBody3D
#extends CharacterBody3D
class_name Unit

var item_in_hands: Weapon = null
@export var team: int = 0
@export var mesh_animation_player: AnimationPlayer
@export var health_current: float = 100
@export var health_max: float = 100
@export var stamina_current : float = 100
@export var stamina_max : float = 100

@export var take_damage_anims: Array[StringName] = []
@export var death_anims: Array[StringName] = []

@export var is_attacking = false
@export var is_blocking = false
@export var is_blocking_react = false
@export var is_stun_lock = false
@export var is_taking_damage = false
@onready var eyes: Node3D = %Eyes

func _ready():
	is_stun_lock = false
	is_blocking = false
	is_attacking = false
	is_taking_damage = false
	is_blocking_react = false
	
@rpc("any_peer", "call_local", "reliable")
func rpc_stun_lock_on_blocked_attack():
	if is_stun_lock:
		return
	is_stun_lock = true
	# Reverse current attack animation from current frame
	
	# reversed attack anim
	#if is_attacking and mesh_animation_player.current_animation:
		#var current_pos = mesh_animation_player.current_animation_position
		#mesh_animation_player.play(mesh_animation_player.current_animation, 0.1, -1.0, false)
		#mesh_animation_player.seek(current_pos, true)
		
	# Zero out horizontal attack-push velocity when attack is blocked (only on server)
	if multiplayer.is_server():
		velocity.x = 0
		velocity.z = 0
	mesh_animation_player.play("stun_lock", 0.1)
	await mesh_animation_player.animation_finished
	is_stun_lock = false
	
@rpc("any_peer", "call_local", "reliable")
func rpc_take_attack_blocked():
	if is_blocking_react:
		return
	is_blocking_react = true
	mesh_animation_player.play("block_react", 0.1)
	await mesh_animation_player.animation_finished
	is_blocking_react = false

@rpc("any_peer", "call_local", "reliable")
func rpc_take_damage(dmg, fire_damage: float = 0):
	# Only allow server to call this RPC
	# When server calls .rpc(), remote_sender_id is 0 on server, 1 on clients
	# When client calls, remote_sender_id is the client's peer ID
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	take_damage(dmg, fire_damage)

func take_damage(dmg, fire_damage: float = 0):
	play_take_damage()
	if is_dead():
		return
	# Zero out horizontal attack-push velocity when taking damage (only on server)
	if multiplayer.is_server():
		velocity.x = 0
		velocity.z = 0
	health_current -= dmg
	if health_current <= 0:
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

@rpc("any_peer", "call_local", "reliable")
func rpc_play_hit_solid():
	# Only allow server to call this RPC
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	play_hit_solid()
	
@onready var take_damage_audio_stream_player_3d: AudioStreamPlayer3D = %TakeDamageAudioStreamPlayer3D
func play_take_damage():
	take_damage_audio_stream_player_3d.play()
	pass
	
@onready var death_audio_stream_player_3d: AudioStreamPlayer3D = %DeathAudioStreamPlayer3D
func play_death():
	death_audio_stream_player_3d.play()

func play_mesh_animation(moving_vector, auth, state):
	if is_attacking or is_taking_damage or is_dead() or is_blocking or is_blocking_react or is_stun_lock or is_on_floor() == false:
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
		elif state == "crouching":
			if mesh_animation_player.current_animation != "crouch_walk":
				mesh_animation_player.play("crouch_walk", 0.2)
		else:
			if mesh_animation_player.current_animation != "walk_forward":
				mesh_animation_player.play("walk_forward", 0.2)
	else:
		if state == "crouching":
			if mesh_animation_player.current_animation != "crouch":
				mesh_animation_player.play("crouch", 0.2)
		else:
			if mesh_animation_player.current_animation != "idle":
				mesh_animation_player.play("idle", 0.2)
			
@rpc("any_peer", "call_local", "reliable")
func rpc_full_heal_and_resurrect():
	# Only allow server to call this RPC
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine

	var old_health = health_current
	health_current = health_max
	print("[RESURRECTION] Unit ", name, " resurrected! Health: ", old_health, " -> ", health_current)

	# Reset states
	is_attacking = false
	is_blocking = false
	is_blocking_react = false
	is_stun_lock = false
	is_taking_damage = false
