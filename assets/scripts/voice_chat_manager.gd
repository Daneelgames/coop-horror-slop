extends Control
class_name PlayerVoiceChatManager

# Ноды из сцены
@onready var microphone_player: AudioStreamPlayer = $MicrophonePlayer
@onready var talk_feedback_label: Label = $TalkFeedbackLabel

# Настройки голосового чата
const MAX_VOICE_DISTANCE: float = 60.0  # Максимальная дистанция слышимости
const VOICE_UPDATE_RATE: float = 0.02  # Проверка каждые 20ms (50 раз в секунду для Opus chunks)

# Состояние
var is_recording: bool = false
var opus_chunked_effect: AudioEffectOpusChunked
var voice_bus_index: int = -1
@export var character_node: PlayerCharacter

# Словарь для хранения AudioStreamPlayer3D для каждого игрока
var player_voice_players: Dictionary = {}  # peer_id -> AudioStreamPlayer3D
var player_opus_streams: Dictionary = {}  # peer_id -> AudioStreamOpusChunked

func _ready():
	# Находим Voice bus
	voice_bus_index = AudioServer.get_bus_index("Voice")
	if voice_bus_index == -1:
		push_error("VoiceChatManager: Voice bus not found! Please add it in Project Settings -> Audio -> Buses")
		return
	
	# Получаем AudioEffectOpusChunked из bus
	if AudioServer.get_bus_effect_count(voice_bus_index) > 0:
		opus_chunked_effect = AudioServer.get_bus_effect(voice_bus_index, 0) as AudioEffectOpusChunked
		if opus_chunked_effect == null:
			push_error("VoiceChatManager: AudioEffectOpusChunked not found on Voice bus! Make sure twovoip addon is installed.")
			return
	else:
		push_error("VoiceChatManager: No effects found on Voice bus! Please add AudioEffectOpusChunked.")
		return
	
	# Настраиваем микрофон
	var mic_stream = AudioStreamMicrophone.new()
	microphone_player.stream = mic_stream
	microphone_player.bus = "Voice"
	
	# Проверяем что Voice bus не замучен (muted)
	# Voice bus должен быть muted чтобы избежать feedback loop
	# Но это нормально - мы используем AudioEffectOpusChunked для захвата
	#if AudioServer.is_bus_mute(voice_bus_index):
		#print("VoiceChat: Voice bus is muted (this is normal to prevent feedback)")
	#else:
		#print("VoiceChat: Warning - Voice bus is not muted, may cause feedback!")
	
	# Проверяем что Opus эффект доступен
	#if opus_chunked_effect != null:
		#print("VoiceChat: OpusChunked effect initialized successfully")
	#else:
		#push_error("VoiceChat: Failed to get OpusChunked effect!")
	
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
	
	# Проверяем что микрофон настроен
	if microphone_player.stream == null:
		push_error("VoiceChat: Microphone stream is null!")
		is_recording = false
		return
	
	microphone_player.play()
	#print("VoiceChat: Started recording (microphone_player.playing: %s, opus_chunked_effect: %s)" % [microphone_player.playing, opus_chunked_effect != null])

func stop_recording():
	if not is_recording:
		talk_feedback_label.hide()
		return
	is_recording = false
	talk_feedback_label.hide()
	microphone_player.stop()
	
	# Сбрасываем encoder при остановке записи (очищаем буферы)
	if opus_chunked_effect != null:
		opus_chunked_effect.resetencoder(true)  # true = очистить буферы
	
	# Отправляем сигнал о прекращении передачи
	_stop_voice_rpc.rpc()
	#print("VoiceChat: Stopped recording")

