@tool
extends Node3D
class_name StairsTile
@onready var csg_linear_stairs: CSGCombiner3D = $CSGLinearStairs
@onready var stair_raycast_origin: Node3D = $StairRaycastOrigin
@onready var stair_diagonal_raycast_direction: Node3D = $DiagonalTunnelRaycastDirection
@onready var stair_horizontal_raycast_direction: Node3D = $HorizontalTunnelRaycastDirection
@onready var stair_end_platform: Node3D = %Platform

signal tunnel_requested(stairs_tile: StairsTile, origin_global: Vector3, target_global: Vector3, tunnel_type: String)


const STAIRS_AMOUNT_PER_TILE = 16
const STAIRS_WIDTH = 4
const STAIR_HEIGHT = 0.13
const STAIR_DEPTH = 0.21
const TILE_SIZE: Vector3i = Vector3i(4, 2, 4)

const TUNNEL_TYPE_DIAGONAL := "diagonal"
const TUNNEL_TYPE_HORIZONTAL := "horizontal"

func configure_stairs_height(floor_height):
	csg_linear_stairs.stairs_amount_set(STAIRS_AMOUNT_PER_TILE * floor_height)
	global_rotation_degrees.y = randi_range(0, 4) * 90
	# После обновления лестниц, переместить stair_raycast_direction на позицию последней лестницы плюс локальный оффсет
	await get_tree().process_frame  # Ждем обновления лестниц
	
	var stairs_amount = csg_linear_stairs.stairs_amount
	if stairs_amount > 0:
		# Вычисляем позицию последней лестницы (индекс stairs_amount - 1)
		# Формулы из csg_linear_stairs.gd:
		# Y: (stair_height / 2) + (i * stair_height)
		# Z: -i * stair_depth
		# X: 0
		var last_stair_index = stairs_amount - 1
		var last_stair_y = (STAIR_HEIGHT / 2) + (last_stair_index * STAIR_HEIGHT)
		var last_stair_z = -last_stair_index * STAIR_DEPTH
		var last_stair_x = 0.0
		
		# Позиция последней лестницы в локальных координатах CSGLinearStairs
		var last_stair_local_pos = Vector3(last_stair_x, last_stair_y, last_stair_z)
		
		# Преобразуем в глобальные координаты, затем в локальные относительно StairsTile
		var last_stair_global_pos = csg_linear_stairs.to_global(last_stair_local_pos)
		var last_stair_stairs_tile_pos = to_local(last_stair_global_pos)
		
		# Добавляем оффсет для туннеля вдоль лестницы
		var diagonal_offset = Vector3(0, 2, 1)
		stair_diagonal_raycast_direction.position = last_stair_stairs_tile_pos + diagonal_offset
		
		# Для горизонтального туннеля смещаемся вперед и опускаем на высоту тайла
		var horizontal_target = last_stair_stairs_tile_pos + Vector3(0, 0, 1)
		horizontal_target.y -= TILE_SIZE.y
		stair_horizontal_raycast_direction.position = horizontal_target
		
		# Располагаем платформу перекрытия щели между лестницей и полом верхнего этажа
		var platform_offset = Vector3(0, 0, 1.12)
		stair_end_platform.position = last_stair_stairs_tile_pos + platform_offset
	
	# На сервере выполнить рейкаст и удаление солидов
	# Ждем еще один фрейм, чтобы убедиться, что все обновлено
	await get_tree().process_frame
	
	var should_raycast := (multiplayer.has_multiplayer_peer() and multiplayer.is_server()) or not multiplayer.has_multiplayer_peer()
	if should_raycast:
		var raycast_targets = [
			{"node": stair_diagonal_raycast_direction, "type": TUNNEL_TYPE_DIAGONAL},
			{"node": stair_horizontal_raycast_direction, "type": TUNNEL_TYPE_HORIZONTAL}
		]
		for target_data in raycast_targets:
			var direction_node: Node3D = target_data["node"]
			var tunnel_type: String = target_data["type"]
			await _raycast_and_remove_solids(direction_node, tunnel_type)

