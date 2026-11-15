module ctfe_defs;

// An instance of Stats gives its scope names that are no variables of the CTFE
// stack: the manifest constants, the aliases and the enum type its body defines.
struct Stats(T)
{
	enum int dim = 3;					// DEF_DIM
	enum bool sorted = false;				// DEF_SORTED
	enum Shape { wide, tall }				// DEF_SHAPE
	enum Shape first = Shape.wide;			// DEF_FIRST
	alias Elem = T;					// DEF_ELEM
	alias Row = T[dim];					// DEF_ROW

	Elem[] cells;

	int total(int k)(int seed)
	{
		int sum = seed;
		foreach (c; cells)
			sum += c * k * dim;				// BP_TOTAL
		return sum;
	}
}

// A template that names a value, a type and a symbol beside the function it
// generates.
int makeTwice(int v)
{
	return v * 2;
}

template helpers(T)
{
	enum int factor = 4;					// DEF_FACTOR
	alias Elem = T;					// DEF_HELPERS_ELEM
	alias twice = makeTwice;				// DEF_TWICE

	int scaled(Elem[] arr)
	{
		int sum = 0;
		foreach (e; arr)
			sum += e * factor;			// BP_SCALED
		return sum;
	}
}

enum int s1 = Stats!int([1, 2, 3]).total!2(0);		// BP_STATS
enum int s2 = helpers!int.scaled([1, 2]);		// BP_HELPERS
