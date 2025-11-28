extends StaticBody3D
class_name InteractiveDoor


@export var outside_point : Node3D
@export var inside_point : Node3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
enum STATE {CLOSED, OPENED_INSIDE, OPENED_OUTSIDE}
var state : STATE = STATE.CLOSED
@onready var open_audio_stream_player_3d: AudioStreamPlayer3D = $OpenAudioStreamPlayer3D
@onready var close_audio_stream_player_3d: AudioStreamPlayer3D = $CloseAudioStreamPlayer3D
@export var auto_close_timer_min_max :Vector2 = Vector2(5,90)
var current_auto_close_timer : float = 0.0

func _ready() -> void:
	# Set initial state
	_play_door_animation(state)

func _process(delta: float) -> void:
	# Only server manages auto-close timer (or single player mode)
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	
	# Decrease timer if door is open
	if state != STATE.CLOSED:
		current_auto_close_timer -= delta
		
		# Auto-close door when timer reaches zero
		if current_auto_close_timer <= 0.0:
			if Engine.is_editor_hint() == false and multiplayer.has_multiplayer_peer():
				print("InteractiveDoor: [SERVER] Auto-closing door (timer expired)")
			set_door_state(STATE.CLOSED)
			current_auto_close_timer = 0.0

# Reset auto-close timer to random value between min and max
func _reset_auto_close_timer():
	var old_timer = current_auto_close_timer
	current_auto_close_timer = randf_range(auto_close_timer_min_max.x, auto_close_timer_min_max.y)

	# Debug log for timer reset
	if Engine.is_editor_hint() == false and multiplayer.has_multiplayer_peer():
		var peer_type = "SERVER" if multiplayer.is_server() else "CLIENT"
		print("InteractiveDoor: [%s] Timer reset - %.2f -> %.2f" % [peer_type, old_timer, current_auto_close_timer])

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
	return STATE.OPENED_OUTSIDE if dist_to_outside > dist_to_inside else STATE.OPENED_INSIDE

# Toggle door state (open/close)
func toggle_door(player_position: Vector3):
	var new_state: STATE
	if state == STATE.CLOSED:
		# Determine which side to open to
		new_state = get_player_side(player_position)
	else:
		# Close the door
		new_state = STATE.CLOSED
	
	# Reset auto-close timer on every interaction (mob or player)
	# This ensures door stays open longer when actively used
	if new_state != STATE.CLOSED:
		_reset_auto_close_timer()
	else:
		# Reset timer when closing
		current_auto_close_timer = 0.0
	
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
		rpc_set_door_state.rpc(new_state, current_auto_close_timer)

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
func rpc_set_door_state(new_state: STATE, auto_close_timer: float = 0.0):
	# Update state and timer on all clients
	var old_state = state
	var old_timer = current_auto_close_timer
	state = new_state
	current_auto_close_timer = auto_close_timer

	# Play animation on all clients
	_play_door_animation(state)

	# Debug log for synchronization
	if Engine.is_editor_hint() == false and multiplayer.has_multiplayer_peer():
		var peer_type = "SERVER" if multiplayer.is_server() else "CLIENT"
		if old_state != new_state or abs(old_timer - auto_close_timer) > 0.01:
			print("InteractiveDoor: [%s] State sync - %s -> %s, timer: %.2f -> %.2f" % [
				peer_type, old_state, new_state, old_timer, auto_close_timer
			])

# RPC function called by players to request door toggle
@rpc("any_peer", "call_local", "reliable")
func rpc_request_toggle(player_position: Vector3):
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	toggle_door(player_position)
