extends RigidBody3D
class_name Interactive

@export var weapon_resource : ResourceWeapon
@onready var visual_parent: Node3D = %VisualParent

func _ready() -> void:
	if weapon_resource:
		weapon_resource = weapon_resource.duplicate()

func _process(delta: float) -> void:
	visual_parent.global_position = visual_parent.global_position.lerp(global_position, 10 * delta)
	var current_basis = Basis.from_euler(visual_parent.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * delta)
	visual_parent.global_rotation = slerped_basis.get_euler()
	
func activate_rigidbody_collisions():
	set_collision_layer_value(3, true)
	set_collision_mask_value(1, true)
	set_collision_mask_value(2, true)
	freeze = false
	
func deactivate_rigidbody_collisions():
	set_collision_layer_value(3, false)
	set_collision_mask_value(1, false)
	set_collision_mask_value(2, false)
	freeze = true

# RPC function called by players to request picking up this item by name
# This allows clients to request pickup even when the node isn't synchronized
@rpc("any_peer", "reliable")
func rpc_request_pickup_by_name(pickup_name: String, pickup_position: Vector3):
	# Only server processes this
	if !multiplayer.is_server():
		return
	
	# Find the pickup by name (since pickups are spawned deterministically on all peers)
	var pickup: Interactive = null
	var root = get_tree().root
	var pickup_path = root.get_node_or_null("Main/GameRoot/GameLevelSpawner/GameLevel/ProceduralDungeon/DungeonTiles/" + pickup_name)
	if pickup_path != null and pickup_path is Interactive:
		pickup = pickup_path as Interactive
	else:
		# Fallback: search by position (within tolerance)
		var all_pickups = get_tree().get_nodes_in_group("pickups")
		for node in all_pickups:
			if node is Interactive and node.global_position.distance_to(pickup_position) < 1.0:
				pickup = node as Interactive
				break
	
	if pickup == null:
		print("[PICKUP] Could not find pickup '%s' at position %s" % [pickup_name, pickup_position])
		return
	
	# Process pickup using the found pickup node
	pickup._process_pickup_request()

# Internal function to process pickup request (called by rpc_request_pickup_by_name)
func _process_pickup_request():
	# Get requesting peer ID
	var requesting_peer_id = multiplayer.get_unique_id()
	if multiplayer.get_remote_sender_id() != 0:
		requesting_peer_id = multiplayer.get_remote_sender_id()
	
	# Find the requesting player's character
	var root = get_tree().root
	var player_path = root.get_node_or_null("Main/GameRoot/Players/PlayerSpawner/Player_%d" % requesting_peer_id)
	var requesting_player = player_path
	
	if requesting_player == null:
		# Try searching all nodes for the player
		var all_players = get_tree().get_nodes_in_group("players")
		for player in all_players:
			if player.name == "Player_%d" % requesting_peer_id:
				requesting_player = player
				break
	
	if requesting_player == null:
		print("[PICKUP] Could not find requesting player %d" % requesting_peer_id)
		return
	
	# Check if player can pick up (inventory not full)
	if requesting_player.carrying_items.size() >= requesting_player.inventory_slots_max:
		print("[PICKUP] Player %d inventory is full" % requesting_peer_id)
		return
	
	# Check if weapon_resource is valid
	if weapon_resource == null:
		print("[PICKUP] This pickup has no weapon_resource!")
		return
	
	# Process pickup on server
	# Handle duplicate names by appending a counter
	var final_name = weapon_resource.weapon_name
	var counter = 1
	while requesting_player.carrying_items.has(final_name):
		final_name = StringName("%s %d" % [weapon_resource.weapon_name, counter+1])
		counter += 1
	
	requesting_player.carrying_items[final_name] = weapon_resource.duplicate()
	
	# Clamp selected index if needed
	requesting_player._clamp_selected_index()
	
	# Tell all clients to destroy this pickup by name
	rpc_destroy_pickup_by_name.rpc(name, global_position)
	
	# Tell requesting client to update their inventory UI
	if requesting_peer_id == 1:
		# Server picking up - update directly
		if requesting_player.inventory_slots_panel_container:
			requesting_player.inventory_slots_panel_container.update_inventory_items_ui(requesting_player.carrying_items, requesting_player.current_selected_item_index)
	else:
		# Client picking up - send RPC to their character node
		var serialized_inventory: Dictionary = {}
		for key in requesting_player.carrying_items.keys():
			serialized_inventory[key] = GameManager.serialize_weapon_resource(requesting_player.carrying_items[key])
		requesting_player.rpc_update_inventory.rpc_id(requesting_peer_id, serialized_inventory)
	
	# Update item in hands for all clients
	var item_keys = requesting_player.carrying_items.keys()
	if item_keys.size() > requesting_player.current_selected_item_index and requesting_player.current_selected_item_index >= 0:
		var selected_item_resource = requesting_player.carrying_items[item_keys[requesting_player.current_selected_item_index]]
		var selected_weapon_data = GameManager.serialize_weapon_resource(selected_item_resource)
		requesting_player.rpc_update_item_in_hands.rpc(requesting_player.current_selected_item_index, selected_weapon_data)
	else:
		requesting_player.rpc_update_item_in_hands.rpc(-1, {})  # No item selected

# RPC function called by players to request picking up this item (kept for backward compatibility)
@rpc("any_peer", "reliable")
func rpc_request_pickup():
	# Only server processes this
	if !multiplayer.is_server():
		return
	_process_pickup_request()

# RPC to destroy this pickup on all clients by name
@rpc("any_peer", "call_local", "reliable")
func rpc_destroy_pickup_by_name(pickup_name: String, pickup_position: Vector3):
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	# Find the pickup by name or position
	var pickup: Interactive = null
	if name == pickup_name:
		pickup = self
	else:
		# Try to find by name in scene tree
		var root = get_tree().root
		var pickup_path = root.get_node_or_null("Main/GameRoot/GameLevelSpawner/GameLevel/ProceduralDungeon/DungeonTiles/" + pickup_name)
		if pickup_path != null and pickup_path is Interactive:
			pickup = pickup_path as Interactive
		else:
			# Fallback: search by position
			var all_pickups = get_tree().get_nodes_in_group("pickups")
			for node in all_pickups:
				if node is Interactive and node.global_position.distance_to(pickup_position) < 1.0:
					pickup = node as Interactive
					break
	
	if pickup != null:
		print("[PICKUP] Destroying pickup: %s" % pickup.name)
		pickup.queue_free()

# RPC to destroy this pickup on all clients (kept for backward compatibility)
@rpc("any_peer", "call_local", "reliable")
func rpc_destroy_pickup():
	# Only process if called from server (peer ID 1)
	var sender_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	
	print("[PICKUP] Destroying pickup: %s" % name)
	queue_free()

func snap_visual():
	if visual_parent == null:
		return
	visual_parent.global_position = global_position
	visual_parent.global_rotation = global_rotation
