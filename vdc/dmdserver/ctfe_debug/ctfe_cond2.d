module ctfe_cond2;

int g(int n) { return n * 2; }	// BP_G

// a function template with several parameters and a condition in its body
int pick(size_t N, T = int)(T[] a, int i) if (N > 0 && g(N) == 2 * N)	// BP_PICKCONSTRAINT
{
	static if (is(T == int) && g(1) == 2)	// BP_STATICIF
		return a[i];	// BP_PICK
	else
		return 0;
}

// a struct template whose constraint calls a function
struct Box(T = int) if (is(T == int) && g(1) == 2)	// BP_BOXCONSTRAINT
{
	T value;
	this(T v) { value = v; }
	static if (g(2) == 4)	// BP_BOXIF
		enum int doubled = 4;
	static assert(g(3) == 6);	// BP_BOXASSERT
}

// a function template whose arguments are all deduced or defaulted
int idf(int n = 1)(int v) if (g(n) == 2)	// BP_IDF
{
	return v + n;
}

// a condition inside a template mixin, mixed into an aggregate instance
mixin template Check(U)
{
	static if (is(U == int) && g(3) == 6)	// BP_MIXINIF
		enum int ok = 1;
}

struct Outer(T)
{
	mixin Check!T;
	static if (is(T == int) && g(4) == 8)	// BP_OUTERIF
		enum int three = 3;
}

enum int a = pick!(2)([7, 8, 9], 1);	// BP_A
enum int b = Box!int(5).value + Box!int.doubled;	// BP_B
enum int c = Outer!int.three + Outer!int.ok;	// BP_C
enum int d = idf(7);	// BP_D

struct S(int x)
if((x & 1) == 0)
{
	enum val = x * x;
}
struct S(int x)
if((x & 1) == 1)
{
	enum val = x;
}
static assert(S!(4).val == 16);
static assert(S!(3).val == 3);
