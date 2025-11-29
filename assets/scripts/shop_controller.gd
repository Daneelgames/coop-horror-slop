extends StaticBody3D
class_name ShopController
@onready var selling_table_static_body_3d: InteractiveButton = %SellingTableStaticBody3D
@onready var party_money_label_3d: Label3D = %PartyMoneyLabel3D

func _ready() -> void:
	GameManager.party_money_changed.connect(update_party_money)
	selling_table_static_body_3d.button_interacted.connect(on_selling_table_button_interacted)
	update_party_money()

func on_selling_table_button_interacted(_player_id: int):
	# Handle selling table interaction for specific player
	rpc_local_player_tries_selling_item_in_hands.rpc(_player_id)
	pass

@rpc("any_peer", "call_local")
func rpc_local_player_tries_selling_item_in_hands(player_id: int):
	# Handle selling table interaction for specific player
	# найди игрока по id игрока и вызови функцию try_selling_item_in_hands
	if GameManager._player_nodes.has(player_id):
		var player = GameManager._player_nodes[player_id]
		player.try_selling_item_in_hands()
		
@onready var money_audio_stream_player_3d: AudioStreamPlayer3D = %MoneyAudioStreamPlayer3D

func update_party_money():
	party_money_label_3d.text = '%s MONIES AVAILABLE'%GameManager.party_money
	money_audio_stream_player_3d.play()
	pass
