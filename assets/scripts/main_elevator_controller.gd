extends StaticBody3D
class_name MainElevatorController
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var door_audio_stream_player_3d: AudioStreamPlayer3D = $DoorAudioStreamPlayer3D
@export var elevator_button: InteractiveButton
var bodies_inside: Array = []
var bodies_to_move_inside: Array = []
var is_open = false
var is_elevator_moving = false

func _ready() -> void:
	elevator_button.button_interacted.connect(on_elevator_button_interacted)

func on_elevator_button_interacted():
	# Только на сервере выполняем логику репарентинга
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	
	if is_elevator_moving:
		return
	is_elevator_moving = true
	print("[ELEVATOR] Button pressed! bodies inside: ", bodies_inside.size())
	
	# Зарепарентить всех персонажей внутри лифта
	#for character in characters_inside:
		#if is_instance_valid(character) and character.get_parent() != self:
			#print("[ELEVATOR] Reparenting character: ", character.name)
			#var old_parent = character.get_parent()
			#if old_parent:
				#old_parent.remove_child(character)
			#self.add_child(character)
			## Сохраняем глобальную позицию после репарентинга
			#character.set_multiplayer_authority(1)
	
	# Найти все интерактивные пикапы внутри области лифта
	# Используем ShapeCast3D или получаем объекты через Area3D
	# var elevator_area = $ElevatorArea3D if has_node("ElevatorArea3D") else null
	# if elevator_area:
	# 	# Получаем все тела, которые перекрываются с областью лифта
	# 	var overlapping_bodies = elevator_area.get_overlapping_bodies()
	# 	for body in overlapping_bodies:
	# 		# Проверяем, является ли это интерактивным пикапом
	# 		if body is InteractivePickup and body.get_parent() != self:
	# 			print("[ELEVATOR] Reparenting pickup: ", body.name)
	# 			var old_parent = body.get_parent()
	# 			if old_parent:
	# 				old_parent.remove_child(body)
	# 			self.add_child(body)
	# 			# Сохраняем authority на сервере
	# 			body.set_multiplayer_authority(1)

	bodies_to_move_inside = bodies_inside
	bodies_inside = []
	update_door_anim()
	# TODO: Дальше добавить логику перемещения лифта со всем содержимым

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
