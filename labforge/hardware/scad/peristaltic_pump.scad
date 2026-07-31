// LabForge — parametric 3D-printable peristaltic pump (3-roller).
//
// A NEMA 17 driven peristaltic pump head for the drain / recirculation line,
// where the fluid must not touch the pump (only the tubing does). Prints as a
// housing, a lid, and a 3-roller rotor; the rollers ride on 623ZZ bearings
// (bought parts). See hardware/bom.md.
//
//   openscad -D 'part="housing"' -o housing.stl peristaltic_pump.scad
//   openscad -D 'part="rotor"'   -o rotor.stl   peristaltic_pump.scad
//   openscad -D 'part="lid"'     -o lid.stl     peristaltic_pump.scad

use <common.scad>

part          = "all";     // "housing" | "rotor" | "lid" | "all"

tube_od       = 4.8;       // silicone tubing outer diameter (e.g. 3x5 mm)
occlusion     = 0.75;      // fraction of tube squeezed at rollers (0..1)
n_rollers     = 3;
roller_bearing_od = 10.0;  // 623ZZ outer diameter
roller_bearing_id = 3.0;
rotor_r       = 20.0;      // roller centre radius
wall          = 3.5;
housing_h     = 24.0;
shaft_d       = NEMA17_SHAFT_D;

// Inner race radius the tube is pressed against.
race_r = rotor_r + roller_bearing_od/2 + (tube_od * (1 - occlusion));

module housing() {
    difference() {
        cylinder(r = race_r + wall, h = housing_h);
        // tube race channel
        translate([0, 0, wall])
            difference() {
                cylinder(r = race_r + tube_od, h = housing_h);
                cylinder(r = race_r, h = housing_h);
            }
        // central rotor cavity
        translate([0, 0, wall]) cylinder(r = rotor_r + roller_bearing_od/2 + 1.0, h = housing_h);
        // tube inlet/outlet slots (tangential, opposite sides)
        for (a = [0, 180])
            rotate([0, 0, a]) translate([race_r + tube_od/2, -tube_od/2 - 0.3, wall])
                cube([wall + 6, tube_od + 0.6, tube_od + 1]);
        // NEMA 17 mount on the base
        translate([0, 0, 0]) nema17_faceplate(wall);
    }
}

module rotor() {
    difference() {
        union() {
            cylinder(r = rotor_r + roller_bearing_od/2, h = 6);
            // roller posts (bearing shoulder screws go here; modelled as pins)
            for (i = [0:n_rollers-1])
                rotate([0, 0, i * 360 / n_rollers])
                    translate([rotor_r, 0, 6]) cylinder(d = roller_bearing_id + 0.2, h = 8);
        }
        // motor shaft (D-cut approximated with a flat)
        hole(shaft_d + 0.3, 6);
        translate([shaft_d/2 - 0.5, -shaft_d, 0]) cube([1.5, shaft_d*2, 6]);
        // grub-screw hole
        translate([0, rotor_r/2, 3]) rotate([90, 0, 0]) hole(M3_TAP, rotor_r);
    }
}

module lid() {
    difference() {
        cylinder(r = race_r + wall, h = wall);
        translate([0, 0, -0.01]) hole(shaft_d + 4, wall + 0.02);
        for (a = [45:90:315])
            rotate([0,0,a]) translate([race_r + wall/2, 0, 0]) hole(M3_CLEAR, wall);
    }
}

if (part == "housing") housing();
else if (part == "rotor") rotor();
else if (part == "lid") lid();
else {
    housing();
    translate([0, 0, wall + 1]) rotor();
    translate([2*(race_r + wall) + 10, 0, 0]) lid();
}
