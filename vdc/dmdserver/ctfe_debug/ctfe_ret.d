module ctfe_ret;

// A call ends on a line of its own: the return of the function that hands its
// value back to the caller, and the statement of the caller that goes on.
int total(int[] arr)
{
	int sum = 0;
	foreach (e; arr)
		sum += e;
	return sum;					// RET_TOTAL
}

int scaled(int[] arr)
{
	int factor = 4;
	int base = total(arr);				// BP_CALL
	return (base + factor) * 2;			// RET_SCALED
}

enum int v1 = scaled([1, 2, 3]);			// BP_ENUM
