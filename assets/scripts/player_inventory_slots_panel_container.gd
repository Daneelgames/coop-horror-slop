extends PanelContainer
class_name PlayerInventorySlotsPanelContainer
@onready var v_box_container: VBoxContainer = $VBoxContainer

func update_inventory_items_ui(items: Dictionary[StringName, StringName]):
	for child in v_box_container.get_children():
		child.queue_free()
	
	await get_tree().process_frame
	for interactive_name in items.keys():
		var new_label = Label.new()
		new_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		new_label.text = interactive_name
		v_box_container.add_child(new_label)
	
