extends StaticBody3D
class_name ShopController
@onready var selling_table_static_body_3d: InteractiveButton = %SellingTableStaticBody3D
@onready var party_money_label_3d: Label3D = %PartyMoneyLabel3D
@export var weapons_on_sell : Array[ResourceWeapon]
@export var items_for_sale_parent : Node3D
func _ready() -> void:
	GameManager.party_money_changed.connect(update_party_money)
	selling_table_static_body_3d.button_interacted.connect(on_selling_table_button_interacted)
	update_party_money()
	spawn_items_for_sell()
func spawn_items_for_sell():
	for index in weapons_on_sell.size():
		var rw : ResourceWeapon = weapons_on_sell[index]
		var new_pickup : InteractivePickup = load(rw.pickup_prefab_path).instantiate()
		items_for_sale_parent.get_child(index).add_child(new_pickup)
		new_pickup.weapon_resource = rw.duplicate(true)  # Deep duplicate to preserve all properties
		new_pickup.is_item_for_sale = true
		new_pickup.position = Vector3.ZERO
		new_pickup.rotation_degrees = Vector3.ZERO

func on_selling_table_button_interacted(_player_id: int):
	# Handle selling table interaction for specific player
	print("[SHOP] Selling table interacted by player %d" % _player_id)

	if multiplayer.is_server():
		print("[SHOP] Server processing directly")
		_process_sell_request(_player_id)
	else:
		print("[SHOP] Calling RPC for selling...")
		rpc_local_player_tries_selling_item_in_hands.rpc(_player_id)
		print("[SHOP] RPC call completed")
	pass

func _process_sell_request(player_id: int):
	# Handle selling table interaction for specific player
	# Only server should process this
	print("[SHOP] Processing sell request for player %d, is_server: %s" % [player_id, multiplayer.is_server()])
	if !multiplayer.is_server():
		print("[SHOP] Not server, ignoring")
		return

	print("[SHOP] Server processing sell request for player %d" % player_id)

	# найди игрока по id игрока и вызови функцию try_selling_item_in_hands
	if GameManager._player_nodes.has(player_id):
		var player = GameManager._player_nodes[player_id]
		print("[SHOP] Found player %d, calling try_selling_item_in_hands" % player_id)
		player.try_selling_item_in_hands()
	else:
		print("[SHOP] Player %d not found in _player_nodes" % player_id)

@rpc("any_peer")
func rpc_local_player_tries_selling_item_in_hands(player_id: int):
	# Handle selling table interaction for specific player
	_process_sell_request(player_id)
		
@onready var money_audio_stream_player_3d: AudioStreamPlayer3D = %MoneyAudioStreamPlayer3D

func update_party_money():
	party_money_label_3d.text = '%s MONIES AVAILABLE'%GameManager.party_money
	money_audio_stream_player_3d.play()
	pass
