module ctfe_template;

T twice(T)(T v)
{
	return v * 2;					// BP_TWICE
}

int addup(int n)(int step)
{
	int sum = 0;
	foreach (k; 0 .. 3)
		sum += n * step;				// BP_VALUE
	return sum;
}

struct Box(T)
{
	T value;

	T doubled()
	{
		return value * 2;				// BP_MEMBER
	}
}

int tupsum(Args...)(Args args)
{
	int sum = 0;
	foreach (a; args)
		sum += a;					// BP_TUPLE
	return sum;
}

enum int t1 = twice(21);				// BP_TWICE_CALL
enum int t2 = addup!4(3);				// BP_VALUE_CALL
enum int t3 = addup!5(2);				// BP_VALUE_CALL2
enum int t4 = Box!int(21).doubled();			// BP_MEMBER_CALL
enum int t5 = tupsum(1, 2, 3);			// BP_TUPLE_CALL
