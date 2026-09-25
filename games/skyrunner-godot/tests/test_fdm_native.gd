extends TestCase


func test_jsbsim_matches_the_python_build() -> void:
	# same scenario, same numbers the Python jsbsim==1.3.1 build printed
	var fdm := JSBSimFDM.new()
	fdm.setup(ProjectSettings.globalize_path("res://data/jsbsim"))
	check(fdm.load_model("c172p"), "load c172p")
	fdm.set_property("ic/h-sl-ft", 3000.0)
	fdm.set_property("ic/vc-kts", 100.0)
	fdm.set_property("ic/psi-true-deg", 90.0)
	fdm.run_ic()
	fdm.set_property("propulsion/set-running", -1)
	fdm.set_property("fcs/throttle-cmd-norm", 0.8)
	fdm.set_property("fcs/mixture-cmd-norm", 1.0)
	fdm.run_steps(int(10.0 / fdm.get_delta_t()))
	check_near(fdm.get_property("position/h-sl-ft"), 3430.0, 0.1, "altitude after 10 s")
	check_near(fdm.get_property("velocities/vc-kts"), 56.7, 0.1, "IAS after 10 s")


func test_bound_handles_read_and_write() -> void:
	var fdm := JSBSimFDM.new()
	fdm.setup(ProjectSettings.globalize_path("res://data/jsbsim"))
	fdm.load_model("c172p")
	var h := fdm.bind("fcs/throttle-cmd-norm")
	fdm.set_bound(h, 0.42)
	check_near(fdm.get_property("fcs/throttle-cmd-norm"), 0.42, 1e-9)
	check(fdm.has_property("position/h-sl-ft"))
	check(not fdm.has_property("no/such/property"))
