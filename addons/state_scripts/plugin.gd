@tool
extends EditorPlugin
# The addon is a runtime library exposed through `class_name`. The editor plugin
# adds the State Scripts tab to the Debugger dock, and shows the addon in
# Project Settings > Plugins with its version.

# Before 4.7, a coroutine dropped while suspended never releases its local
# variables, so every wait cancelled by leaving a state would leak them.
const MINIMUM_VERSION := 0x040700
const _DebuggerPlugin := preload("debugger/debugger_plugin.gd")

var _debugger: EditorDebuggerPlugin


func _enter_tree() -> void:
	if Engine.get_version_info().hex < MINIMUM_VERSION:
		push_warning("State Scripts needs Godot 4.7 or later. Cancelled waits leak memory on this version.")
	_debugger = _DebuggerPlugin.new()
	add_debugger_plugin(_debugger)


func _exit_tree() -> void:
	remove_debugger_plugin(_debugger)
	_debugger = null
