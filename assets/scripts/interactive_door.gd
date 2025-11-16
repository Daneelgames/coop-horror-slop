extends StaticBody3D
class_name InteractiveDoor

@export var outside_point : Node3D
@export var inside_point : Node3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
enum STATE {CLOSED, OPENED_INSIDE, OPENED_OUTSIDE}
var state : STATE = STATE.CLOSED
@onready var open_audio_stream_player_3d: AudioStreamPlayer3D = $OpenAudioStreamPlayer3D
@onready var close_audio_stream_player_3d: AudioStreamPlayer3D = $CloseAudioStreamPlayer3D

func _ready() -> void:
	# Set initial state
	_play_door_animation(state)

# Determine which side of the door the player is on
func get_player_side(player_position: Vector3) -> STATE:
	if outside_point == null or inside_point == null:
		# Fallback: use door's forward direction
		var door_forward = -global_transform.basis.z
		var to_player = (player_position - global_position).normalized()
		var dot = door_forward.dot(to_player)
		return STATE.OPENED_OUTSIDE if dot > 0 else STATE.OPENED_INSIDE
	
	# Calculate distances to both points
	var dist_to_outside = player_position.distance_to(outside_point.global_position)
	var dist_to_inside = player_position.distance_to(inside_point.global_position)
	
	# Player is on the side they're closer to
	return STATE.OPENED_OUTSIDE if dist_to_outside < dist_to_inside else STATE.OPENED_INSIDE

# Toggle door state (open/close)
func toggle_door(player_position: Vector3):
	var new_state: STATE
	if state == STATE.CLOSED:
		# Determine which side to open to
		new_state = get_player_side(player_position)
	else:
		# Close the door
		new_state = STATE.CLOSED
	
	set_door_state(new_state)

# Set door state and sync to all clients (called on server)
func set_door_state(new_state: STATE):
	if state == new_state:
		return
	
	state = new_state
	
	# Play animation locally on server
	_play_door_animation(state)
	
	# Sync to all clients via RPC (only server calls this)
	if multiplayer.is_server():
		rpc_set_door_state.rpc(new_state)

# Internal function to play door animation
func _play_door_animation(door_state: STATE):
	if animation_player:
		match door_state:
			STATE.CLOSED:
				animation_player.play("closed", 0.33)
				close_audio_stream_player_3d.play()
			STATE.OPENED_INSIDE:
				animation_player.play("opened_inside", 1.0)
				open_audio_stream_player_3d.play()
			STATE.OPENED_OUTSIDE:
				animation_player.play("opened_outside", 1.0)
				open_audio_stream_player_3d.play()

# RPC to sync door state to all clients
@rpc("any_peer", "call_local", "reliable")
func rpc_set_door_state(new_state: STATE):
	# Update state on all clients
	state = new_state
	
	# Play animation on all clients
	_play_door_animation(state)

# RPC function called by players to request door toggle
@rpc("any_peer", "reliable")
func rpc_request_toggle(player_position: Vector3):
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	toggle_door(player_position)
