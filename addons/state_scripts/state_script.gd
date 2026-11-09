class_name StateScript
extends Node
## Data-driven finite state machine that attaches to any node.
##
## Define the states in one function and give it to [method define] with the
## node that owns them and a category for the debugger panel. Each state is
## assigned a function that sets its hooks. The first state defined is the
## initial one, not counting [code]ALL[/code].
## [codeblock]
## @onready var fsm := StateScript.define(self, "Player", func(state):
##     state.idle = func(on):
##         on.enter = func(): $Sprite.play("idle")
##         on.physics_process = func(delta):
##             if Input.is_action_just_pressed("jump"):
##                 fsm.go("jump")
##
##     state.jump = func(on):
##         on.enter = func(): velocity.y = -400.0
##         on.physics_process = func(delta):
##             if is_on_floor():
##                 fsm.go("idle")
## )
## [/codeblock]
## Hooks are named after the callback they mirror, without the underscore:
## [code]process[/code], [code]physics_process[/code], [code]input[/code],
## [code]shortcut_input[/code], [code]unhandled_input[/code],
## [code]unhandled_key_input[/code], [code]enter_tree[/code] and
## [code]exit_tree[/code]. [code]draw[/code] needs a [CanvasItem] host, and
## [code]gui_input[/code] a [Control] host. [code]enter[/code] and
## [code]exit[/code] run on transitions. A hook may leave out the parameters
## it does not need.
## [br][br]
## Any hook can [code]await[/code]. A suspended [code]process[/code] or
## [code]physics_process[/code] hook is not started again until it finishes,
## so it behaves like a loop. A suspended [code]exit[/code] hook holds the
## transition until it finishes. A suspended [code]enter[/code] hook does not
## hold anything back: the state's other hooks run alongside it.
## [codeblock]
## state.windup = func(on):
##     on.enter = func():
##         sprite.play("windup")
##         await fsm.wait(0.4)
##         spawn_hitbox()
##         await fsm.until(sprite.animation_finished)
##         fsm.go("idle")
## [/codeblock]
## Use [method wait], [method until], [method next_frame] and
## [method next_physics_frame] for pauses inside a state. Leaving the state
## cancels them, so the rest of the hook never runs. A plain [code]await[/code]
## cannot be cancelled and carries on after the state has been left.
## [br][br]
## A state's [code]on.signal[/code] table handles custom events and signals.
## Events by name run from [method send], and [Signal] keys run when that
## signal is emitted. Both reach only the active state, and other states ignore
## them.
## [codeblock]
## state.idle = func(on):
##     on.signal.hit = func(damage): fsm.go("hurt", damage)
##     on.signal[$Sensor.body_entered] = func(body): fsm.go("chase", body)
## [/codeblock]
## A state named [code]ALL[/code] holds hooks shared by every state. They run
## in whichever state is active, before that state's own hooks, except
## [code]exit[/code], which runs after the state's. Both run when they define
## the same hook or event. If an [code]ALL[/code] hook leaves the state, the
## state's own hook does not run. [code]ALL[/code] cannot be entered.

## Emitted after [member current] changes, before the new state's [code]enter[/code] hook.
signal state_changed(from: StringName, to: StringName)

## Transitions allowed in one uninterrupted chain, such as [code]enter[/code]
## hooks that keep calling [method go]. Reaching it means two states are
## bouncing between each other, which would otherwise hang the game.
const MAX_CHAINED_TRANSITIONS := 64

const _ALL_STATE := &"ALL"
const _LIFECYCLE_HOOKS: Array[StringName] = [&"enter", &"exit"]
const _CALLBACK_HOOKS: Array[StringName] = [
	&"process",
	&"physics_process",
	&"input",
	&"shortcut_input",
	&"unhandled_input",
	&"unhandled_key_input",
]
const _HOST_SIGNAL_HOOKS: Array[StringName] = [&"draw", &"gui_input", &"enter_tree", &"exit_tree"]
const _NAME_PREFIX := "SS_"
const _DEBUG_PREFIX := "state_scripts:"

# Receives the messages meant for the State Scripts debugger panel, in place of
# the editor's debugger. For tests.
static var _debug_sink := Callable()

## Groups the machine in the debugger panel. A [code]/[/code] nests one
## category in another, as in [code]"Enemies/Flying"[/code].
var category: String:
	get:
		return _category

## Name of the active state. Empty until the machine has started.
var current: StringName:
	get:
		return _current

