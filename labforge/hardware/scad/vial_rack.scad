// LabForge — parametric vial / tube rack.
//
// A simple gridded rack to hold reagent stock vials or the reactor vessel in a
// repeatable position under the dispensing tubing.
//
//   openscad -D 'rows=4' -D 'cols=6' -D 'vial_d=17' -o rack.stl vial_rack.scad

use <common.scad>

rows      = 3;
cols      = 4;
vial_d    = 28.0;     // vial outer diameter (e.g. 20 mL scintillation vial)
pitch     = 34.0;     // centre-to-centre spacing
depth     = 22.0;     // pocket depth
wall      = 4.0;
floor_t   = 3.0;

body_x = cols * pitch + wall - (pitch - vial_d);
body_y = rows * pitch + wall - (pitch - vial_d);
body_z = depth + floor_t;

module rack() {
    difference() {
        rounded_plate(body_x, body_y, body_z, r = 4);
        for (r = [0:rows-1], c = [0:cols-1]) {
            x = -body_x/2 + pitch/2 + c * pitch;
            y = -body_y/2 + pitch/2 + r * pitch;
            translate([x, y, floor_t])
                cylinder(d = vial_d + 0.4, h = depth + 0.1);
            // small drain/ID hole in the bottom of each pocket
            translate([x, y, -0.01]) hole(4, floor_t + 0.02);
        }
    }
}

// centre the plate so multi-part previews line up
translate([0, 0, 0]) rack();
