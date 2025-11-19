extends StaticBody3D
class_name InteractiveButton

signal button_interacted

@rpc("any_peer", "call_local")
func rpc_request_interaction():
	# Emit signal on all clients and host
	button_interacted.emit()
