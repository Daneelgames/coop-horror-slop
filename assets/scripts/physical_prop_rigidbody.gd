extends RigidBody3D
class_name PhysicalPropRigidbody3D

@export var health : int = 30
@export var visual_node : Node3D
@export var death_particles : PackedScene  # GPU particles scene for death effect

var is_dead : bool = false

func _ready() -> void:
	# Disable physics processing on clients - only server processes physics
	if not multiplayer.is_server():
		freeze = true
		set_physics_process(false)

func _process(delta: float) -> void:
	if is_dead:
		return
	visual_node.global_position = visual_node.global_position.lerp(global_position, 10 * delta)
	var current_basis = Basis.from_euler(visual_node.global_rotation)
	var target_basis = Basis.from_euler(global_rotation)
	var slerped_basis = current_basis.slerp(target_basis, 10 * delta)
	visual_node.global_rotation = slerped_basis.get_euler()

# RPC method to handle damage from any source (players or mobs)
@rpc("any_peer", "call_local", "reliable")
func rpc_take_damage(damage: float, fire_damage: float, hit_position: Vector3, attacker_position: Vector3):
	# Only allow server to process damage
	var sender_id = multiplayer.get_remote_sender_id()
	if !multiplayer.is_server():
		# On clients, only accept from server (peer ID 1)
		if sender_id != 1:
			return
	# On server, sender_id will be 0 (local call) which is fine
	take_damage(damage, fire_damage, hit_position, attacker_position)

func take_damage(damage: float, fire_damage: float, hit_position: Vector3, attacker_position: Vector3):
	if is_dead:
		return
	
	# Apply damage to health
	health -= int(damage)
	
	# Check if prop died
	if health <= 0:
		health = 0
		# Call death directly on server
		death(hit_position)
		# Sync death to all clients via GameManager to avoid path resolution issues
		if multiplayer.is_server() and is_instance_valid(GameManager):
			var prop_name = name
			GameManager.rpc_prop_death.rpc(prop_name, hit_position)
		return
	
	# Apply impulse based on damage and mass
	if self.mass > 0:
		# Calculate impulse = damage / mass
		var impulse_magnitude = damage / self.mass
		# Calculate direction from hit point to attacker (push away from attacker)
		var push_direction = (hit_position - attacker_position).normalized()
		# Apply impulse at hit position for realistic physics
		var impulse_vector = push_direction * impulse_magnitude
		apply_impulse(impulse_vector, hit_position)

# RPC method to synchronize death across all clients
@rpc("any_peer", "call_local", "reliable")
func rpc_death(death_position: Vector3):
	# Update state on all clients (called from server)
	death(death_position)

func death(death_position: Vector3):
	if is_dead:
		return
	
	is_dead = true
	
	# Hide visual node
	if visual_node != null:
		visual_node.visible = false

	# Disable collisions
	set_collision_layer_value(1, false)
	set_collision_layer_value(2, false)
	set_collision_layer_value(3, false)
	set_collision_layer_value(4, false)
	set_collision_layer_value(5, false)
	set_collision_mask_value(1, false)
	set_collision_mask_value(2, false)
	set_collision_mask_value(3, false)
	set_collision_mask_value(4, false)
	
	# Freeze rigidbody
	freeze = true
	
	# Spawn death particles on all clients
	# Use call_deferred to ensure particles spawn after prop state is updated
	if death_particles != null:
		_spawn_death_particles(death_position)
	
	# Only destroy the prop on server - MultiplayerSpawner will handle cleanup on clients
	if multiplayer.is_server():
		# Destroy the prop after a short delay to allow particles to spawn
		var destroy_timer = get_tree().create_timer(0.1)
		destroy_timer.timeout.connect(func():
			if is_instance_valid(self):
				queue_free()
		)

func _spawn_death_particles(death_position: Vector3):
	# Spawn particles using call_deferred to ensure they spawn correctly on all clients
	call_deferred("_do_spawn_death_particles", death_position)

func _do_spawn_death_particles(death_position: Vector3):
	if death_particles == null:
		return
	
	var particles_instance = death_particles.instantiate()
	if particles_instance == null:
		return
	
	# Add to scene tree - use current scene root or GameLevel
	var scene_root = get_tree().root
	if is_instance_valid(GameManager) and is_instance_valid(GameManager._game_level):
		# Add to GameLevel so particles are in the correct scene context
		GameManager._game_level.add_child(particles_instance)
	else:
		# Fallback to scene root
		scene_root.add_child(particles_instance)
	
	particles_instance.global_position = death_position
	
	if particles_instance is GPUParticles3D:
		particles_instance.emitting = true
		particles_instance.restart()
		# Clean up particles after they finish (on each client independently)
		var cleanup_timer = get_tree().create_timer(particles_instance.lifetime + 0.1)
		cleanup_timer.timeout.connect(func():
			if is_instance_valid(particles_instance):
				particles_instance.queue_free()
		)
