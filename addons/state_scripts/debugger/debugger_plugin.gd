@tool
extends EditorDebuggerPlugin
## Adds the State Scripts tab to each debugger session, and feeds it the
## messages that machines in the running game send.

const Model := preload("debugger_model.gd")
const DebuggerPanel := preload("debugger_panel.gd")

# Session id to its model.
var _models: Dictionary = {}


func _has_capture(capture: String) -> bool:
	return capture == Model.CAPTURE


func _capture(message: String, data: Array, session_id: int) -> bool:
	var model: Model = _models.get(session_id)
	return model != null and model.receive(message, data, Time.get_ticks_msec() / 1000.0)


func _setup_session(session_id: int) -> void:
	var model := Model.new()
	_models[session_id] = model
	var panel := DebuggerPanel.new()
	panel.model = model
	var session := get_session(session_id)
	# Each run of the game starts with an empty list. When the game stops, its
	# machines stay listed, but their time in state stops counting.
	session.started.connect(model.clear)
	session.stopped.connect(func() -> void: model.stop(Time.get_ticks_msec() / 1000.0))
	session.add_session_tab(panel)
