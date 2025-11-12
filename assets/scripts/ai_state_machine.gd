extends Node3D
class_name AiStateMachine

var ai_character: AiCharacter
var current_state: AiState = null

# State references
@onready var patrol_state: AiStatePatrol = %PatrolState
@onready var combat_state: AiStateCombat = %CombatState
@onready var investigate_state: AiStateInvestigate = %InvestigateState

func _ready():
	ai_character = get_parent() as AiCharacter
	if ai_character == null:
		push_error("AiStateMachine: Could not find AiCharacter parent")
		return
	
	# Disable physics processing for all states initially
	if patrol_state:
		patrol_state.set_physics_process(false)
	if combat_state:
		combat_state.set_physics_process(false)
	if investigate_state:
		investigate_state.set_physics_process(false)
	
	# Start in patrol state
	change_state(patrol_state)

func _physics_process(_delta):
	if ai_character == null:
		return
	
	# Only process state machine on server
	if not multiplayer.is_server():
		return
	
	# Check for state transitions
	_check_state_transitions()

func _check_state_transitions():
	if ai_character.is_dead():
		return
	
	# Check if we have visible enemies - switch to combat
	if not ai_character.visible_enemies.is_empty():
		# Filter out dead enemies
		var alive_enemies = []
		for enemy in ai_character.visible_enemies:
			if is_instance_valid(enemy) and not enemy.is_dead():
				alive_enemies.append(enemy)
		
		if not alive_enemies.is_empty():
			# Switch to combat state if not already in it
			if current_state != combat_state:
				change_state(combat_state)
			return
	
	# No visible enemies - switch back to patrol if in combat
	if current_state == combat_state:
		change_state(patrol_state)

func change_state(new_state: AiState):
	if new_state == null:
		push_error("AiStateMachine: Attempted to change to null state")
		return
	
	if current_state == new_state:
		return  # Already in this state
	
	# Disable physics processing for current state
	if current_state != null:
		current_state.set_physics_process(false)
		if current_state.has_method("exit_state"):
			current_state.exit_state()
	
	# Change state
	current_state = new_state
	
	# Enable physics processing for new state
	if current_state != null:
		current_state.set_physics_process(true)
		if current_state.has_method("enter_state"):
			current_state.enter_state()
