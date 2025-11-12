extends Node3D
class_name AiVisibilityManager

var _ai_characters: Array[AiCharacter] = []
var _check_interval: float = 0.1  # Check every 0.1 seconds (10 times per second)
var _time_since_last_check: float = 0.0

func _ready() -> void:
	GameManager.ai_visibility_manager = self

func register_ai_character(ai_char: AiCharacter) -> void:
	if ai_char == null:
		return
	if not _ai_characters.has(ai_char):
		_ai_characters.append(ai_char)

func unregister_ai_character(ai_char: AiCharacter) -> void:
	if ai_char == null:
		return
	_ai_characters.erase(ai_char)

func _process(delta: float) -> void:
	# Only run visibility checks on server
	if not multiplayer.is_server():
		return
	
	_time_since_last_check += delta
	if _time_since_last_check >= _check_interval:
		_time_since_last_check = 0.0
		_update_visibility()

func _update_visibility() -> void:
	# Get all team 0 units (players and AI characters)
	var team_0_units: Array[Unit] = _get_team_0_units()
	
	# Get all team 1 AI characters
	var team_1_ai: Array[AiCharacter] = []
	for ai_char in _ai_characters:
		if is_instance_valid(ai_char) and ai_char.team == 1:
			team_1_ai.append(ai_char)
	
	# For each team 1 AI character, check visibility against team 0 units
	for ai_char in team_1_ai:
		if not is_instance_valid(ai_char) or ai_char.is_dead():
			continue
		
		var visible_enemies: Array[Unit] = []
		
		# Check visibility against each team 0 unit
		for enemy in team_0_units:
			if not is_instance_valid(enemy) or enemy.is_dead():
				continue
			
			if _is_visible(ai_char, enemy):
				visible_enemies.append(enemy)
		
		# Update the AI character's visible_enemies list
		ai_char.visible_enemies = visible_enemies

func _get_team_0_units() -> Array[Unit]:
	var units: Array[Unit] = []
	
	# Get all player characters (team 0)
	var player_nodes = GameManager._player_nodes
	for peer_id in player_nodes:
		var player = player_nodes[peer_id]
		if is_instance_valid(player) and player is Unit:
			var unit = player as Unit
			if unit.team == 0:
				units.append(unit)
	
	# Get all AI characters with team 0
	for ai_char in _ai_characters:
		if is_instance_valid(ai_char) and ai_char.team == 0:
			units.append(ai_char)
	
	return units

func _is_visible(observer: AiCharacter, target: Unit) -> bool:
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return false
	
	if not is_instance_valid(observer.eyes) or not is_instance_valid(target.eyes):
		return false
	
	var observer_pos = observer.eyes.global_position
	var target_pos = target.eyes.global_position
	
	# Perform raycast from observer's eyes to target's eyes
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(observer_pos, target_pos)
	
	# Set collision layers: layer 1 (solids) and layer 2 (units)
	query.collision_mask = (1 << 0) | (1 << 1)  # layers 1 and 2
	
	# Exclude the observer and its weapon from collision check
	var exclude: Array[RID] = []
	if observer:
		var observer_rid = observer.get_rid()
		if observer_rid:
			exclude.append(observer_rid)
		# Exclude observer's weapon if it exists
		#if observer.item_in_hands:
			#var observer_weapon_rid = observer.item_in_hands.get_rid()
			#if observer_weapon_rid:
				#exclude.append(observer_weapon_rid)
	
	# Exclude the target's weapon (but not the target itself - we want to hit the target)
	#if target.item_in_hands:
		#var weapon_rid = target.item_in_hands.get_rid()
		#if weapon_rid:
			#exclude.append(weapon_rid)
	
	query.exclude = exclude
	
	# Perform raycast
	var result = space_state.intersect_ray(query)
	
	if result.is_empty():
		return false
	
	# Check if we hit the target unit or any of its children
	var collider = result.get("collider")
	if collider == target:
		return true
	
	# Check if collider is a child/descendant of the target
	if collider is Node:
		var node = collider as Node
		var parent = node.get_parent()
		while parent != null:
			if parent == target:
				return true
			parent = parent.get_parent()
	
	# If we hit something else (like a wall), the target is not visible
	return false
