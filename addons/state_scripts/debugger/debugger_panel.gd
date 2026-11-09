@tool
extends HSplitContainer
## The State Scripts tab of the editor's Debugger dock. It lists the machines of
## the running game by category, and the states of the selected one.

const Model := preload("debugger_model.gd")

const _FALLBACK_ACCENT := Color(0.44, 0.73, 0.98)
const _DIM := 0.6

var model: Model:
	set(value):
		if model:
			model.changed.disconnect(_on_changed)
			model.removed.disconnect(_on_removed)
		model = value
		if model:
			model.changed.connect(_on_changed)
			model.removed.connect(_on_removed)
		_rebuild()

var _machines := Tree.new()
var _empty := Label.new()
var _title := Label.new()
var _status := Label.new()
var _states := Tree.new()
var _selected := 0
# Machine id to its row, and a category's key, such as "Enemies/Flying", to
# its row. Rows are updated in place, so a game with many machines does not
# rebuild the list on every transition.
var _machine_rows: Dictionary = {}
var _category_rows: Dictionary = {}
# Keys of the categories the user collapsed, kept across runs of the game.
var _collapsed: Dictionary = {}
# The selected machine's current state in _states, whose time counts up.
var _current_row: TreeItem
var _bold: Font
var _italic: Font


func _init() -> void:
	name = "State Scripts"
	split_offsets = PackedInt32Array([300])

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 200
	add_child(left)
	_machines.columns = 2
	_machines.hide_root = true
	_machines.column_titles_visible = true
	_machines.set_column_title(0, "Machine")
	_machines.set_column_title(1, "State")
	_machines.set_column_expand_ratio(0, 3)
	_machines.size_flags_vertical = SIZE_EXPAND_FILL
	_machines.item_selected.connect(_on_machine_selected)
	_machines.item_collapsed.connect(_on_item_collapsed)
	left.add_child(_machines)

	var right := VBoxContainer.new()
	add_child(right)
	_empty.text = "Run the project to see its state machines here."
	_empty.modulate.a = _DIM
	right.add_child(_empty)
	right.add_child(_title)
	_status.modulate.a = _DIM
	right.add_child(_status)
	_states.columns = 2
	_states.hide_root = true
	_states.column_titles_visible = true
	_states.set_column_title(0, "State")
	_states.set_column_title(1, "Time in state")
	_states.set_column_expand_ratio(0, 2)
	_states.select_mode = Tree.SELECT_ROW
	_states.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(_states)
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_bold = null
		_italic = null
		_show_selected()


func _process(_delta: float) -> void:
	if is_visible_in_tree() and _current_row:
		_show_time()


func _rebuild() -> void:
	_machines.clear()
	_machine_rows.clear()
	_category_rows.clear()
	_machines.create_item()
	var machines: Dictionary = model.machines if model else {}
	for id: int in machines:
		_place(id)
	_update_counts()
	if not machines.has(_selected):
		_selected = 0
	_show_selected()


func _on_changed(id: int) -> void:
	if id == 0:
		_rebuild()
		return
	if not model.machines.has(id):
		return
	var added := not _machine_rows.has(id)
	_place(id)
	if added:
		_update_counts()
	if added or id == _selected:
		_show_selected()


func _on_removed(id: int) -> void:
	var row: TreeItem = _machine_rows.get(id)
	if row:
		var parent := row.get_parent()
		_machine_rows.erase(id)
		row.free()
		_prune(parent)
		_update_counts()
	if id == _selected:
		_selected = 0
		_show_selected()


# Adds or updates the machine's row, under the rows of its categories.
func _place(id: int) -> void:
	var machine: Dictionary = model.machines[id]
	var parent := _category_row(Model.category_path(machine.category))
	var row: TreeItem = _machine_rows.get(id)
	if row and row.get_parent() != parent:
		# Its category arrived after its first transition.
		var old_parent := row.get_parent()
		row.free()
		_prune(old_parent)
		row = null
	if row == null:
		row = _machines.create_item(parent)
		row.set_metadata(0, id)
		_machine_rows[id] = row
		_sort_into_place(row)
		if id == _selected:
			row.select(0)
	row.set_text(0, machine.path + (" (freed)" if machine.freed else ""))
	row.set_tooltip_text(0, machine.path)
	row.set_text(1, machine.current)
	if machine.freed:
		for column in 2:
			row.set_custom_color(column, _dimmed())


func _category_row(path: PackedStringArray) -> TreeItem:
	var row := _machines.get_root()
	var key := ""
	for part in path:
		key = part if key.is_empty() else key + "/" + part
		if not _category_rows.has(key):
			var child := _machines.create_item(row)
			child.set_metadata(0, key)
			child.set_selectable(0, false)
			child.set_selectable(1, false)
			child.collapsed = _collapsed.has(key)
			_category_rows[key] = child
			_sort_into_place(child)
		row = _category_rows[key]
	return row


