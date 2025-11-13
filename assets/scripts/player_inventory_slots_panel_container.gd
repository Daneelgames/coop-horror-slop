extends PanelContainer
class_name PlayerInventorySlotsPanelContainer
@onready var v_box_container: VBoxContainer = $VBoxContainer

# Store references to labels by item key for efficient updates
var item_labels: Dictionary = {}

func update_inventory_items_ui(items, selected_index = null):
	# Clear existing labels
	for child in v_box_container.get_children():
		child.queue_free()
	item_labels.clear()
	
	await get_tree().process_frame
	var index = 0
	for key_name in items.keys():
		var weapon_resource = items[key_name] as ResourceWeapon
		var new_label = Label.new()
		if index == selected_index:
			new_label.modulate = Color.YELLOW
		else:
			new_label.modulate = Color.WHITE
		new_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		
		# Format text with durability percentage
		var durability_text = _format_item_text(key_name, weapon_resource)
		new_label.text = durability_text
		
		v_box_container.add_child(new_label)
		item_labels[key_name] = new_label
		index += 1

func _format_item_text(item_name: StringName, weapon_resource: ResourceWeapon) -> String:
	if weapon_resource == null:
		return str(item_name)
	
	var durability_percent = 0.0
	if weapon_resource.weapon_durability_max > 0:
		durability_percent = (weapon_resource.weapon_durability_current / weapon_resource.weapon_durability_max) * 100.0
	
	return "%s (%.0f%%)" % [item_name, durability_percent]

func update_durability_display(items):
	# Update durability text for existing labels without recreating them
	for key_name in items.keys():
		if item_labels.has(key_name):
			var weapon_resource = items[key_name] as ResourceWeapon
			var label = item_labels[key_name]
			if label != null and is_instance_valid(label):
				var old_text = label.text
				var new_text = _format_item_text(key_name, weapon_resource)
				label.text = new_text
				# Debug output when text changes
				if old_text != new_text and weapon_resource != null:
					print("[UI UPDATE] %s: %s -> %s (durability: %.2f/%.2f)" % [
						key_name,
						old_text,
						new_text,
						weapon_resource.weapon_durability_current,
						weapon_resource.weapon_durability_max
					])
	
