extends StaticBody3D
class_name LightStandProp
@onready var fire_gpu_particles_3d: GPUParticles3D = %FireGPUParticles3D
@onready var omni_light_3d: OmniLight3D = %OmniLight3D
@onready var fire_audio_stream_player_3d: AudioStreamPlayer3D = %FireAudioStreamPlayer3D

func _ready() -> void:
	if multiplayer.is_server():
		rpc_set_lights_active.rpc(randf() < 0.2)

@rpc("any_peer", "call_local", "reliable")
func rpc_set_lights_active(active):
	fire_gpu_particles_3d.emitting = active
	omni_light_3d.visible = active
	fire_audio_stream_player_3d.playing = active
	
	
var is_dead = false
# RPC method to handle damage from any source (players or mobs)
@rpc("any_peer", "call_local", "reliable")
func rpc_take_damage(damage: float, fire_damage, hit_position: Vector3, attacker_position: Vector3):
	# Only allow server to process damage
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	take_damage(damage, fire_damage, hit_position, attacker_position)

func take_damage(damage: float, fire_damage, hit_position: Vector3, attacker_position: Vector3):
	if fire_damage > 0:
		# fire light up
		rpc_set_lights_active.rpc(true)
	else:
		# put lights down
		rpc_set_lights_active.rpc(false)
