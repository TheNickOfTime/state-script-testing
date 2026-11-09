@tool
extends RefCounted
## What the State Scripts debugger panel knows about the machines of a running
## game, built from the messages they send.

## Emitted when a machine is added or changes, with its id. An id of 0 means
## everything may have changed, as after [method clear] or [method stop].
signal changed(id: int)
## Emitted when a freed machine is dropped to stay within [constant FREED_LIMIT].
signal removed(id: int)

## The prefix of the messages that machines send.
const CAPTURE := "state_scripts"
## Freed machines kept, greyed out, after their game freed them. The oldest go first.
const FREED_LIMIT := 100
## Where machines with an empty category are listed.
const NO_CATEGORY := "(no category)"
## The state that holds hooks shared by every state.
const ALL_STATE := "ALL"

## Machine instance id to a dictionary with path, category, states (the names
## it defines, in order), current, previous, received_at (editor time of the
## last transition) and freed.
var machines: Dictionary = {}
## Whether the game is still running. When it stops, times in state freeze.
var running := true

var _stopped_at := 0.0
var _freed: Array[int] = []


## Forgets every machine, for a new run of the game.
func clear() -> void:
	machines.clear()
	_freed.clear()
	running = true
	changed.emit(0)


## Marks the game as stopped at [param now], the editor's time in seconds.
## Machines are kept, so the panel still shows where each one ended up.
func stop(now: float) -> void:
	if not running:
		return
	running = false
	_stopped_at = now
	changed.emit(0)


## Applies a message as the debugger delivers it, such as
## [code]state_scripts:state[/code]. Returns whether it was one of ours.
func receive(message: String, data: Array, received_at: float) -> bool:
	if not message.begins_with(CAPTURE + ":"):
		return false
	apply(message.trim_prefix(CAPTURE + ":"), data, received_at)
	return true


## Applies one message from the game. [param message] is its name without the
## capture prefix, and [param received_at] the editor's time in seconds.
func apply(message: String, data: Array, received_at: float) -> void:
	var id := 0
	match message:
		"machine":
			if data.size() < 4 or not data[0] is int or not data[3] is PackedStringArray:
				return
			id = data[0]
			var machine := _machine(id, data[1])
			machine.category = str(data[2])
			machine.states = data[3]
		"state":
			if data.size() < 4 or not data[0] is int:
				return
			id = data[0]
			var machine := _machine(id, data[1])
			machine.previous = str(data[2])
			machine.current = str(data[3])
			machine.received_at = received_at
		"gone":
			if data.size() < 1 or not machines.has(data[0]):
				return
			id = data[0]
			machines[id].freed = true
			_freed.append(id)
			while _freed.size() > FREED_LIMIT:
				var dropped: int = _freed.pop_front()
				machines.erase(dropped)
				removed.emit(dropped)
		_:
			return
	changed.emit(id)


## Seconds since the machine's last transition, by the editor's clock, so it
## keeps counting while the game is paused. It stops when the game does.
func time_in_state(id: int, now: float) -> float:
	var machine: Dictionary = machines.get(id, {})
	if not machine or machine.freed or not machine.current:
		return 0.0
	return (now if running else _stopped_at) - machine.received_at


## The categories a machine is nested under, outermost first: "Enemies/Flying"
## gives ["Enemies", "Flying"].
static func category_path(category: String) -> PackedStringArray:
	var path := PackedStringArray()
	for part in category.split("/"):
		if not part.strip_edges().is_empty():
			path.append(part.strip_edges())
	if path.is_empty():
		path.append(NO_CATEGORY)
	return path


func _machine(id: int, path: String) -> Dictionary:
	if not machines.has(id):
		machines[id] = {
			"path": path,
			"category": "",
			"states": PackedStringArray(),
			"current": "",
			"previous": "",
			"received_at": 0.0,
			"freed": false,
		}
	var machine: Dictionary = machines[id]
	# A host can be renamed or moved while the game runs.
	machine.path = path
	return machine
