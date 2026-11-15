// The values and the types of template instances name the arguments the instance
// was created with, spelled the way the compiler spells them.
module ctfe_values;

struct Box(T)
{
	T value;
}

struct Pair(A, B)
{
	A first;
	B second;
}

struct Cell(int n)
{
	int value;
	int get()
	{
		return value + n;	// BP_CELL
	}
}

class Obj(T)
{
	T payload;
}

int fn(T)(T v) { return v + 1; }

struct Leaf {
	int val;
	int sum()
	{
		return val;
	}
}

struct Node(T)
{
	int val;
	T next;
	int sum()
	{
		return val + next.sum();	// BP_NODE
	}
}

enum Box!int bi = Box!int(3);
enum Pair!(int,string) ps = Pair!(int,string)(7, "hi");
enum Cell!7 c7 = Cell!7(3);
enum Leaf lf = Leaf(4);
enum Node!Leaf n1 = Node!Leaf(3, lf);
enum Node!(Node!Leaf) n2 = Node!(Node!Leaf)(1, n1);

int test()
{
	auto fp = &fn!int;
	auto b = bi;
	auto p = ps;
	auto cell = c7;
	auto obj = new Obj!(Box!int);
	obj.payload = Box!int(9);
	int probe = 0;   // BP_PROBE
	return b.value + p.first + cell.get() + n2.sum() + obj.payload.value;
}

enum auto x = test();
enum auto y = x / 0;