func _voice_capture_loop():
	# Бесконечный цикл захвата и отправки голоса через Opus
	var loop_count = 0
	while true:
		await get_tree().create_timer(VOICE_UPDATE_RATE).timeout
		loop_count += 1
		
		# Проверяем authority перед захватом
		if character_node == null or not character_node.is_multiplayer_authority():
			continue
		
		if not is_recording:
			continue
		
		if opus_chunked_effect == null:
			if loop_count % 50 == 0:  # Логируем каждые 50 итераций (1 раз в секунду)
				print("VoiceChat: opus_chunked_effect is null!")
			continue
		
		# Проверяем доступность Opus пакетов
		var chunks_available = opus_chunked_effect.chunk_available()
		if chunks_available:
			var packets_sent = 0
			while opus_chunked_effect.chunk_available():
				# Читаем Opus пакет (без префикса)
				var prepend = PackedByteArray()
				var opus_data: PackedByteArray = opus_chunked_effect.read_opus_packet(prepend)
				opus_chunked_effect.drop_chunk()
				
				if opus_data.size() > 0:
					# Отправляем всем пирам (без call_local, чтобы не воспроизводить свой голос локально)
					# Используем rpc_id для отправки только другим пирам, не себе
					var local_id = multiplayer.get_unique_id()
					var peers = multiplayer.get_peers()
					
					if peers.size() > 0:
						# Отправляем каждому пиру отдельно
						for peer_id in peers:
							if peer_id != local_id:
								_send_voice_chunk_rpc.rpc_id(peer_id, opus_data)
					
					packets_sent += 1
					#if packets_sent == 1:  # Логируем только первый пакет в цикле
						#print("VoiceChat: Sent Opus packet, size: %d bytes to %d peers" % [opus_data.size(), peers.size()])
		#elif loop_count % 50 == 0:  # Логируем каждые 50 итераций если нет чанков
			#print("VoiceChat: No Opus chunks available (is_recording: %s, microphone_player.playing: %s)" % [is_recording, microphone_player.playing])

@rpc("any_peer", "unreliable")
func _send_voice_chunk_rpc(opus_data: PackedByteArray):
	var sender_id = multiplayer.get_remote_sender_id()
	var local_id = multiplayer.get_unique_id()
	
	# Если sender_id == 0, это локальный вызов (не должно происходить без call_local)
	# Но на всякий случай проверяем и игнорируем
	if sender_id == 0:
		print("VoiceChat: WARNING - Received local RPC call (should not happen)")
		return
	
	# Не воспроизводим свой собственный голос
	if sender_id == local_id:
		print("VoiceChat: Ignoring own voice packet (sender_id: %d == local_id: %d)" % [sender_id, local_id])
		return
	
	#print("VoiceChat: Received Opus packet from peer %d, size: %d bytes (local_id: %d)" % [sender_id, opus_data.size(), local_id])
	
	# Рассчитываем расстояние до отправителя
	var distance = _get_player_distance(sender_id)
	
	if distance <= MAX_VOICE_DISTANCE:
		# Воспроизводим голос с учетом расстояния
		_play_voice_chunk(sender_id, opus_data, distance)
		#print("VoiceChat: Playing voice from peer %d at distance %.2f" % [sender_id, distance])
	#else:
		#print("VoiceChat: Peer %d too far (%.2f > %.2f)" % [sender_id, distance, MAX_VOICE_DISTANCE])

func _get_player_distance(peer_id: int) -> float:
	# Получаем позиции игроков
	var local_id = multiplayer.get_unique_id()
	var local_player = GameManager._player_nodes.get(local_id)
	var remote_player = GameManager._player_nodes.get(peer_id)
	
	if local_player == null or remote_player == null:
		return MAX_VOICE_DISTANCE + 1.0
	
	return local_player.global_position.distance_to(remote_player.global_position)

