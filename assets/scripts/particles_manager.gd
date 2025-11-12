extends Node3D
class_name ParticlesManager

const HIT_BLOOD_GPU_PARTICLES_3D = preload("uid://bmbm0r6bhy0dx")
const HIT_SOLID_GPU_PARTICLES_3D = preload("uid://ywjfm5gkmyns")
const BLOOD_SPLATTER_GPU_PARTICLES_3D = preload("uid://dj6l4m5wv7ft2")

const POOL_SIZE = 10  # Initial pool size for each particle type

var _blood_particle_pool: Array[GPUParticles3D] = []
var _solid_particle_pool: Array[GPUParticles3D] = []
var _blood_splatter_pool: Array[GPUParticles3D] = []
var _active_blood_particles: Array[GPUParticles3D] = []
var _active_solid_particles: Array[GPUParticles3D] = []
var _active_blood_splatter_particles: Array[GPUParticles3D] = []

func _ready() -> void:
	GameManager.particles_manager = self
	# Pre-populate pools with particle instances
	_initialize_pool(_blood_particle_pool, HIT_BLOOD_GPU_PARTICLES_3D, POOL_SIZE)
	_initialize_pool(_solid_particle_pool, HIT_SOLID_GPU_PARTICLES_3D, POOL_SIZE)
	_initialize_pool(_blood_splatter_pool, BLOOD_SPLATTER_GPU_PARTICLES_3D, POOL_SIZE)

func _initialize_pool(pool: Array, scene: PackedScene, size: int) -> void:
	for i in size:
		var instance = scene.instantiate() as GPUParticles3D
		if instance:
			instance.emitting = false
			instance.visible = false
			add_child(instance)
			pool.append(instance)

func _get_particle_from_pool(pool: Array, active_list: Array, scene: PackedScene) -> GPUParticles3D:
	var particle: GPUParticles3D = null
	
	# Try to find an available particle in the pool
	for i in range(pool.size() - 1, -1, -1):
		var p = pool[i]
		if is_instance_valid(p) and not p.emitting and not p.visible:
			particle = p
			pool.remove_at(i)
			break
	
	# If no available particle, create a new one
	if particle == null:
		particle = scene.instantiate() as GPUParticles3D
		if particle:
			add_child(particle)
	
	if particle:
		active_list.append(particle)
	
	return particle

func _return_particle_to_pool(particle: GPUParticles3D, pool: Array, active_list: Array) -> void:
	if not is_instance_valid(particle):
		return
	
	particle.emitting = false
	particle.visible = false
	
	if active_list.has(particle):
		active_list.erase(particle)
	
	if not pool.has(particle):
		pool.append(particle)

@rpc("call_local")
func spawn_blood_hit_particle(pos: Vector3, danger_direction : Vector3) -> void:
	# Spawn blood hit particle
	var particle = _get_particle_from_pool(_blood_particle_pool, _active_blood_particles, HIT_BLOOD_GPU_PARTICLES_3D)
	if particle:
		particle.global_position = pos
		particle.visible = true
		particle.restart()
		particle.emitting = true
		
		# Return to pool after lifetime expires
		_return_particle_after_delay(particle, _blood_particle_pool, _active_blood_particles, particle.lifetime + 0.1)
	
	# Spawn blood splatter particle and rotate it towards danger direction
	var splatter = _get_particle_from_pool(_blood_splatter_pool, _active_blood_splatter_particles, BLOOD_SPLATTER_GPU_PARTICLES_3D)
	if splatter:
		splatter.global_position = pos
		
		# Rotate splatter to face the danger direction
		# The particle emits in -Z direction, so we make it look_at a point in the danger direction
		# so that -Z points along danger_direction (blood splatters in the direction of the attack)
		if danger_direction.length_squared() > 0.0001:
			var normalized_direction = danger_direction.normalized()
			# Look at a point in the danger direction so -Z (emission direction) points that way
			var target_position = pos + normalized_direction
			splatter.look_at(target_position, Vector3.UP)
		
		splatter.visible = true
		splatter.restart()
		splatter.emitting = true
		
		# Return to pool after lifetime expires
		_return_particle_after_delay(splatter, _blood_splatter_pool, _active_blood_splatter_particles, splatter.lifetime + 0.1)

@rpc("call_local")
func spawn_solid_hit_particle(pos: Vector3) -> void:
	var particle = _get_particle_from_pool(_solid_particle_pool, _active_solid_particles, HIT_SOLID_GPU_PARTICLES_3D)
	if particle:
		particle.global_position = pos
		particle.visible = true
		particle.restart()
		particle.emitting = true
		
		# Return to pool after lifetime expires
		_return_particle_after_delay(particle, _solid_particle_pool, _active_solid_particles, particle.lifetime + 0.1)

func _return_particle_after_delay(particle: GPUParticles3D, pool: Array, active_list: Array, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	if is_instance_valid(particle) and is_instance_valid(self):
		_return_particle_to_pool(particle, pool, active_list)
