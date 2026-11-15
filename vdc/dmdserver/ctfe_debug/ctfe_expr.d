module ctfe_expr;

struct Point
{
	int x;
	int y;
}

int sumArr(int[4] arr)
{
	int total = 0;
	foreach (k, v; arr)
		total += v;				// BP_FOREACH
	return total;
}

int loop(int n)
{
	int total = 0;
	for (int k = 0; k < n; k++)
	{
		total += k;				// BP_LOOP
	}
	return total;
}

int mixed(int[5] arr, Point p, string s, bool flag)
{
	int r = arr[2] + p.y;
	if (flag)
		r += cast(int) s.length;
	return r;					// BP_MIXED
}

enum int a = sumArr([10, 20, 30, 40]);
enum int b = loop(20);
enum int c = mixed([1, 2, 3, 4, 5], Point(7, 9), "abc", true);
