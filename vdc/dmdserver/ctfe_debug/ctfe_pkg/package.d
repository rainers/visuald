// The package of the debugged module, which imports that module the way
// visuald\dpackage.d imports visuald\ctfedebug.d.
module ctfe_pkg;

import ctfe_pkg.leaf;

enum fromPkg = twice(3);
