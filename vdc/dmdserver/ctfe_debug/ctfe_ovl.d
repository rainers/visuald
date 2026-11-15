module ctfe_ovl;

struct T(int x)
if((x & 1) == 0)
{
	int val = x;
	static if(x == 0){
		enum done = true;
		pragma(msg, "done ", T);
		int foo(int y)
		{
			return x + y;
		}
	} else {
		pragma(msg, "static else, before expanding the dependent template");
		T!(x - 1) nested;

		int foo(int y)
		{
			return nested.foo(y) + x;
		}
	}
	enum even = 3;
	alias Type = long;
}

struct T(int x)
if((x & 1) == 1)
{
	pragma(msg, "before expanding the dependent template");
	T!(x - 1) nested;

	int foo(int y)
	{
		return nested.foo(y) - x;
	}
	enum odd = 3;
	alias Type = int;
}

void test2()
{
	T!5 t3;
	static if(is(t3.done)){
		pragma(msg, "instantiated");
	}
	pragma(msg, "main");
}

enum t5 = T!5().foo(4);