func _raycast_and_remove_solids(direction_node: Node3D, tunnel_type: String):
	if direction_node == null:
		return
	await get_tree().process_frame
	# Рейкаст от stair_raycast_origin до stair_raycast_direction и удаление всех солидов на пути
	if not is_instance_valid(stair_raycast_origin) or not is_instance_valid(direction_node):
		print("ERROR: stair_raycast_origin or tunnel direction is not valid!")
		return
	
	var origin_global = stair_raycast_origin.global_position
	var target_global = direction_node.global_position
	var direction = (target_global - origin_global).normalized()
	var distance = origin_global.distance_to(target_global)
	
	print("Starting ", tunnel_type, " raycast from ", origin_global, " to ", target_global, " (distance: ", distance, ")")
	
	var space_state = get_world_3d().direct_space_state
	# Проверяем все слои (можно настроить collision_mask если нужно)
	# var collision_mask = 0xFFFFFFFF  # Все слои
	var collision_mask = 1
	
	# Выполняем множественный рейкаст для получения всех объектов на пути
	# Удаляем объекты сразу в каждом цикле
	var removed_anything := false
	var current_origin = origin_global
	var max_iterations = 100  # Защита от бесконечного цикла
	var iteration = 0
	
	while iteration < max_iterations:
		var query = PhysicsRayQueryParameters3D.create(current_origin, target_global)
		query.collision_mask = collision_mask
		
		# Исключаем уже удаленные объекты через exclude (массив RID)
		var result = space_state.intersect_ray(query)
		
		if not result:
			break
		
		var collider = result["collider"]
		if collider == null:
			break
		
		# var hit_point = result.get("position", current_origin)
		var hit_point = result["position"]
		print("Raycast hit: ", collider.name, " (type: ", collider.get_class(), ") at ", hit_point)
		
		# Проверяем, является ли объект солидом (стена, пол, потолок)
			# Сразу удаляем найденный объект
		# if is_instance_valid(collider) and collider is CSGLinearStairs3D == false:
		if is_instance_valid(collider):
			print("  -> Removing solid object: ", collider.name, " at ", collider.global_position)
			collider.queue_free()
			removed_anything = true
			# Ждем кадр после удаления для синхронизации
			await get_tree().process_frame
		
		# Продолжаем рейкаст от точки столкновения
		# Смещаемся немного вперед от точки столкновения по направлению к цели
		# var forward = (target_global - hit_point).normalized()
		# Увеличиваем шаг для более надежного прохождения через объекты
		# current_origin = hit_point + forward * 0.2
		
		# # Если достигли цели, выходим
		# if current_origin.distance_to(target_global) < 0.1:
		# 	break
		
		iteration += 1
	
	if removed_anything:
		emit_signal("tunnel_requested", self, origin_global, target_global, tunnel_type)


func _is_solid_object(obj: Node) -> bool:
	# Проверяем, является ли объект солидом (стена, пол, потолок)
	# Это могут быть CSG объекты или части DungeonTile (floor, ceiling, walls)
	
	# Проверяем, является ли это часть DungeonTile (floor, ceiling, walls)
	var parent = obj.get_parent()
	if parent != null and parent is DungeonTile:
		var obj_name = obj.name.to_lower()
		# Проверяем, является ли это floor, ceiling или wall
		if "floor" in obj_name or "ceiling" in obj_name or "wall" in obj_name:
			return true
		# Также проверяем дочерние элементы Node3D из DungeonTile
		if obj is Node3D:
			# Проверяем все дочерние CSG объекты
			for child in obj.get_children():
				if child is CSGShape3D or child is CSGCombiner3D:
					return true
	
	# Проверяем, является ли объект дочерним элементом floor/ceiling/wall из DungeonTile
	var current = obj
	for i in range(5):  # Проверяем до 5 уровней вверх
		if current == null:
			break
		var current_parent = current.get_parent()
		if current_parent != null and current_parent is DungeonTile:
			var current_name = current.name.to_lower()
			if "floor" in current_name or "ceiling" in current_name or "wall" in current_name:
				return true
		current = current_parent
	
	# Проверяем CSG объекты
	if obj is CSGShape3D or obj is CSGCombiner3D:
		var obj_name = obj.name.to_lower()
		# Проверяем имя на наличие ключевых слов
		if "wall" in obj_name or "floor" in obj_name or "ceiling" in obj_name:
			return true
		# Или если это часть dungeon tile
		if parent != null:
			var parent_name = parent.name.to_lower()
			if "tile" in parent_name or "dungeon" in parent_name:
				return true
			# Проверяем, является ли родитель частью DungeonTile
			if parent is DungeonTile:
				return true
	
	# Проверяем StaticBody3D
	if obj is StaticBody3D:
		var obj_name = obj.name.to_lower()
		if "wall" in obj_name or "floor" in obj_name or "ceiling" in obj_name:
			return true
	
	return false
