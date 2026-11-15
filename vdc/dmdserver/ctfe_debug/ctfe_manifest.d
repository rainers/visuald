module ctfe_manifest;

int addup(int n)
{
	int sum = 0;
	for (int k = 1; k <= n; k++)
		sum += k;					// BP_ADDUP
	return sum;
}

enum int e1 = addup(6);				// BP_MANIFEST
const int c1 = addup(7);			// BP_CONST
immutable int i1 = addup(8);		// BP_IMMUTABLE

enum int[3] arr = [addup(1), addup(2), addup(3)];	// BP_ARRAY

T twice(T)(T v)
{
	return v * 2;
}

enum int t1 = twice(21);			// BP_TEMPLATE

static assert(addup(4) == 10);		// BP_STATICASSERT

int gfn()
{
	enum int local = addup(5);		// BP_LOCALMANIFEST
	return local;
}

enum int g1 = gfn();				// BP_GFN
