extends StaticBody3D
class_name InteractiveButton

signal button_interacted

@rpc("any_peer")
func rpc_request_interaction(player_id: int):
	# Emit signal on server only (called from clients)
	print("[BUTTON] RPC received, emitting button_interacted for player %d" % player_id)
	button_interacted.emit(player_id)
