extends PanelContainer
class_name PlayerInventorySlotsPanelContainer
@onready var v_box_container: VBoxContainer = $VBoxContainer

func update_inventory_items_ui(items, selected_index = null):
	for child in v_box_container.get_children():
		child.queue_free()
	
	await get_tree().process_frame
	var index = 0
	for key_name in items.keys():
		var new_label = Label.new()
		if index == selected_index:
			new_label.modulate = Color.YELLOW
		else:
			new_label.modulate = Color.WHITE
		new_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		new_label.text = key_name
		v_box_container.add_child(new_label)
		index += 1
	
