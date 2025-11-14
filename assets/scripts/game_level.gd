extends NavigationRegion3D

@export var is_game_level_ready = false
@export var level_generator : ProceduralDungeon

func _ready() -> void:
	is_game_level_ready = false
	GameManager._game_level = self
	level_generator.generate_dungeon()
	await level_generator.level_generated
	bake_navigation_mesh()
	await bake_finished
	is_game_level_ready = true
	if multiplayer.is_server():
		place_players_into_first_room.rpc()
	
@rpc("authority", "call_local")
func place_players_into_first_room():
	# host and clients players should be placed on random tiles of first spawned room
	# Only server should execute this to ensure consistent placement
	if not multiplayer.is_server():
		return
	
	# Check if level_generator is ProceduralDungeon
	if not level_generator is ProceduralDungeon:
		push_warning("place_players_into_first_room: level_generator is not ProceduralDungeon")
		return
	
	var procedural_dungeon: ProceduralDungeon = level_generator as ProceduralDungeon
	
	# Get the first room
	if procedural_dungeon.rooms_resources.is_empty():
		push_warning("place_players_into_first_room: No rooms available")
		return
	
	var first_room = procedural_dungeon.rooms_resources[0]
	
	# Get tiles from the first room
	if not procedural_dungeon.spawned_room_tiles.has(first_room):
		push_warning("place_players_into_first_room: First room has no tiles")
		return
	
	var room_tiles: Array = procedural_dungeon.spawned_room_tiles[first_room]
	if room_tiles.is_empty():
		push_warning("place_players_into_first_room: First room tiles array is empty")
		return
	
	# Filter tiles that have floors (so players can stand on them)
	var tiles_with_floors: Array = []
	for tile in room_tiles:
		if not is_instance_valid(tile):
			continue
		if is_instance_valid(tile.floor):
			tiles_with_floors.append(tile)
	
	if tiles_with_floors.is_empty():
		push_warning("place_players_into_first_room: No tiles with floors found in first room")
		return
	
	# Get all players from GameManager
	var players_to_place: Array = []
	for peer_id in GameManager._player_nodes.keys():
		var player = GameManager._player_nodes[peer_id]
		if is_instance_valid(player):
			players_to_place.append(player)
	
	if players_to_place.is_empty():
		push_warning("place_players_into_first_room: No players found to place")
		return
	
	# Place each player on a random tile from the first room
	# Shuffle tiles to ensure different positions for each player
	tiles_with_floors.shuffle()
	
	for i in range(players_to_place.size()):
		var player = players_to_place[i]
		var tile_index = i % tiles_with_floors.size()
		var tile: DungeonTile = tiles_with_floors[tile_index]
		
		# Place player on the tile's position (tile position is at bottom center)
		# Add some height offset so player stands on the floor
		var spawn_position = tile.position + Vector3(0, 1.0, 0)  # 1 unit above tile center
		player.global_position = spawn_position
		
		print("Placed player %s at position %s (tile coord: %s)" % [player.name, spawn_position, tile.coord])
