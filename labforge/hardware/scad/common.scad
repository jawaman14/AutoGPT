// LabForge — shared OpenSCAD helpers.
//
// Units are millimetres. Include this from the part files:
//   use <common.scad>

$fn = 64;

// M3 clearance and tap parameters (tune for your printer/filament shrinkage).
M3_CLEAR = 3.4;   // clearance hole for an M3 screw
M3_TAP   = 2.9;   // self-tapping into plastic
M3_HEAD  = 6.0;   // socket-head cap diameter
NUT_M3_AF = 5.5;  // M3 nut across-flats
NUT_M3_T  = 2.4;  // M3 nut thickness

// NEMA 17 stepper reference dimensions.
NEMA17_BODY      = 42.3;
NEMA17_HOLE_PITCH = 31.0;   // square hole pattern
NEMA17_BOSS_D    = 22.0;    // pilot boss diameter
NEMA17_SHAFT_D   = 5.0;

// A through hole centred at origin.
module hole(d, h) {
    translate([0, 0, -0.01]) cylinder(d = d, h = h + 0.02);
}

// Counterbored hole for a socket-head cap screw (head at +z end).
module counterbore(d_clear, d_head, h, head_h = 3) {
    hole(d_clear, h);
    translate([0, 0, h - head_h + 0.01]) cylinder(d = d_head, h = head_h + 0.01);
}

// The 4 mounting holes of a NEMA 17 face, centred on the origin.
module nema17_holes(d = M3_CLEAR, h = 6) {
    p = NEMA17_HOLE_PITCH / 2;
    for (x = [-p, p], y = [-p, p])
        translate([x, y, 0]) hole(d, h);
}

// A NEMA 17 faceplate cutout (boss pilot + 4 screw holes) for a bracket of
// thickness `t`. Place at the mounting face.
module nema17_faceplate(t) {
    hole(NEMA17_BOSS_D + 0.6, t);
    nema17_holes(M3_CLEAR, t);
}

// A captive hex-nut pocket (open toward -y) plus the bolt clearance along z.
module nut_trap(af = NUT_M3_AF, th = NUT_M3_T, bolt_d = M3_CLEAR, bolt_len = 20) {
    // hex pocket
    rotate([0, 0, 30]) cylinder(d = af / cos(30) + 0.2, h = th, $fn = 6);
    // bolt clearance
    hole(bolt_d, bolt_len);
}

// Rounded rectangular plate in XY of size [x, y], thickness z, corner radius r.
module rounded_plate(x, y, z, r = 3) {
    linear_extrude(z)
        offset(r = r) offset(delta = -r)
            square([x, y], center = true);
}

// A linear-rod clamp (split) sized for a smooth rod of diameter `rod_d`.
module rod_clamp(rod_d, w = 16, h = 12, wall = 4, bolt = M3_CLEAR) {
    difference() {
        translate([-w/2, 0, 0]) cube([w, wall*2 + rod_d, h]);
        translate([0, wall + rod_d/2, -0.01]) cylinder(d = rod_d, h = h + 0.02);
        // clamp slit
        translate([-0.6, wall + rod_d/2, -0.01]) cube([1.2, wall + rod_d, h + 0.02]);
        // clamp bolt across the slit
        translate([0, wall + rod_d/2, h/2]) rotate([0, 90, 0]) hole(bolt, w + 2);
    }
}
