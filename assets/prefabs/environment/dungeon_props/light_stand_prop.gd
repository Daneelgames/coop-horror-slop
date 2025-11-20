extends StaticBody3D
class_name LightStandProp
@onready var fire_gpu_particles_3d: GPUParticles3D = %FireGPUParticles3D
@onready var omni_light_3d: OmniLight3D = %OmniLight3D
@onready var fire_audio_stream_player_3d: AudioStreamPlayer3D = %FireAudioStreamPlayer3D

# Synchronized properties for multiplayer
@export var lights_active: bool = false:
	set(value):
		lights_active = value
		if is_node_ready():
			_update_lights_state()

var is_dead = false
func _ready() -> void:
	# Initialize lights state on ready
	_update_lights_state()

	if multiplayer.is_server():
		# Defer RPC call to next frame to ensure prop is fully synchronized on all clients
		# This prevents "Failed to get path from RPC" errors when clients receive RPC
		# before the prop node is fully added to the scene tree
		call_deferred("_initialize_lights")

func _initialize_lights() -> void:
	if multiplayer.is_server():
		lights_active = randf() < 0.2
		#lights_active = true

func _update_lights_state():
	if fire_gpu_particles_3d:
		fire_gpu_particles_3d.emitting = lights_active
	if omni_light_3d:
		omni_light_3d.visible = lights_active
	if fire_audio_stream_player_3d:
		fire_audio_stream_player_3d.playing = lights_active

@rpc("authority", "call_local", "reliable")
func rpc_set_lights_active(active):
	# Only server can change this via RPC, clients get it via synchronization
	if multiplayer.is_server():
		lights_active = active
	
	
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
	if multiplayer.is_server():  # Only server can change synchronized properties
		if fire_damage > 0:
			# fire light up
			lights_active = true
		else:
			# put lights down
			lights_active = false
