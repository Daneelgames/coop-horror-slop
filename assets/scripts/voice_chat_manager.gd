extends Control
class_name PlayerVoiceChatManager

# Ноды из сцены
@onready var microphone_player: AudioStreamPlayer = $MicrophonePlayer
@onready var talk_feedback_label: Label = $TalkFeedbackLabel

# Настройки голосового чата
const VOICE_SAMPLE_RATE: int = 16000  # 16kHz для голоса
const CHUNK_SIZE: int = 1024  # Размер чанка в сэмплах (~64ms при 16kHz)
const MAX_VOICE_DISTANCE: float = 20.0  # Максимальная дистанция слышимости
const VOICE_UPDATE_RATE: float = 0.05  # Отправка каждые 50ms (20 раз в секунду)

# Состояние
var is_recording: bool = false
var voice_capture_effect: AudioEffectCapture
var voice_bus_index: int = -1
@export var character_node: PlayerCharacter

# Словарь для хранения AudioStreamPlayer3D для каждого игрока
var player_voice_players: Dictionary = {}  # peer_id -> AudioStreamPlayer3D

func _ready():
	# Получаем ссылку на character для проверки authority
	# Структура: Character -> UserInterface -> VoiceChatManager
	# Находим или создаем Voice bus
	voice_bus_index = AudioServer.get_bus_index("Voice")
	if voice_bus_index == -1:
		push_error("VoiceChatManager: Voice bus not found! Please add it in Project Settings -> Audio -> Buses")
		return
	
	# Получаем AudioEffectCapture из bus
	if AudioServer.get_bus_effect_count(voice_bus_index) > 0:
		voice_capture_effect = AudioServer.get_bus_effect(voice_bus_index, 0) as AudioEffectCapture
		if voice_capture_effect == null:
			push_error("VoiceChatManager: AudioEffectCapture not found on Voice bus!")
			return
	else:
		push_error("VoiceChatManager: No effects found on Voice bus! Please add AudioEffectCapture.")
		return
	
	# Настраиваем микрофон
	var mic_stream = AudioStreamMicrophone.new()
	microphone_player.stream = mic_stream
	microphone_player.bus = "Voice"
	
	# Подключаемся к сигналам мультиплеера
	if multiplayer.has_multiplayer_peer():
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Запускаем процесс захвата голоса
	_voice_capture_loop()

func _input(event):
	# Проверяем что это локальный игрок (имеет authority)
	if character_node == null:
		return
	if not character_node.is_multiplayer_authority():
		return
	
	# Push-to-talk: зажать T для разговора
	if event.is_action_pressed("talk"):
		print('talk input pressed')
		start_recording()
	elif event.is_action_released("talk"):
		print('talk input released')
		stop_recording()

func start_recording():
	# Проверяем authority
	if character_node == null or not character_node.is_multiplayer_authority():
		return
	
	if is_recording:
		talk_feedback_label.show()
		return
	talk_feedback_label.show()
	is_recording = true
	microphone_player.play()
	print("VoiceChat: Started recording")

func stop_recording():
	if not is_recording:
		talk_feedback_label.hide()
		return
	is_recording = false
	talk_feedback_label.hide()
	microphone_player.stop()
	# Отправляем сигнал о прекращении передачи
	_stop_voice_rpc.rpc()
	print("VoiceChat: Stopped recording")

func _voice_capture_loop():
	# Бесконечный цикл захвата и отправки голоса
	while true:
		await get_tree().create_timer(VOICE_UPDATE_RATE).timeout
		
		# Проверяем authority перед захватом
		if character_node == null or not character_node.is_multiplayer_authority():
			continue
		
		if not is_recording or voice_capture_effect == null:
			continue
		
		# Проверяем доступность данных
		var frames_available = voice_capture_effect.get_frames_available()
		if frames_available < CHUNK_SIZE:
			continue
		
		# Получаем буфер (стерео)
		var stereo_buffer = voice_capture_effect.get_buffer(CHUNK_SIZE)
		if stereo_buffer.size() == 0:
			continue
		
		# Конвертируем стерео в моно (берем левый канал)
		var mono_data = _stereo_to_mono_pcm16(stereo_buffer)
		
		if mono_data.size() > 0:
			# Отправляем всем пирам
			_send_voice_chunk_rpc.rpc(mono_data)