## Name of the state active before [member current]. Empty until the first transition.
var previous: StringName:
	get:
		return _previous

## Name of the state being transitioned to, for use in [code]exit[/code]
## hooks. Empty when no transition is pending.
var next: StringName:
	get:
		return _queued[0] if not _queued.is_empty() else &""

## Seconds spent in [member current]. Follows pausing and [member Engine.time_scale].
var time_in_state: float:
	get:
		return _time_in_state

var _category := ""
var _states: Dictionary = {}
var _all: Dictionary = {}
var _current: StringName = &""
var _previous: StringName = &""
var _time_in_state := 0.0
var _started := false
var _transitioning := false
var _queued: Array = []
# Hook tables of the active state in the order they run: ALL, then the state's
# own. Empty while no state is active.
var _active: Array[Dictionary] = []
var _scope := _Scope.new()


## Creates a machine with the states that [param definition] defines, and adds
## it to [param host] as an internal child, which [method Node.get_children]
## does not list. [param category] groups it in the debugger panel, and a
## [code]/[/code] nests one category in another, as in
## [code]"Enemies/Flying"[/code]. [param definition] is called straight away with an object to
## define the states on: assign each state a function that sets its hooks, as
## in [code]state.idle = func(on): on.enter = func(): ...[/code]. Use
## [code]state["name"][/code] for a name that is not an identifier.[br][br]
## The machine starts after [param host] is ready, in the first state defined,
## not counting [code]ALL[/code]. To start in another, call [method go] before
## it starts.
static func define(host: Node, category: String, definition: Callable) -> StateScript:
	var machine := StateScript.new()
	machine._category = category.strip_edges()
	if machine._category.is_empty():
		push_error("StateScript: define() needs a category for the debugger panel, such as \"Player\".")
	var states := _Definition.new()
	if definition.get_argument_count() == 1:
		definition.call(states)
	else:
		push_error("StateScript: define() needs a function with one parameter, such as func(state):.")
	machine._load_states(states.__states)
	if machine._states.is_empty():
		push_error("StateScript: no valid states to define on %s." % host)
	else:
		machine._queue(machine._states.keys()[0], [])
	machine._connect_host_hooks(host)
	machine.process_priority = host.process_priority
	machine.process_physics_priority = host.process_physics_priority
	# Named after the host, so it is easy to find in the remote scene tree. A
	# second machine on the same host gets a number, as in SS_Hero2.
	machine.name = _NAME_PREFIX + host.name
	host.renamed.connect(machine._name_after_host)
	host.add_child(machine, true, Node.INTERNAL_MODE_FRONT)
	return machine


func _init() -> void:
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _debugging():
		_debug("gone", [get_instance_id()])


func _enter_tree() -> void:
	# The host may have been named since define(), as when it is defined in a
	# member variable and then instantiated from a scene.
	_name_after_host()


func _ready() -> void:
	# Deferred so @onready variables holding the machine are assigned, and the
	# host's own _ready has finished, before the first enter hook runs.
	start.call_deferred()


func _process(delta: float) -> void:
	_time_in_state += delta
	_dispatch_frame(&"process", delta)


func _physics_process(delta: float) -> void:
	_dispatch_frame(&"physics_process", delta)


func _input(event: InputEvent) -> void:
	_dispatch(&"input", [event])


func _shortcut_input(event: InputEvent) -> void:
	_dispatch(&"shortcut_input", [event])


func _unhandled_input(event: InputEvent) -> void:
	_dispatch(&"unhandled_input", [event])


func _unhandled_key_input(event: InputEvent) -> void:
	_dispatch(&"unhandled_key_input", [event])


## Enters the initial state now instead of waiting for the deferred start.
## Does nothing if the machine has already started.
func start() -> void:
	if _started:
		return
	_started = true
	set_process(true)
	if _debugging():
		var names := PackedStringArray()
		if not _all.is_empty():
			names.append(_ALL_STATE)
		for state_name: StringName in _states:
			names.append(state_name)
		_debug("machine", [get_instance_id(), _host_path(), _category, names])
	if not _queued.is_empty():
		_transition()


