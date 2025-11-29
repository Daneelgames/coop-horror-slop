extends StaticBody3D
class_name InteractiveButton

signal button_interacted

@rpc("any_peer", "call_local")
func rpc_request_interaction(player_id: int):
	# Emit signal on all clients and host with player ID
	button_interacted.emit(player_id)