func _stereo_to_mono_pcm16(stereo_buffer: PackedVector2Array) -> PackedByteArray:
	# Конвертируем стерео Vector2 в моно PCM16
	var bytes = PackedByteArray()
	bytes.resize(stereo_buffer.size() * 2)  # 2 байта на сэмпл (16-bit)
	
	var index = 0
	for vec in stereo_buffer:
		# Берем левый канал (x) и конвертируем в 16-bit integer
		var sample = int(clamp(vec.x * 32767.0, -32768, 32767))
		bytes[index] = sample & 0xFF  # Младший байт
		bytes[index + 1] = (sample >> 8) & 0xFF  # Старший байт
		index += 2
	
	return bytes

@rpc("any_peer", "unreliable", "call_local")
func _send_voice_chunk_rpc(audio_data: PackedByteArray):
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = multiplayer.get_unique_id()
	
	# Не воспроизводим свой собственный голос
	if sender_id == multiplayer.get_unique_id():
		return
	
	# Рассчитываем расстояние до отправителя
	var distance = _get_player_distance(sender_id)
	
	if distance <= MAX_VOICE_DISTANCE:
		# Воспроизводим голос с учетом расстояния
		_play_voice_chunk(sender_id, audio_data, distance)

func _get_player_distance(peer_id: int) -> float:
	# Получаем позиции игроков
	var local_id = multiplayer.get_unique_id()
	var local_player = GameManager._player_nodes.get(local_id)
	var remote_player = GameManager._player_nodes.get(peer_id)
	
	if local_player == null or remote_player == null:
		return MAX_VOICE_DISTANCE + 1.0
	
	return local_player.global_position.distance_to(remote_player.global_position)

func _play_voice_chunk(peer_id: int, pcm_data: PackedByteArray, distance: float):
	# Создаем или получаем AudioStreamPlayer3D для этого игрока
	if not player_voice_players.has(peer_id):
		var player_node = GameManager._player_nodes.get(peer_id)
		if player_node == null:
			return
		
		var voice_player = AudioStreamPlayer3D.new()
		voice_player.name = "VoicePlayer_%d" % peer_id
		voice_player.bus = "Voice"
		voice_player.max_distance = MAX_VOICE_DISTANCE
		voice_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		voice_player.unit_size = 1.0
		player_node.add_child(voice_player)
		player_voice_players[peer_id] = voice_player
	
	var voice_player = player_voice_players[peer_id]
	if voice_player == null:
		return
	
	# Создаем AudioStreamWAV из PCM данных
	var audio_stream = AudioStreamWAV.new()
	audio_stream.format = AudioStreamWAV.FORMAT_16_BITS
	audio_stream.mix_rate = VOICE_SAMPLE_RATE
	audio_stream.stereo = false
	audio_stream.data = pcm_data
	
	# Настраиваем громкость по расстоянию (proximity effect)
	var volume_factor = 1.0 - (distance / MAX_VOICE_DISTANCE)
	volume_factor = clamp(volume_factor, 0.0, 1.0)
	voice_player.volume_db = linear_to_db(volume_factor * 0.7)  # Немного тише для комфорта
	
	# Воспроизводим
	voice_player.stream = audio_stream
	voice_player.play()

@rpc("any_peer", "reliable")
func _stop_voice_rpc():
	var sender_id = multiplayer.get_remote_sender_id()
	if player_voice_players.has(sender_id):
		var player = player_voice_players[sender_id]
		if player:
			player.stop()

func _on_peer_connected(peer_id: int):
	print("VoiceChat: Peer %d connected" % peer_id)

func _on_peer_disconnected(peer_id: int):
	if player_voice_players.has(peer_id):
		var player = player_voice_players[peer_id]
		if player:
			player.queue_free()
		player_voice_players.erase(peer_id)
	print("VoiceChat: Peer %d disconnected" % peer_id)
