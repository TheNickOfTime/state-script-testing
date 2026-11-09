extends CharacterBody2D

# Variables ------------------------------------------------------------------------------------------------------------

# Constants --------------------------------------------------------------------
const moveSpeed : float = 96.0
const moveFriction : float = 310
const jumpSpeed : float = -256.0

# State
var previousDirection = 0.0
var canDoubleJump : bool = false

# Child References -------------------------------------------------------------
@onready var characterSprite : AnimatedSprite2D = $AnimatedSprite2D

# State Script ---------------------------------------------------------------------------------------------------------
var ss : StateScript = StateScript.define(self, "player", func(state):
	state.ALL = func(on):
		on.physics_process = func(delta):
			handle_gravity(delta)

			# Apply calculated movement in all states
			move_and_slide()


	state.inital = func(on):
		on.enter = func():
			print("The player is alive!")
			if is_on_floor():
				ss.go("idle")
			else:
				ss.go("falling")


	state.idle = func(on):
		on.enter = func():
			print("The player is idle...")
			characterSprite.play("idle")
		
		on.physics_process = func(delta):
			handle_movement(delta)
			handle_jump()

			if check_moving():
				ss.go("walking")
			
			if check_jumping():
				ss.go("jumping")

	
	state.walking = func(on):
		on.enter = func():
			print("The player is moving...")
			characterSprite.play("walking")
		
		on.physics_process = func(delta):
			handle_movement(delta)
			handle_jump()

			if not check_moving():
				ss.go("idle")
			
			if check_jumping():
				ss.go("jumping")

	
	state.jumping = func(on):
		on.enter = func():
			print("The player is jumping...")
			characterSprite.play("jumping")
		
		on.physics_process = func(delta):
			handle_movement(delta)
			handle_double_jump()

			# if check_grounded():
			# 	ss.go("grounded")

			if check_falling():
				ss.go("falling")
	

	state.falling = func(on):
		on.enter = func():
			print("The player is falling...")
			characterSprite.play("falling")
		
		on.physics_process = func(delta):
			handle_movement(delta)
			handle_double_jump()

			if check_jumping():
				ss.go("jumping")

			if check_grounded():
				ss.go("grounded")
	

	state.grounded = func(on):
		on.enter = func():
			canDoubleJump = false

			if check_moving():
				ss.go("walking")
			else:
				ss.go("idle")
)


# Helper Functions -----------------------------------------------------------------------------------------------------
func handle_gravity(delta : float):
	if not is_on_floor():
		velocity += get_gravity() * delta


func handle_movement(delta : float):
	var direction := Input.get_axis("move-left", "move-right")
	if direction:
		velocity.x = direction * moveSpeed
	else:
		velocity.x = move_toward(velocity.x, 0, moveFriction * delta)

	# Ensure the sprite faces the last direction the player was going
	if direction > 0.0 and characterSprite.flip_h:
		characterSprite.flip_h = false
	elif direction < 0.0 and not characterSprite.flip_h:
		characterSprite.flip_h = true


func check_moving() -> bool:
	return velocity.x != 0.0


func handle_jump():
	var canJump = is_on_floor() and not canDoubleJump
	var wantsJump = Input.is_action_just_pressed("move-jump")
	if canJump and wantsJump:
		canDoubleJump = true
		velocity.y = jumpSpeed


func handle_double_jump():
	var canJump = not is_on_floor() and canDoubleJump
	var wantsJump = Input.is_action_just_pressed("move-jump")
	if canJump and wantsJump:
		canDoubleJump = false
		velocity.y = jumpSpeed


func check_jumping() -> bool:
	return velocity.y < 0.0


func check_falling() -> bool:
	return velocity.y > 0.0


func check_grounded() -> bool:
	return velocity.y == 0 and is_on_floor()