## Leaves [member current] and enters [param state], passing [param args] to
## its [code]enter[/code] hook. Going to the current state runs both hooks
## again.[br][br]
## Code after this call in a hook still runs, so [code]return[/code] straight
## after it if the rest of the hook should not.[br][br]
## A call made during a transition does not interrupt it. From an
## [code]exit[/code] hook it replaces the destination, and from an
## [code]enter[/code] hook it takes effect once that hook returns. If several
## calls are made, the latest one wins.
func go(state: StringName, ...args: Array) -> void:
	if state == _ALL_STATE:
		push_error("StateScript: \"ALL\" holds hooks shared by every state and cannot be entered.")
		return
	if not _states.has(state):
		push_error("StateScript: unknown state \"%s\"." % state)
		return
	_queue(state, args)
	if _started and not _transitioning:
		_transition()


## Runs the [param event] handlers in the [code]on.signal[/code] tables of
## [code]ALL[/code] and the active state, passing them [param args]. Returns
## [code]true[/code] if either handles the event. Events are not queued, so
## nothing happens if no state is active, as during a suspended
## [code]exit[/code] hook.
func send(event: StringName, ...args: Array) -> bool:
	var handled := false
	var scope := _scope
	for hooks: Dictionary in _active:
		var handlers: Dictionary = hooks.get(&"events", {})
		if handlers.has(event):
			handled = true
			if scope == _scope:
				scope.run(handlers[event], args)
	return handled


## Returns a signal to [code]await[/code] for a pause of [param seconds], which
## is cancelled if the state is left. It follows [member Engine.time_scale],
## and stops while the game is paused unless [member Node.process_mode] lets
## the machine run during a pause.
func wait(seconds: float) -> Signal:
	return until(get_tree().create_timer(seconds, _runs_while_paused()).timeout)


## Returns a signal to [code]await[/code] for [param source], which is
## cancelled if the state is left. The [code]await[/code] gives the same result
## as awaiting [param source] directly.
func until(source: Signal) -> Signal:
	return _scope.add_wait(source)


## Returns a signal to [code]await[/code] for the next frame, which is
## cancelled if the state is left.
func next_frame() -> Signal:
	return until(get_tree().process_frame)


## Returns a signal to [code]await[/code] for the next physics frame, which is
## cancelled if the state is left.
func next_physics_frame() -> Signal:
	return until(get_tree().physics_frame)


# Messages for the debugger panel are only built while something receives them,
# which is never the case in an exported game.
static func _debugging() -> bool:
	return _debug_sink.is_valid() or EngineDebugger.is_active()


static func _debug(message: String, data: Array) -> void:
	if _debug_sink.is_valid():
		_debug_sink.call(message, data)
	else:
		EngineDebugger.send_message(_DEBUG_PREFIX + message, data)


func _name_after_host() -> void:
	var host := get_parent()
	if host:
		name = _NAME_PREFIX + host.name


func _host_path() -> String:
	var host := get_parent()
	if host == null:
		return "(no host)"
	return str(host.get_path()) if host.is_inside_tree() else str(host)


func _queue(state: StringName, args: Array) -> void:
	_queued = [state, args]


func _runs_while_paused() -> bool:
	var node: Node = self
	while node and node.process_mode == PROCESS_MODE_INHERIT:
		node = node.get_parent()
	return node != null and node.process_mode in [PROCESS_MODE_ALWAYS, PROCESS_MODE_WHEN_PAUSED]


func _transition() -> void:
	_transitioning = true
	var chained := 0
	while not _queued.is_empty():
		chained += 1
		if chained > MAX_CHAINED_TRANSITIONS:
			push_error(
				"StateScript: stopped after %d chained transitions, last going to \"%s\"."
				% [MAX_CHAINED_TRANSITIONS, _queued[0]]
			)
			_queued = []
			break

		await _leave_current()

		var target: StringName = _queued[0]
		var args: Array = _queued[1]
		_queued = []
		_enter(target, args)
	_transitioning = false


func _leave_current() -> void:
	# The state's own exit hook runs before the one of ALL.
	var exit_hooks: Array[Callable] = []
	for i in range(_active.size() - 1, -1, -1):
		var hook: Callable = _active[i].get(&"exit", Callable())
		if hook.is_valid():
			exit_hooks.append(hook)
	_active = []
	# Cancels the waits of the state being left. The exit hooks get a new scope
	# so that their own waits survive.
	_scope = _Scope.new()
	_update_callbacks()
	var scope := _scope
	for hook in exit_hooks:
		await scope.run(hook, [])


func _enter(state: StringName, args: Array) -> void:
	_previous = _current
	_current = state
	_time_in_state = 0.0
	_active = [_all, _states[state]]
	_scope = _Scope.new()
	for hooks: Dictionary in _active:
		_scope.listen(hooks.get(&"signals", {}))
	_update_callbacks()
	state_changed.emit(_previous, _current)
	if _debugging():
		_debug("state", [get_instance_id(), _host_path(), String(_previous), String(_current)])
	_dispatch(&"enter", args)


