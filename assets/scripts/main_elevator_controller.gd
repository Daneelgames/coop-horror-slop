extends StaticBody3D
class_name MainElevatorController
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var door_audio_stream_player_3d: AudioStreamPlayer3D = $DoorAudioStreamPlayer3D
@onready var elevator_area_3d: Area3D = $ElevatorArea3D
@export var elevator_button: InteractiveButton
var bodies_inside: Array = []
var bodies_to_move_inside: Array = []
var is_open = false
var is_elevator_moving = false
var is_elevator_moving_down = false
@export var elevator_movement_speed : float = 20
var elevator_movement_top_position: Vector3
var elevator_movement_bottom_position: Vector3

# Лифт двигается локально на всех клиентах
# Синхронизация происходит через rpc_set_elevator_moving
@export var sync_position: Vector3:
	set(value):
		if sync_position != value:
			var old_value = sync_position
			sync_position = value
			# На клиентах плавно корректировать позицию если разница большая
			if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
				var position_diff = global_position.y - value.y
				if abs(position_diff) > 0.5:  # Если разница больше 0.5 метра
					# Плавная коррекция вместо скачка
					global_position.y = lerp(global_position.y, value.y, 0.1)
					print("[ELEVATOR] sync_position setter (CLIENT): Smooth correction from %s to %s (diff: %s)" % [old_value.y, value.y, position_diff])
				# Для небольших расхождений не корректируем - пусть работает локально

func _ready() -> void:
	elevator_button.button_interacted.connect(on_elevator_button_interacted)

	# Инициализировать sync_position текущей позицией
	sync_position = global_position
	print("[ELEVATOR] _ready: Initialized position to %s, sync_position=%s, authority=%s, is_server=%s" % [
		global_position, sync_position, get_multiplayer_authority(), multiplayer.is_server()])

func _physics_process(delta: float) -> void:
	if is_elevator_moving:
		# Все клиенты двигают лифт локально
		# Проверить, что позиции инициализированы
		if elevator_movement_top_position == Vector3.ZERO and elevator_movement_bottom_position == Vector3.ZERO:
			push_warning("[ELEVATOR] Movement positions not initialized, cannot move")
			is_elevator_moving = false
			return

		# Определить направление движения и скорость
		var movement_direction: float = -1.0 if is_elevator_moving_down else 1.0
		var movement_distance = elevator_movement_speed * delta * movement_direction

		# Проверить, достиг ли лифт целевой позиции
		var target_position: Vector3
		if is_elevator_moving_down:
			target_position = elevator_movement_bottom_position
		else:
			target_position = elevator_movement_top_position

		# Проверить, достигли ли мы целевой позиции (с небольшой погрешностью)
		var distance_to_target = abs(global_position.y - target_position.y)
		if distance_to_target <= abs(movement_distance) + 0.1:  # Небольшая погрешность для остановки
			# Достигли целевой позиции - остановить лифт
			global_position.y = target_position.y
			sync_position = global_position

			# Остановить движение
			_stop_elevator_at_target()
		else:
			# Продолжить движение
			global_position.y += movement_distance
			sync_position = global_position

			# Двигать тела внутри лифта
			_move_bodies_inside(movement_distance)

