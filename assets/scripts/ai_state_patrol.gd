extends AiState
class_name AiStatePatrol

#patrol between random points around home spawn position. points should be chosen by patrol_from_home_distance_min_max vec2

var ai_character: AiCharacter
var wait_time_at_target: float = 0.0
var wait_duration: float = 2.0  # Wait 2 seconds at each patrol point

func _ready():
	# Get reference to AI character (state -> state machine -> ai character)
	ai_character = get_parent().get_parent() as AiCharacter
	if ai_character == null:
		push_error("AiStatePatrol: Could not find AiCharacter parent")

func enter_state():
	if ai_character == null:
		return
	# Generate a new patrol target when entering patrol state
	_generate_new_patrol_target()

func exit_state():
	if ai_character:
		ai_character.stop_movement()
	wait_time_at_target = 0.0

func _physics_process(_delta):
	if ai_character == null:
		return
	
	# Only process patrol logic on server
	if not multiplayer.is_server():
		return
	
	# Don't patrol if dead or in combat states
	if ai_character.is_dead() or ai_character.is_attacking or ai_character.is_taking_damage:
		return
	
	# Check if we've reached the target
	if ai_character.navigation_agent_3d.is_navigation_finished():
		# Reached target, wait for a bit
		ai_character.stop_movement()
		wait_time_at_target += _delta
		
		if wait_time_at_target >= wait_duration:
			# Generate new patrol target
			wait_time_at_target = 0.0
			_generate_new_patrol_target()

func _generate_new_patrol_target():
	if ai_character == null:
		return
	
	var home_position = ai_character.home_position
	var min_distance = ai_character.patrol_from_home_distance_min_max.x
	var max_distance = ai_character.patrol_from_home_distance_min_max.y
	
	# Generate random angle and distance
	var angle = randf() * TAU  # Random angle in radians (0 to 2π)
	var distance = randf_range(min_distance, max_distance)
	
	# Calculate target position
	var target_offset = Vector3(
		cos(angle) * distance,
		0,
		sin(angle) * distance
	)
	
	var target_position = home_position + target_offset
	
	# Set movement target (ai_character handles the actual movement)
	ai_character.set_movement_target(target_position)
