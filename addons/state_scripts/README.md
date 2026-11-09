# State Scripts

Data-driven finite state machines for GDScript. Define your states in one block on any node, and `await` freely inside your hooks.

```gdscript
extends CharacterBody2D

@onready var fsm := StateScript.define(self, "Player", func(state):
	state.idle = func(on):
		on.enter = func(): $Sprite.play("idle")
		on.physics_process = func(_delta):
			if Input.is_action_just_pressed("attack"):
				fsm.go("attack")

	state.attack = func(on):
		on.enter = func():
			$Sprite.play("attack")
			await fsm.until($Sprite.animation_finished)
			fsm.go("idle")
)
```

Requires Godot 4.7 or later.

## Install

1. Extract the release zip into your project root, so that you have `addons/state_scripts/`.
2. Enable **State Scripts** in **Project > Project Settings > Plugins**.

`StateScript` is then available in every script.

A C# variant is also available. It installs to the same `addons/state_scripts/` folder, so a project uses one variant or the other.

## States

`StateScript.define(host, category, definition)` adds a machine to `host` and returns it. Keep it in a member variable.

`category` groups the machine in the [debugger panel](#debugger-panel), such as `"Player"` or `"Enemies/Flying"`, where a `/` nests one category in another. A game with many machines stays easy to browse that way. It is required, and an empty one is reported as an error.

`definition` is a function that defines the states. It runs straight away, with an object to define them on, called `state` above:

- Each state is assigned a function that sets its hooks: `state.idle = func(on): ...`.
- That function's parameter, called `on` above, takes the hooks: `on.enter = func(): ...`. Each hook is an ordinary statement, so a hook of several lines needs nothing special to end it.
- Events and signals go in `on.signal`. See [Events and signals](#events-and-signals).
- A state with no hooks can leave out the parameter: `state.dead = func(): pass`.
- For a state name that is not a valid identifier, use brackets: `state["wall-slide"] = func(on): ...`.

The names `state` and `on` are only the parameter names this README uses, chosen so that hooks read as `on.enter` and `on.exit`. You can call them anything.
- The name `ALL` is reserved for hooks shared by every state. See [Shared hooks](#shared-hooks).
- The first state defined is the initial one. `ALL` does not count, so it can come first.
- The machine starts after `host` is ready, so `fsm` is assigned and `_ready` has finished before the first `enter` runs. Call `fsm.start()` to enter the initial state sooner, or `fsm.go("state")` before it starts to choose a different one.

The closing `)` goes at the indentation of the line that calls `define()`. That is column 0 for an `@onready var`, or the function body's level when you call it inside a function.

The host can be any node. Scripts that do not extend `Node` are not supported, because the machine relies on the scene tree. The machine is an internal child, so `get_children()` does not list it. In the remote scene tree it is named after its host, as in `SS_Player`, with a number for a second machine on the same host. It is freed with its host.

## Hooks

Hooks are named after the Godot callback they mirror, without the underscore. A hook can be a lambda or a method reference such as `_on_idle_enter`, and it can leave out parameters it does not need.

| Hook | Runs | Arguments |
|---|---|---|
| `enter` | On entering the state | Whatever was passed to `go()` |
| `exit` | On leaving the state | None |
| `process` | Every frame | `delta` |
| `physics_process` | Every physics frame | `delta` |
| `input` | On `_input` | `event` |
| `shortcut_input` | On `_shortcut_input` | `event` |
| `unhandled_input` | On `_unhandled_input` | `event` |
| `unhandled_key_input` | On `_unhandled_key_input` | `event` |
| `gui_input` | On `gui_input`. Needs a `Control` host | `event` |
| `draw` | On drawing. Needs a `CanvasItem` host | None |
| `enter_tree` | When the host re-enters the tree | None |
| `exit_tree` | When the host leaves the tree | None |
| `signal` | Events and signals, not a hook. See [Events and signals](#events-and-signals) | |

Misspelled hook names, unknown states, and states or hooks defined twice report an error instead of being ignored.

`_integrate_forces` has no signal to connect to, so forward it yourself:

```gdscript
func _integrate_forces(physics_state):
	fsm.send("integrate_forces", physics_state)
```

## Transitions

Call `fsm.go("state")` from a hook or from anywhere else. Extra arguments go to the next state's `enter` hook:

```gdscript
fsm.go("hurt", damage, source)
```

```gdscript
state.hurt = func(on):
	on.enter = func(damage, source): health -= damage
```

Going to the current state runs its `exit` and `enter` hooks again.

Code after `go()` still runs, so `return` straight after it if the rest of the hook should not:

```gdscript
on.process = func(_delta):
	if health <= 0:
		fsm.go("dead")
		return
	move()
```

A `go()` made during a transition does not interrupt it. From `exit` it replaces the destination, and from `enter` it takes effect when the hook returns. If several calls are made, the latest one wins. States that keep bouncing between each other stop after 64 chained transitions with an error, instead of hanging the game.

## State information

| Member | Meaning |
|---|---|
| `current` | Name of the active state |
| `previous` | Name of the state before it |
| `next` | Destination during a transition, for use in `exit`. Otherwise empty |
| `time_in_state` | Seconds in `current`. Follows pausing and time scale |
| `state_changed(from, to)` | Signal emitted on each transition, before the new `enter` |

## Async

Any hook can `await`. There is nothing to set up.

| Hook | While suspended |
|---|---|
| `process`, `physics_process` | Not started again until it finishes, so it acts like a loop |
| `exit` | Holds the transition. The next state's `enter` runs once it finishes |
| `enter` | Holds nothing back. The state's other hooks run alongside it |
| Input hooks and events | Each event starts its own run |

A `process` hook can therefore pace itself:

```gdscript
on.process = func(_delta):
	fire()
	await fsm.wait(0.5)
```

### Waits tied to the state

Use these inside a state. Leaving the state cancels them, and the rest of the hook never runs.

| Method | Waits for |
|---|---|
| `await fsm.wait(seconds)` | A delay. It stops during a pause unless the host runs while paused |
| `await fsm.until(some_signal)` | Any signal, giving the same result as awaiting it directly |
| `await fsm.next_frame()` | The next frame |
| `await fsm.next_physics_frame()` | The next physics frame |

```gdscript
state.windup = func(on):
	on.enter = func():
		$Sprite.play("windup")
		await fsm.wait(0.4)
		spawn_hitbox()
		await fsm.until($Sprite.animation_finished)
		fsm.go("idle")
	on.signal.stunned = func(): fsm.go("stunned")
```

If `stunned` arrives during the wait, the hitbox never spawns.

### Plain `await`

A plain `await` works, but it cannot be cancelled. The hook carries on after the state has been left, which can be what you want for something like a sound that should finish. To tie any signal to the state, wrap it: `await fsm.until(some_signal)`.

## Events and signals

A state's `on.signal` table handles custom events and signals. Only the active state receives them, and other states ignore them.

```gdscript
@onready var fsm := StateScript.define(self, "Player", func(state):
	state.idle = func(on):
		on.signal.hit = func(damage): fsm.go("hurt", damage)
		on.signal[$Sensor.body_entered] = func(body): fsm.go("chase", body)

	state.hurt = func(on):
		on.enter = func(damage): health -= damage

	state.chase = func(): pass
)

func take_damage(amount):
	fsm.send("hit", amount)
```

- Custom events are set by name, as in `on.signal.hit`, or `on.signal["hit"]`. They run from `fsm.send(event, ...)`, which returns `true` if the state handled the event.
- Godot signals are set in brackets, as in `on.signal[$Sensor.body_entered]`. They are connected only while the state is active.
- Events are not queued. If no state is active, as during a suspended `exit`, `send()` returns `false`.
- Handlers can `await`, and their waits are cancelled like any other hook's.

## Shared hooks

A state named `ALL` holds hooks that run in every state. It takes the same hooks and `on.signal` table as any other state.

```gdscript
@onready var fsm := StateScript.define(self, "Player", func(state):
	state.ALL = func(on):
		on.physics_process = func(delta):
			velocity.y += gravity * delta
		on.signal.hit = func(damage): health -= damage

	state.idle = func(): pass
	state.run = func(): pass
)
```

- `ALL`'s hooks run before the active state's own. `exit` is the exception: the state's `exit` runs first, then `ALL`'s. When both are async, each holds the transition in turn.
- If both define the same hook or event, both run. `send()` returns `true` if either handles the event.
- If an `ALL` hook leaves the state, the state's own hook does not run. For example, an `ALL` handler for `hit` that calls `fsm.go("hurt")` stops the old state's own `hit` handler.
- `ALL`'s hooks belong to whichever state is active. Their waits are cancelled on every transition, and a suspended `process` hook in `ALL` starts again in the next state. It does not hold back the state's own `process`.
- `ALL` is never the initial state, and `fsm.go("ALL")` reports an error.

## Debugger panel

Run the game from the editor and open the **State Scripts** tab in the **Debugger** dock at the bottom.

- The left side lists every machine in the running game by its host's node path, with its current state. Machines are grouped under their categories, and a `/` nests one category in another, so `"Enemies/Flying"` is listed under `Enemies`. Each category shows how many machines it holds, and can be collapsed. Collapsed categories stay collapsed for the next run.
- Select a machine to see every state it defines. The current state is bold and in the editor's accent colour, with the time spent in it. The previous state is in italics. `ALL` is listed last, as it is never current.

The panel is read-only, and comes with the plugin enabled during install.

- Machines send to the panel only while the editor's debugger is attached. An exported game, or one started outside the editor, sends nothing and builds no messages.
- Each run of the game starts with an empty list. When the game stops, its machines stay listed so you can see where each one ended up, and their times stop counting.
- Freed machines stay listed, greyed out. The 100 most recent are kept.
- The time in the current state is measured from when the transition reached the editor, by the editor's clock. Unlike `time_in_state`, it keeps counting while the game is paused.

## Things to watch for

**Keep the machine in a member variable.** Lambdas capture local variables by value, so hooks using a local `fsm` see `null`:

```gdscript
func _ready():
	var fsm: StateScript
	fsm = StateScript.define(self, "Player", func(state):
		state.idle = func(on):
			on.enter = func(): fsm.go("run")  # fsm is null here
		state.run = func(): pass
	)
```

**Use `@onready` for `$` paths.** The definition runs when the variable is initialised, and a plain member variable runs before child nodes exist. This matters for signals in `on.signal`, as they are evaluated when the definition runs.

**Cancelling inside a helper holds some memory.** If a hook runs `await my_helper()` and is cancelled, it never resumes, but the two suspended functions keep each other in memory until the host is freed. This matters only if it happens a great many times on a very long-lived node.

**A cancelled `wait()` leaves its engine timer running.** It does nothing when it expires.

## Examples

`gdscript/examples/turret` in the repository is a small working scene that uses timed waits, signals and cancellation.
