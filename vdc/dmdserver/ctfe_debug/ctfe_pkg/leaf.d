// The debugged module of a package that imports it back.  The file must be
// analysed as the single module `ctfe_pkg.leaf`, or everything in it is
// interpreted twice: once for the module the debugger parsed, and once for the
// module the package imported.
module ctfe_pkg.leaf;

import ctfe_pkg;

int twice(int n)
{
	return n * 2;	// BP_TWICE
}

enum fromLeaf = twice(21);