func _play_voice_chunk(peer_id: int, opus_data: PackedByteArray, distance: float):
	# Создаем или получаем AudioStreamPlayer3D и AudioStreamOpusChunked для этого игрока
	var voice_player: AudioStreamPlayer3D
	var opus_stream: AudioStreamOpusChunked
	
	if not player_voice_players.has(peer_id):
		var player_node = GameManager._player_nodes.get(peer_id)
		if player_node == null:
			return
		
		# Ищем существующий AudioStreamPlayer3D в ноде Head игрока
		var head_node = player_node.get_node_or_null("Head")
		if head_node == null:
			push_error("VoiceChat: Head node not found for peer %d" % peer_id)
			return
		
		voice_player = head_node.get_node_or_null("VoicePlayer3D") as AudioStreamPlayer3D
		if voice_player == null:
			push_error("VoiceChat: VoicePlayer3D not found in Head node for peer %d" % peer_id)
			return
		
		# Создаем AudioStreamOpusChunked для декодирования
		opus_stream = AudioStreamOpusChunked.new()
		player_opus_streams[peer_id] = opus_stream
		
		# Настраиваем существующий AudioStreamPlayer3D
		voice_player.stream = opus_stream
		# Настройки уже заданы в character.tscn, но убедимся что они правильные
		voice_player.max_distance = MAX_VOICE_DISTANCE
		voice_player.bus = "VoicePlayback"
		
		player_voice_players[peer_id] = voice_player
		
		# Запускаем воспроизведение
		voice_player.play()
		print("VoiceChat: Using existing VoicePlayer3D for peer %d at position %s, bus: %s, playing: %s" % [
			peer_id, 
			str(voice_player.global_position), 
			voice_player.bus,
			voice_player.playing
		])
	else:
		voice_player = player_voice_players[peer_id]
		opus_stream = player_opus_streams[peer_id]
	
	if voice_player == null or opus_stream == null:
		return
	
	# Убеждаемся что AudioStreamPlayer3D играет (должен играть постоянно для Opus потока)
	if not voice_player.playing:
		voice_player.play()
		print("VoiceChat: Restarted playback for peer %d (was stopped)" % peer_id)
	
	# Настраиваем громкость по расстоянию (proximity effect)
	var volume_factor = 1.0 - (distance / MAX_VOICE_DISTANCE)
	volume_factor = clamp(volume_factor, 0.0, 1.0)
	voice_player.volume_db = linear_to_db(volume_factor * 0.7)  # Немного тише для комфорта
	
	# Добавляем Opus пакет в поток для декодирования
	if opus_stream.chunk_space_available():
		# FEC (Forward Error Correction) = 0, так как мы не знаем о потерях пакетов
		opus_stream.push_opus_packet(opus_data, 0, 0)
	else:
		print("VoiceChat: WARNING - Opus stream chunk space not available for peer %d" % peer_id)

@rpc("any_peer", "reliable")
func _stop_voice_rpc():
	var sender_id = multiplayer.get_remote_sender_id()
	# НЕ останавливаем AudioStreamPlayer3D полностью, так как это прервет поток
	# Вместо этого просто перестаем добавлять новые пакеты
	# AudioStreamOpusChunked сам закончит воспроизведение когда буфер опустеет
	if player_voice_players.has(sender_id):
		var player = player_voice_players[sender_id]
		if player:
			# Не останавливаем плеер - пусть доиграет буфер
			# player.stop()  # Закомментировано - не останавливаем
			print("VoiceChat: Received stop signal from peer %d, keeping playback active until buffer empties" % sender_id)
		if player_opus_streams.has(sender_id):
			var opus_stream = player_opus_streams[sender_id]
			if opus_stream:
				# AudioStreamOpusChunked автоматически закончит воспроизведение когда буфер опустеет
				pass

func _on_peer_connected(peer_id: int):
	print("VoiceChat: Peer %d connected" % peer_id)

func _on_peer_disconnected(peer_id: int):
	if player_voice_players.has(peer_id):
		var player = player_voice_players[peer_id]
		if player:
			# Останавливаем воспроизведение, но НЕ удаляем нод (он часть character.tscn)
			player.stop()
			player.stream = null  # Очищаем stream
		player_voice_players.erase(peer_id)
	
	if player_opus_streams.has(peer_id):
		# Очищаем ссылку на Opus stream
		player_opus_streams.erase(peer_id)
	
	print("VoiceChat: Peer %d disconnected" % peer_id)
