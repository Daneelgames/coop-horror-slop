extends StaticBody3D
class_name MainElevatorController
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var door_audio_stream_player_3d: AudioStreamPlayer3D = $DoorAudioStreamPlayer3D
@export var elevator_button: InteractiveButton
var bodies_inside: Array = []
var bodies_to_move_inside: Array = []
var is_open = false
var is_elevator_moving = false
@export var elevator_movement_speed : float = 20

func _ready() -> void:
	elevator_button.button_interacted.connect(on_elevator_button_interacted)
	# Установить authority лифта на сервер для управления состоянием
	if multiplayer.has_multiplayer_peer():
		set_multiplayer_authority(1)

func _physics_process(delta: float) -> void:
	if is_elevator_moving:
		# Двигать лифт локально на всех клиентах (включая хост)
		global_position.y += delta
		
		# Двигать тела внутри лифта
		var is_server = multiplayer.has_multiplayer_peer() and multiplayer.is_server()
		for body in bodies_to_move_inside:
			if not is_instance_valid(body):
				continue
			
			if is_server:
				# На хосте двигаем все тела внутри лифта
				body.global_position.y += delta
			else:
				# На клиентах двигаем только своего игрока (у которого есть authority)
				if body.is_multiplayer_authority():
					body.global_position.y += delta

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
		bodies_to_move_inside = bodies_inside.duplicate()
		bodies_inside = []
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
		rpc_set_elevator_moving.rpc(new_moving_state)
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
	bodies_inside.append(body)
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
	
func update_door_anim():
	if bodies_inside.size() > 0:
		animation_player.play('open', 0.2)
		if is_open == false:
			door_audio_stream_player_3d.play()
		is_open = true
	else:
		animation_player.play('close', 0.2)
		if is_open:
			door_audio_stream_player_3d.play()
		is_open = false

@rpc("authority", "call_local", "reliable")
func rpc_set_elevator_moving(moving: bool):
	# Синхронизация состояния движения лифта с клиентами
	is_elevator_moving = moving
	if not moving:
		# Остановка движения - очистить список тел для движения
		for body in bodies_to_move_inside:
			if body is PlayerCharacter:
				body.is_moving_by_elevator = true
		bodies_to_move_inside = []
		bodies_inside = []
		update_door_anim()
	else:
		# Начало движения
		# На сервере bodies_to_move_inside уже установлен в on_elevator_button_interacted()
		# На клиентах: сохраняем текущие тела внутри перед очисткой
		# (они могут отличаться от сервера, но мы будем двигать только своих игроков)
		if not (multiplayer.has_multiplayer_peer() and multiplayer.is_server()):
			bodies_to_move_inside = bodies_inside.duplicate()
			for body in bodies_to_move_inside:
				if body is PlayerCharacter:
					body.is_moving_by_elevator = true
		bodies_inside = []
		update_door_anim()