func _dispatch(hook_name: StringName, args: Array) -> void:
	# A hook can replace _scope, so keep this one alive through the calls. Once
	# it is replaced the state has been left, and its other hooks must not run.
	var scope := _scope
	for hooks: Dictionary in _active:
		var hook: Callable = hooks.get(hook_name, Callable())
		if hook.is_valid() and scope == _scope:
			scope.run(hook, args)


func _dispatch_frame(hook_name: StringName, delta: float) -> void:
	var scope := _scope
	var active := _active
	for i in active.size():
		var hook: Callable = active[i].get(hook_name, Callable())
		if hook.is_valid() and scope == _scope:
			# Keyed by table too, so ALL and the state are guarded separately.
			scope.run_exclusive([i, hook_name], hook, [delta])


# Per-frame and input callbacks are switched on only while a hook needs them.
func _update_callbacks() -> void:
	set_physics_process(_is_active(&"physics_process"))
	set_process_input(_is_active(&"input"))
	set_process_shortcut_input(_is_active(&"shortcut_input"))
	set_process_unhandled_input(_is_active(&"unhandled_input"))
	set_process_unhandled_key_input(_is_active(&"unhandled_key_input"))
	var host := get_parent() as CanvasItem
	if host and _uses_hook(&"draw"):
		host.queue_redraw()


func _is_active(hook_name: StringName) -> bool:
	for hooks: Dictionary in _active:
		if hooks.has(hook_name):
			return true
	return false


func _uses_hook(hook_name: StringName) -> bool:
	if _all.has(hook_name):
		return true
	for hooks: Dictionary in _states.values():
		if hooks.has(hook_name):
			return true
	return false


func _load_states(states: Dictionary) -> void:
	for state_name: StringName in states:
		if state_name == _ALL_STATE:
			_all = _load_hooks(state_name, states[state_name])
		else:
			_states[state_name] = _load_hooks(state_name, states[state_name])


func _load_hooks(state_name: StringName, definition: Dictionary) -> Dictionary:
	var hooks := {}
	for hook_name: Variant in definition:
		var key := StringName(str(hook_name))
		if key == &"signal":
			_load_events(state_name, definition[hook_name], hooks)
		elif not _is_hook_name(key):
			push_error("StateScript: state \"%s\" has unknown hook \"%s\"." % [state_name, key])
		elif not definition[hook_name] is Callable:
			push_error("StateScript: hook \"%s\" of \"%s\" must be a function." % [key, state_name])
		else:
			hooks[key] = definition[hook_name]
	return hooks


func _load_events(state_name: StringName, table: Variant, hooks: Dictionary) -> void:
	if not table is Dictionary:
		push_error("StateScript: \"signal\" of \"%s\" must be a dictionary." % state_name)
		return
	var named := {}
	var signals := {}
	for event: Variant in table:
		if not table[event] is Callable:
			push_error("StateScript: handler for %s in \"%s\" must be a function." % [event, state_name])
		elif event is Signal:
			signals[event] = table[event]
		elif event is String or event is StringName:
			named[StringName(event)] = table[event]
		else:
			push_error("StateScript: event %s in \"%s\" must be a string or a Signal." % [event, state_name])
	hooks[&"events"] = named
	hooks[&"signals"] = signals


func _is_hook_name(hook_name: StringName) -> bool:
	return (
		hook_name in _LIFECYCLE_HOOKS
		or hook_name in _CALLBACK_HOOKS
		or hook_name in _HOST_SIGNAL_HOOKS
	)


func _connect_host_hooks(host: Node) -> void:
	if _uses_hook(&"enter_tree"):
		host.tree_entered.connect(_dispatch.bind(&"enter_tree", []))
	if _uses_hook(&"exit_tree"):
		host.tree_exiting.connect(_dispatch.bind(&"exit_tree", []))
	if _uses_hook(&"draw"):
		if host is CanvasItem:
			host.draw.connect(_dispatch.bind(&"draw", []))
		else:
			push_error("StateScript: the draw hook needs a CanvasItem host, got %s." % host)
	if _uses_hook(&"gui_input"):
		if host is Control:
			host.gui_input.connect(func(event: InputEvent) -> void: _dispatch(&"gui_input", [event]))
		else:
			push_error("StateScript: the gui_input hook needs a Control host, got %s." % host)