func on_elevator_button_interacted():
	# Только сервер обрабатывает нажатие кнопки и синхронизирует состояние
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if is_elevator_moving:
		return
	
	var new_moving_state = not is_elevator_moving
	
	if new_moving_state:
		# Начало движения
		print("[ELEVATOR] Button pressed! Starting movement. bodies inside: ", bodies_inside.size())
		print("[ELEVATOR] Button pressed! bodies_inside content: ", bodies_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid"))
		
		# Определить направление движения на основе текущей позиции
		var distance_to_top = abs(global_position.y - elevator_movement_top_position.y)
		var distance_to_bottom = abs(global_position.y - elevator_movement_bottom_position.y)
		
		# Если лифт находится ближе к верхней позиции, движемся вниз
		if distance_to_top < distance_to_bottom:
			is_elevator_moving_down = true
			# Вызвать set_dark_environment когда начинаем движение вниз из верхней точки
			if is_instance_valid(GameManager) and is_instance_valid(GameManager._game_level):
				GameManager._game_level.set_dark_environment()
				print("[ELEVATOR] Called set_dark_environment() - starting movement down from top")
		else:
			is_elevator_moving_down = false
		
		bodies_to_move_inside = bodies_inside.duplicate()
		bodies_inside = []
		print("[ELEVATOR] Starting movement, bodies_to_move_inside: %s" % [bodies_to_move_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid")])
		
		# Установить is_moving_by_elevator = true для всех игроков на сервере
		# Для RigidBody3D (пикапов) заморозить физику чтобы они двигались вместе с лифтом
		for body in bodies_to_move_inside:
			if not is_instance_valid(body):
				continue
			if body is PlayerCharacter:
				body.is_moving_by_elevator = true
				body.rpc_full_heal_and_resurrect()
				print("[ELEVATOR] Set is_moving_by_elevator=true for player: ", body.name)
			elif body is RigidBody3D:
				# Заморозить RigidBody3D чтобы он двигался вместе с лифтом
				body.freeze = true
				print("[ELEVATOR] Frozen RigidBody3D for movement: ", body.name)
	else:
		# Остановка движения
		print("[ELEVATOR] Button pressed! Stopping movement.")
		bodies_to_move_inside = []
		bodies_inside = []
		for body in bodies_to_move_inside:
			if is_instance_valid(body) and body is RigidBody3D:
				body.freeze = true
	
	# Синхронизировать состояние с клиентами через RPC
	if multiplayer.has_multiplayer_peer():
		rpc_set_elevator_moving.rpc(new_moving_state, is_elevator_moving_down)
	else:
		# Single player: установить состояние локально
		is_elevator_moving = new_moving_state
		update_door_anim()

func _on_elevator_area_3d_body_entered(body: Node3D) -> void:
	if is_elevator_moving:
		return
	if body is AiCharacter:
		return
	if bodies_inside.has(body):
		return
	# Добавлять игроков и RigidBody3D объекты (пикапы) в bodies_inside
	if body is PlayerCharacter or body is RigidBody3D:
		bodies_inside.append(body)
		print("[ELEVATOR] Body entered: %s (authority: %s), bodies_inside size: %d" % [body.name, body.get("is_multiplayer_authority") if body is PlayerCharacter else "N/A", bodies_inside.size()])
		update_door_anim()


func _on_elevator_area_3d_body_exited(body: Node3D) -> void:
	if is_elevator_moving:
		return
	if body is AiCharacter:
		return
	if bodies_inside.has(body) == false:
		return
	bodies_inside.erase(body)
	update_door_anim()
	
func _stop_elevator_at_target():
	print("[ELEVATOR] _stop_elevator_at_target: Starting stop sequence")
	print("[ELEVATOR] _stop_elevator_at_target: bodies_to_move_inside before stop: ", bodies_to_move_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid"))

	# Остановить движение лифта
	is_elevator_moving = false

	# Определить достигли ли мы верхней позиции
	var distance_to_top = abs(global_position.y - elevator_movement_top_position.y)
	var is_at_top = distance_to_top < 0.5  # Небольшая погрешность

	# Если достигли верхней позиции, вызвать set_light_environment
	if is_at_top:
		if is_instance_valid(GameManager) and is_instance_valid(GameManager._game_level):
			GameManager._game_level.set_light_environment()
			print("[ELEVATOR] Reached top position - called set_light_environment()")

	# Сбросить направление движения
	is_elevator_moving_down = false

	# Установить is_moving_by_elevator = false для всех игроков внутри
	# Разморозить RigidBody3D объекты (пикапы) чтобы они могли нормально взаимодействовать с физикой
	for body in bodies_to_move_inside:
		if not is_instance_valid(body):
			continue
		if body is PlayerCharacter:
			body.is_moving_by_elevator = false
		elif body is RigidBody3D:
			# Разморозить RigidBody3D чтобы он мог нормально взаимодействовать с физикой
			body.freeze = false
			# Сбросить вертикальную скорость чтобы предотвратить падение
			body.linear_velocity.y = 0
			print("[ELEVATOR] Unfrozen RigidBody3D after stop: ", body.name)

	# Также сбросить is_moving_by_elevator для всех игроков в группе на сервере
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		var players = get_tree().get_nodes_in_group("players")
		for player in players:
			if player is PlayerCharacter and is_instance_valid(player):
				player.is_moving_by_elevator = false

	# Вернуть тела обратно в bodies_inside
	bodies_inside = bodies_to_move_inside.duplicate()
	bodies_to_move_inside = []

	print("[ELEVATOR] _stop_elevator_at_target: bodies_inside after copying from bodies_to_move_inside: ", bodies_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid"))

	# Проверить какие тела находятся в Area3D и добавить их в bodies_inside
	# Это исправляет проблему когда двери открываются но лифт не видит игроков
	if is_instance_valid(elevator_area_3d):
		# Временно включить monitoring чтобы получить overlapping bodies
		elevator_area_3d.monitoring = true
		await get_tree().process_frame  # Подождать чтобы physics обновил overlapping
		var overlapping_bodies = elevator_area_3d.get_overlapping_bodies()
		print("[ELEVATOR] _stop_elevator_at_target: overlapping_bodies: ", overlapping_bodies.map(func(b): return b.name if is_instance_valid(b) else "invalid"))
		for body in overlapping_bodies:
			if not is_instance_valid(body):
				continue
			if body is AiCharacter:
				continue
			if body is PlayerCharacter or body is RigidBody3D:
				if not bodies_inside.has(body):
					bodies_inside.append(body)
					print("[ELEVATOR] Added body to bodies_inside after stop: ", body.name)

	print("[ELEVATOR] _stop_elevator_at_target: final bodies_inside: ", bodies_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid"))

	# Обновить анимацию дверей
	update_door_anim()

	# Синхронизировать остановку с клиентами через RPC
	if multiplayer.has_multiplayer_peer():
		rpc_set_elevator_moving.rpc(false, is_elevator_moving_down)

	print("[ELEVATOR] Reached target position and stopped. Bodies inside: ", bodies_inside.size())

func _move_bodies_inside(movement_distance: float):
	# Двигать тела внутри лифта
	var is_server = multiplayer.has_multiplayer_peer() and multiplayer.is_server()

	for body in bodies_to_move_inside:
		if not is_instance_valid(body):
			continue

		if body is PlayerCharacter:
			# Игроки двигаются локально на всех клиентах
			body.global_position.y += movement_distance
		elif body is RigidBody3D:
			# Пикапы двигаются только на сервере
			if is_server:
				body.global_position.y += movement_distance
				# Также сбрасываем вертикальную скорость чтобы предотвратить падение
				if body.linear_velocity.y < 0:
					body.linear_velocity.y = 0

func _get_all_nodes_of_type(node: Node, type_name: String, result: Array):
	# Рекурсивно найти все ноды определенного типа
	if node.get_class() == type_name:
		result.append(node)

	for child in node.get_children():
		_get_all_nodes_of_type(child, type_name, result)

func update_door_anim():
	await get_tree().process_frame
	print("[ELEVATOR] update_door_anim: bodies_inside.size() = ", bodies_inside.size(), ", is_open = ", is_open)
	if bodies_inside.size() > 0:
		print("[ELEVATOR] update_door_anim: Opening doors")
		animation_player.play('open', 0.2)
		if is_open == false:
			door_audio_stream_player_3d.play()
		is_open = true
	else:
		print("[ELEVATOR] update_door_anim: Closing doors")
		animation_player.play('close', 0.2)
		if is_open:
			door_audio_stream_player_3d.play()
		is_open = false

@rpc("authority", "call_local", "reliable")
func rpc_set_elevator_moving(moving: bool, moving_down: bool = false):
	# Синхронизация состояния движения лифта с клиентами
	is_elevator_moving = moving
	is_elevator_moving_down = moving_down

	var is_server = multiplayer.has_multiplayer_peer() and multiplayer.is_server()

	if not moving:
		# Остановка движения - сбросить is_moving_by_elevator для всех игроков
		var players = get_tree().get_nodes_in_group("players")
		for player in players:
			if player is PlayerCharacter and is_instance_valid(player):
				player.is_moving_by_elevator = false

		# Разморозить RigidBody3D объекты
		for body in bodies_to_move_inside:
			if not is_instance_valid(body):
				continue
			if body is RigidBody3D and is_server:
				# Разморозить RigidBody3D объекты только на сервере
				body.freeze = false
				body.linear_velocity.y = 0

		# Вернуть тела обратно в bodies_inside
		bodies_inside = bodies_to_move_inside.duplicate()
		bodies_to_move_inside = []

		update_door_anim()
		elevator_area_3d.monitoring = true
	else:
		# Начало движения - определить тела для движения локально
		bodies_to_move_inside = bodies_inside.duplicate()
		bodies_inside = []

		print("[ELEVATOR] Starting movement, bodies_to_move_inside: %s" % [
			bodies_to_move_inside.map(func(b): return b.name if is_instance_valid(b) else "invalid")
		])

		for body in bodies_to_move_inside:
			if not is_instance_valid(body):
				continue
			if body is PlayerCharacter:
				body.is_moving_by_elevator = true
				body.rpc_full_heal_and_resurrect()
			elif body is RigidBody3D and is_server:
				# Заморозить RigidBody3D объекты только на сервере
				body.freeze = true

		update_door_anim()
		elevator_area_3d.monitoring = false
