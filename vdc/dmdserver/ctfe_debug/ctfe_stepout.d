module ctfe_stepout;

// Stepping out of a call ends at the line the call is written on: the frame the
// value goes back to is reported there, and the value comes back with it.  A call
// that returns nothing ends at that line as well, without a value.
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
	int base = total(arr);				// CALL_TOTAL
	return (base + factor) * 2;			// RET_SCALED
}

void say(int[] arr)
{
	auto n = arr.length;				// SAY_BODY
}

int twice(int[] arr)
{
	int v = scaled(arr);				// CALL_SCALED
	say(arr);						// CALL_SAY
	return v * 3;					// RET_TWICE
}

enum int v1 = twice([1, 2, 3]);			// BP_ENTRY