# Categories come before machines, each in natural order, so Bat2 is before Bat10.
func _sort_into_place(row: TreeItem) -> void:
	var key := _sort_key(row)
	for sibling in row.get_parent().get_children():
		if sibling != row and key.naturalnocasecmp_to(_sort_key(sibling)) < 0:
			row.move_before(sibling)
			return


func _sort_key(row: TreeItem) -> String:
	var metadata: Variant = row.get_metadata(0)
	if metadata is String:
		return "0" + metadata.get_file()
	return "1" + model.machines[metadata].path if model.machines.has(metadata) else "1"


# Removes category rows left with nothing in them.
func _prune(row: TreeItem) -> void:
	while row and row != _machines.get_root() and row.get_child_count() == 0:
		var parent := row.get_parent()
		_category_rows.erase(row.get_metadata(0))
		row.free()
		row = parent


func _update_counts() -> void:
	_count(_machines.get_root())
	_empty.visible = _machine_rows.is_empty()


# Shows how many machines each category holds, nested ones included.
func _count(row: TreeItem) -> int:
	var total := 0
	for child in row.get_children():
		if child.get_metadata(0) is String:
			total += _count(child)
		else:
			total += 1
	var key: Variant = row.get_metadata(0)
	if key is String:
		row.set_text(0, "%s  (%d)" % [key.get_file(), total])
	return total


func _on_machine_selected() -> void:
	var row := _machines.get_selected()
	if row and row.get_metadata(0) is int and row.get_metadata(0) != _selected:
		_selected = row.get_metadata(0)
		_show_selected()


func _on_item_collapsed(row: TreeItem) -> void:
	var key: Variant = row.get_metadata(0)
	if key is String:
		if row.collapsed:
			_collapsed[key] = true
		else:
			_collapsed.erase(key)


func _show_selected() -> void:
	_current_row = null
	var machine: Dictionary = model.machines.get(_selected, {}) if model else {}
	for control: Control in [_title, _status, _states]:
		control.visible = not machine.is_empty()
	if machine.is_empty():
		return

	_title.text = machine.path
	var status := PackedStringArray([" / ".join(Model.category_path(machine.category))])
	if machine.freed:
		status.append("freed")
	elif not machine.current:
		status.append("not started")
	if not model.running:
		status.append("game stopped")
	_status.text = "  ·  ".join(status)

	_states.clear()
	var root := _states.create_item()
	var names: PackedStringArray = machine.states.duplicate()
	# The states arrive when the machine starts. Before that, or from a game
	# that did not send them, the panel still knows these two.
	for state_name: String in [machine.current, machine.previous]:
		if state_name and not names.has(state_name):
			names.append(state_name)
	for state_name in names:
		if state_name == Model.ALL_STATE:
			continue
		var row := _states.create_item(root)
		row.set_text(0, state_name)
		if state_name == machine.current:
			row.set_custom_font(0, _bold_font())
			row.set_custom_font(1, _bold_font())
			for column in 2:
				row.set_custom_color(column, _accent())
			_current_row = row
		elif state_name == machine.previous:
			row.set_custom_font(0, _italic_font())
			row.set_text(1, "previous")
			for column in 2:
				row.set_custom_color(column, _dimmed())
	if names.has(Model.ALL_STATE):
		var row := _states.create_item(root)
		row.set_text(0, Model.ALL_STATE)
		row.set_text(1, "shared by every state")
		for column in 2:
			row.set_custom_color(column, _dimmed())
	if _current_row and machine.freed:
		_current_row.set_text(1, "when freed")
		_current_row = null
	_show_time()


func _show_time() -> void:
	if _current_row:
		var seconds := model.time_in_state(_selected, Time.get_ticks_msec() / 1000.0)
		_current_row.set_text(1, "%.1f s" % seconds)


func _accent() -> Color:
	return get_theme_color("accent_color", "Editor") if Engine.is_editor_hint() else _FALLBACK_ACCENT


func _dimmed() -> Color:
	var color := _states.get_theme_color("font_color")
	color.a *= _DIM
	return color


# The editor's bold font, or the tree's font made bolder outside the editor,
# as in tests. has_theme_font() cannot tell, as it is true for any name.
func _bold_font() -> Font:
	if _bold == null:
		if Engine.is_editor_hint():
			_bold = get_theme_font("bold", "EditorFonts")
		else:
			var font := FontVariation.new()
			font.base_font = _states.get_theme_font("font")
			font.variation_embolden = 0.8
			_bold = font
	return _bold


# The tree's font, slanted. The editor has no italic font for its interface.
func _italic_font() -> Font:
	if _italic == null:
		var font := FontVariation.new()
		font.base_font = _states.get_theme_font("font")
		font.variation_transform = Transform2D(Vector2(1.0, 0.2), Vector2(0.0, 1.0), Vector2.ZERO)
		_italic = font
	return _italic
