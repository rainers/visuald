module ctfe_nested;

// Each instance declares a member of the next instance, so the instances are
// nested in each other and one call frame belongs to several of them at once.
struct Link(int n)
{
	int value;

	static if (n == 0)
		int add(int acc)
		{
			return acc + value;				// BP_ZERO
		}
	else
	{
		Link!(n - 1) inner;					// BP_SITE

		int add(int acc)
		{
			inner.value = value + n;
			return inner.add(acc);			// BP_STEP
		}
	}
}

enum int r = Link!2(1).add(0);			// BP_CALL