# What define() passes to its function. Assigning a state a function runs it
# with that state's definition. Its own variable has a name no state would
# use, as assigning a state of the same name would set the variable instead.
class _Definition extends RefCounted:
	var __states: Dictionary = {}

	func _set(state_name: StringName, value: Variant) -> bool:
		if __states.has(state_name):
			push_error("StateScript: state \"%s\" is defined twice, keeping the first." % state_name)
		elif not value is Callable:
			push_error(
				"StateScript: state \"%s\" must be a function that sets its hooks, such as func(on):."
				% state_name
			)
		else:
			var state := _StateDefinition.new(state_name)
			var define_state: Callable = value
			if define_state.get_argument_count() == 0:
				define_state.call()
			else:
				define_state.call(state)
			__states[state_name] = state.__hooks()
		return true


# What a state's function receives. Assigning a hook records it, and signal
# holds the state's events and signals. "signal" is a keyword, so it cannot be
# a variable, and _get() returns it instead.
class _StateDefinition extends RefCounted:
	var __name: StringName
	var __recorded: Dictionary = {}
	var __signal: Dictionary = {}

	func _init(state_name: StringName) -> void:
		__name = state_name

	func _get(property: StringName) -> Variant:
		return __signal if property == &"signal" else null

	func _set(hook_name: StringName, value: Variant) -> bool:
		if hook_name == &"signal" and value is Dictionary:
			__signal = value
		elif __recorded.has(hook_name):
			push_error("StateScript: state \"%s\" defines %s twice, keeping the first." % [__name, hook_name])
		else:
			# Includes a signal that is not a dictionary, for the loader to report.
			__recorded[hook_name] = value
		return true

	func __hooks() -> Dictionary:
		var hooks := __recorded.duplicate()
		if not hooks.has(&"signal") and not __signal.is_empty():
			hooks[&"signal"] = __signal
		return hooks


# Everything tied to one activation of a state. Replacing the scope frees its
# waits, and with them every coroutine suspended on one. It also disconnects
# its signal listeners and releases the frames of run(), which would otherwise
# form a cycle with the hook they await.
class _Scope extends RefCounted:
	var _running: Dictionary = {}
	var _waits: Array[_Wait] = []
	var _listeners: Array[_Listener] = []

	# Hooks must be awaited even when they are not meant to block: taking the
	# return value of a suspended hook without await is a debug-only error.
	func run(hook: Callable, args: Array) -> void:
		await hook.callv(_fit_arguments(hook, args))

	func run_exclusive(key: Variant, hook: Callable, args: Array) -> void:
		if _running.has(key):
			return
		_running[key] = true
		await hook.callv(_fit_arguments(hook, args))
		_running.erase(key)

	func add_wait(source: Signal) -> Signal:
		var wait := _Wait.new(self)
		_waits.append(wait)
		source.connect(wait.resume, CONNECT_ONE_SHOT)
		return wait.finished

	func remove_wait(wait: _Wait) -> void:
		_waits.erase(wait)

	func listen(signals: Dictionary) -> void:
		for source: Signal in signals:
			if source.get_object() != null:
				var listener := _Listener.new(self, signals[source])
				_listeners.append(listener)
				source.connect(listener.receive)

	func _fit_arguments(hook: Callable, args: Array) -> Array:
		var accepted := hook.get_argument_count()
		return args.slice(0, accepted) if accepted < args.size() else args


# Runs a hook for a signal. The scope owns it, so freeing the scope disconnects it.
class _Listener extends RefCounted:
	var _scope: WeakRef
	var _hook: Callable

	func _init(scope: _Scope, hook: Callable) -> void:
		_scope = weakref(scope)
		_hook = hook

	func receive(...args: Array) -> void:
		var scope: _Scope = _scope.get_ref()
		if scope:
			scope.run(_hook, args)


# One cancellable pause. Each has its own object because a signal cannot be
# connected to the same method twice, and two hooks may await the same source.
class _Wait extends RefCounted:
	signal finished(result: Variant)

	var _scope: WeakRef

	func _init(scope: _Scope) -> void:
		_scope = weakref(scope)

	func resume(...args: Array) -> void:
		# The scope holds the only reference, and the resumed hook can replace it.
		var keep_alive := self
		var scope: _Scope = _scope.get_ref()
		if scope:
			scope.remove_wait(keep_alive)
		match args.size():
			0:
				finished.emit(null)
			1:
				finished.emit(args[0])
			_:
				finished.emit(args)
