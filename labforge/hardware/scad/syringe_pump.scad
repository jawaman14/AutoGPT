// LabForge — parametric 3D-printable syringe pump.
//
// A NEMA 17 + leadscrew driven syringe pump in the lineage of open designs
// (Poseidon / FINDUS). Prints as three parts: a motor-end block, a syringe-end
// block, and a moving carriage that pushes the plunger. Two smooth rods and one
// leadscrew (bought parts) tie them together; see hardware/bom.md.
//
// Render one part at a time by setting `part`:
//   openscad -D 'part="motor"'    -o motor.stl    syringe_pump.scad
//   openscad -D 'part="carriage"' -o carriage.stl syringe_pump.scad
//   openscad -D 'part="syringe"'  -o syringe.stl  syringe_pump.scad
//   openscad -D 'part="all"'      syringe_pump.scad   (preview, laid out)

use <common.scad>

// ---- parameters (edit for your syringe / hardware) ------------------------
part           = "all";      // "motor" | "carriage" | "syringe" | "all"

syringe_barrel_d = 19.0;     // 10 mL BD-style barrel outer diameter
plunger_d        = 9.0;      // plunger rod diameter
flange_w         = 30.0;     // syringe finger-flange width (slot)
flange_t         = 3.0;      // finger-flange thickness

rod_d            = 8.0;      // smooth guide rod diameter
rod_spacing      = 45.0;     // centre-to-centre of the two guide rods
leadscrew_d      = 8.0;      // leadscrew (T8) major diameter
nut_flange_d     = 22.0;     // T8 brass nut flange diameter
nut_bolt_pitch   = 16.0;     // T8 nut flange bolt circle (M3 x4 typical)

plate_t          = 8.0;      // end-block thickness
plate_w          = rod_spacing + 26;
plate_h          = 58.0;
carriage_t       = 12.0;

// ---- derived --------------------------------------------------------------
rod_z  = 20.0;                       // rod height above the base
screw_z = rod_z;                     // leadscrew shares the rod height

// ---- end block (shared body for motor + syringe ends) ---------------------
module end_block() {
    difference() {
        union() {
            rounded_plate(plate_w, plate_h, plate_t, r = 4);
            // stiffening foot
            translate([0, 0, 0]) rounded_plate(plate_w, plate_h, 3, r = 4);
        }
        // rod bores
        for (x = [-rod_spacing/2, rod_spacing/2])
            translate([x, rod_z - plate_h/2, -0.01]) rotate([0,0,0])
                translate([0,0,0]) hole(rod_d + 0.4, plate_t + 1);
        // leadscrew clearance
        translate([0, screw_z - plate_h/2, -0.01]) hole(leadscrew_d + 2, plate_t + 1);
    }
}

module motor_end() {
    difference() {
        end_block();
        // NEMA 17 faceplate, centred on the leadscrew axis
        translate([0, screw_z - plate_h/2, 0]) nema17_faceplate(plate_t);
    }
}

module syringe_end() {
    difference() {
        end_block();
        // Barrel nozzle pass-through + finger-flange slot to hold the syringe.
        translate([0, screw_z - plate_h/2, -0.01]) hole(syringe_barrel_d + 0.5, plate_t + 1);
        translate([-flange_w/2, screw_z - plate_h/2 - flange_t/2, plate_t - flange_t])
            cube([flange_w, flange_t + syringe_barrel_d, flange_t + 0.5]);
    }
}

// ---- carriage: rides the rods, driven by the T8 nut, pushes the plunger ----
module carriage() {
    difference() {
        rounded_plate(plate_w - 6, plate_h, carriage_t, r = 4);
        // linear-bearing / rod bores
        for (x = [-rod_spacing/2, rod_spacing/2])
            translate([x, rod_z - plate_h/2, -0.01]) hole(rod_d + 0.6, carriage_t + 1);
        // T8 nut flange recess + bolt holes on the leadscrew axis
        translate([0, screw_z - plate_h/2, -0.01]) {
            hole(leadscrew_d + 2, carriage_t + 1);
            cylinder(d = nut_flange_d + 0.6, h = 3.2);
            for (a = [45:90:315])
                translate([nut_bolt_pitch/2*cos(a), nut_bolt_pitch/2*sin(a), 0])
                    hole(M3_CLEAR, 8);
        }
        // plunger cup: captures the plunger head so it moves both ways
        translate([0, screw_z - plate_h/2, carriage_t - 4])
            hole(plunger_d + 0.6, 5);
    }
}

// ---- layout ---------------------------------------------------------------
if (part == "motor")    motor_end();
else if (part == "syringe") syringe_end();
else if (part == "carriage") carriage();
else {
    translate([-plate_w - 8, 0, 0]) motor_end();
    translate([0, 0, 0]) carriage();
    translate([plate_w + 8, 0, 0]) syringe_end();
}
