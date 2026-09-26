extends TestCase
## Commands from the network can carry anything; bad arguments must come back
## as errors, never as script errors.


func test_bad_arguments_are_errors_not_crashes() -> void:
	var s := T.sess(4)
	check(not s.command(Roles.PILOT, "accept_job", {"job_id": "x"})[0], "non-numeric job id")
	check(not s.command(Roles.PILOT, "accept_job", {})[0], "missing job id")
	check(not s.command(Roles.PILOT, "move_item", {"item_id": null})[0], "null item")
	check(not s.command(Roles.BOAT, "boat_goto", {"x": "west"})[0], "bad point")
	check(not s.command(Roles.PILOT, "buy_aircraft", {"key": "b52"})[0], "unknown aircraft")
	check(not s.command(Roles.PILOT, "no_such_command")[0], "unknown command")
	check(not s.command("janitor", "chat", {"text": "hi"})[0], "unknown role")
	check(s.command(Roles.PILOT, "set_fuel", {"lb": "150"})[0], "numeric strings are accepted")
