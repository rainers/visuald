module ctfe_cond;

bool big(int n)
{
	return n > 2;
}

T combine(T)(T a, T b) if (is(T == int) || is(T == double))  // BP_CONSTRAINT
{
	static if (is(T == int) && big(3))                       // BP_STATICIF
	{
		assert(a != b);                                      // BP_ASSERT
		return a + b;
	}
	else
	{
		return a * b;
	}
}

static assert(combine(2, 3) == 5);                           // BP_STATICASSERT

enum auto total = combine(4, 5);                             // BP_ENUM
