extends StaticBody3D

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var door_audio_stream_player_3d: AudioStreamPlayer3D = $DoorAudioStreamPlayer3D

var characters_inside : Array[CharacterBody3D]
var is_open = false

func _on_elevator_area_3d_body_entered(body: Node3D) -> void:
	if characters_inside.has(body):
		return
	if body is CharacterBody3D:
		characters_inside.append(body)
		update_door_anim()


func _on_elevator_area_3d_body_exited(body: Node3D) -> void:
	if characters_inside.has(body) == false:
		return
	characters_inside.erase(body)
	update_door_anim()
	
func update_door_anim():
	if characters_inside.size() > 0:
		animation_player.play('open', 0.2)
		if is_open == false:
			door_audio_stream_player_3d.play()
		is_open = true
	else:
		animation_player.play('close', 0.2)
		if is_open:
			door_audio_stream_player_3d.play()
		is_open = false
